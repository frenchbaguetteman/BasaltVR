import Foundation

/// Minimal H.264 bitstream reader for tests: reads `frame_num` from slice
/// headers so a test can prove whether a stream has a reference gap (what
/// the Quest decoder reports as `h264DpbFillFrameNumGap`).
struct H264FrameNumParser {
    struct Picture: Equatable {
        let isIDR: Bool
        let isReference: Bool
        let frameNum: Int
    }

    private(set) var log2MaxFrameNum: Int?
    private(set) var gapsInFrameNumAllowed = false
    private var separateColourPlane = false

    struct BitReader {
        let bytes: [UInt8]
        var bit = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func u(_ count: Int) -> Int {
            var value = 0
            for _ in 0..<count {
                let byte = bit / 8 < bytes.count ? bytes[bit / 8] : 0
                value = (value << 1) | Int((byte >> (7 - UInt8(bit % 8))) & 1)
                bit += 1
            }
            return value
        }

        mutating func ue() -> Int {
            var zeros = 0
            while u(1) == 0 && zeros < 32 { zeros += 1 }
            return (1 << zeros) - 1 + u(zeros)
        }

        mutating func se() -> Int {
            let value = ue()
            return value % 2 == 1 ? (value + 1) / 2 : -(value / 2)
        }
    }

    /// NAL unit payloads (header byte first) with emulation-prevention
    /// bytes removed.
    static func nalUnits(_ annexB: Data) -> [[UInt8]] {
        let bytes = [UInt8](annexB)
        var starts = [(offset: Int, length: Int)]()
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else if index + 4 <= bytes.count, bytes[index] == 0, bytes[index + 1] == 0,
                      bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else {
                index += 1
            }
        }
        return starts.enumerated().map { position, start in
            let begin = start.offset + start.length
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            var rbsp = [UInt8]()
            var zeros = 0
            for byte in bytes[begin..<end] {
                if zeros >= 2 && byte == 3 {
                    zeros = 0
                    continue
                }
                rbsp.append(byte)
                zeros = byte == 0 ? zeros + 1 : 0
            }
            return rbsp
        }
    }

    /// Reads any SPS in the access unit, then returns its first slice.
    mutating func parse(accessUnit: Data) -> Picture? {
        var picture: Picture?
        for nal in Self.nalUnits(accessUnit) where !nal.isEmpty {
            let type = Int(nal[0] & 0x1F)
            let referenceIdc = Int(nal[0] >> 5) & 3
            var reader = BitReader(Array(nal.dropFirst()))
            if type == 7 {
                readSPS(&reader)
            } else if type == 1 || type == 5, picture == nil, let log2MaxFrameNum {
                _ = reader.ue() // first_mb_in_slice
                _ = reader.ue() // slice_type
                _ = reader.ue() // pic_parameter_set_id
                if separateColourPlane { _ = reader.u(2) }
                picture = Picture(isIDR: type == 5, isReference: referenceIdc != 0,
                                  frameNum: reader.u(log2MaxFrameNum))
            }
        }
        return picture
    }

    private mutating func readSPS(_ r: inout BitReader) {
        let profile = r.u(8)
        _ = r.u(16) // constraint flags, level_idc
        _ = r.ue() // seq_parameter_set_id
        separateColourPlane = false
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chroma = r.ue()
            if chroma == 3 { separateColourPlane = r.u(1) == 1 }
            _ = r.ue() // bit_depth_luma_minus8
            _ = r.ue() // bit_depth_chroma_minus8
            _ = r.u(1) // qpprime_y_zero_transform_bypass_flag
            if r.u(1) == 1 {
                for list in 0..<(chroma == 3 ? 12 : 8) where r.u(1) == 1 {
                    var last = 8
                    var next = 8
                    for _ in 0..<(list < 6 ? 16 : 64) where next != 0 {
                        next = (last + r.se() + 256) % 256
                        if next != 0 { last = next }
                    }
                }
            }
        }
        log2MaxFrameNum = r.ue() + 4
        let pictureOrderCountType = r.ue()
        if pictureOrderCountType == 0 {
            _ = r.ue()
        } else if pictureOrderCountType == 1 {
            _ = r.u(1)
            _ = r.se()
            _ = r.se()
            for _ in 0..<r.ue() { _ = r.se() }
        }
        _ = r.ue() // max_num_ref_frames
        gapsInFrameNumAllowed = r.u(1) == 1
    }

    /// Indices of pictures whose `frame_num` skips a reference picture that
    /// the decoder never received.
    static func frameNumGaps(_ pictures: [Picture], log2MaxFrameNum: Int) -> [Int] {
        let modulus = 1 << log2MaxFrameNum
        var previousReference: Int?
        var gaps = [Int]()
        for (index, picture) in pictures.enumerated() {
            if picture.isIDR {
                previousReference = picture.frameNum
                continue
            }
            if let previous = previousReference,
               picture.frameNum != previous,
               picture.frameNum != (previous + 1) % modulus {
                gaps.append(index)
            }
            if picture.isReference { previousReference = picture.frameNum }
        }
        return gaps
    }
}
