import Foundation

/// The parts of a Windows PE image that VR setup needs: the CPU architecture and the DLLs the
/// image imports. Only headers are trusted; every offset is bounds-checked, so a truncated or
/// hostile file gives nil or an empty list, never a crash.
public enum PEImage {
    public static let machineX86: UInt16 = 0x014c
    public static let machineX64: UInt16 = 0x8664
    public static let machineARM64: UInt16 = 0xaa64

    /// The COFF machine field, or nil when `bytes` is not a PE image.
    public static func machine(_ bytes: Data) -> UInt16? {
        BottleManager.peMachine(bytes)
    }

    /// A short name for a COFF machine value, for messages.
    public static func describe(machine: UInt16) -> String {
        switch machine {
        case machineX86: return "32-bit (x86)"
        case machineX64: return "64-bit (x86-64)"
        case machineARM64: return "ARM64"
        default: return String(format: "machine 0x%04x", machine)
        }
    }

    /// Lowercased names of the DLLs in the import and delay-load import tables.
    public static func importedLibraries(_ bytes: Data) -> Set<String> {
        guard let header = Header(bytes) else { return [] }
        let image = header.image
        var names = Set<String>()
        // Import directory (index 1): 20-byte descriptors, name RVA at +12.
        if let (rva, _) = header.dataDirectory(1),
           var offset = header.fileOffset(forRVA: rva) {
            for _ in 0..<4096 {
                guard offset + 20 <= image.count else { break }
                let nameRVA = read32(image, offset + 12)
                if read32(image, offset) == 0, nameRVA == 0, read32(image, offset + 16) == 0 {
                    break
                }
                if let name = header.string(atRVA: nameRVA) { names.insert(name.lowercased()) }
                offset += 20
            }
        }
        // Delay-load directory (index 13): 32-byte descriptors, name RVA at +4.
        if let (rva, _) = header.dataDirectory(13),
           var offset = header.fileOffset(forRVA: rva) {
            for _ in 0..<4096 {
                guard offset + 32 <= image.count else { break }
                let nameRVA = read32(image, offset + 4)
                if nameRVA == 0 { break }
                if let name = header.string(atRVA: nameRVA) { names.insert(name.lowercased()) }
                offset += 32
            }
        }
        return names
    }

    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawOffset: UInt32
        let rawSize: UInt32
    }

    private struct Header {
        let image: [UInt8]
        let machine: UInt16
        let optionalHeader: Int
        let optionalHeaderSize: Int
        let isPE32Plus: Bool
        let sections: [Section]

        init?(_ bytes: Data) {
            let image = [UInt8](bytes)
            guard image.count >= 0x40, image[0] == 0x4d, image[1] == 0x5a else { return nil }
            let peOffset = Int(PEImage.read32(image, 0x3c))
            guard peOffset >= 0x40, peOffset <= image.count - 24,
                  image[peOffset] == 0x50, image[peOffset + 1] == 0x45,
                  image[peOffset + 2] == 0, image[peOffset + 3] == 0 else { return nil }
            self.image = image
            machine = PEImage.read16(image, peOffset + 4)
            let sectionCount = Int(PEImage.read16(image, peOffset + 6))
            optionalHeaderSize = Int(PEImage.read16(image, peOffset + 20))
            optionalHeader = peOffset + 24
            if optionalHeaderSize >= 2, optionalHeader + 2 <= image.count {
                isPE32Plus = PEImage.read16(image, optionalHeader) == 0x20b
            } else {
                isPE32Plus = false
            }
            var sections = [Section]()
            var table = optionalHeader + optionalHeaderSize
            for _ in 0..<min(sectionCount, 96) {
                guard table + 40 <= image.count else { break }
                sections.append(Section(
                    virtualAddress: PEImage.read32(image, table + 12),
                    virtualSize: PEImage.read32(image, table + 8),
                    rawOffset: PEImage.read32(image, table + 20),
                    rawSize: PEImage.read32(image, table + 16)))
                table += 40
            }
            self.sections = sections
        }

        func dataDirectory(_ index: Int) -> (UInt32, UInt32)? {
            guard optionalHeaderSize > 0 else { return nil }
            let directories = optionalHeader + (isPE32Plus ? 112 : 96)
            let countOffset = optionalHeader + (isPE32Plus ? 108 : 92)
            guard countOffset + 4 <= image.count,
                  index < Int(PEImage.read32(image, countOffset)) else { return nil }
            let entry = directories + index * 8
            guard entry + 8 <= optionalHeader + optionalHeaderSize,
                  entry + 8 <= image.count else { return nil }
            let rva = PEImage.read32(image, entry)
            let size = PEImage.read32(image, entry + 4)
            return rva == 0 ? nil : (rva, size)
        }

        func fileOffset(forRVA rva: UInt32) -> Int? {
            for section in sections {
                let span = max(section.virtualSize, section.rawSize)
                guard rva >= section.virtualAddress,
                      UInt64(rva) < UInt64(section.virtualAddress) + UInt64(span) else { continue }
                let offset = Int(rva - section.virtualAddress) + Int(section.rawOffset)
                return offset < image.count ? offset : nil
            }
            return nil
        }

        func string(atRVA rva: UInt32) -> String? {
            guard let start = fileOffset(forRVA: rva) else { return nil }
            var end = start
            while end < image.count, end - start < 260, image[end] != 0 { end += 1 }
            guard end > start, end < image.count, image[end] == 0 else { return nil }
            return String(bytes: image[start..<end], encoding: .ascii)
        }
    }

    private static func read16(_ image: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= image.count else { return 0 }
        return UInt16(image[offset]) | UInt16(image[offset + 1]) << 8
    }

    private static func read32(_ image: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= image.count else { return 0 }
        return UInt32(image[offset]) | UInt32(image[offset + 1]) << 8 |
            UInt32(image[offset + 2]) << 16 | UInt32(image[offset + 3]) << 24
    }
}
