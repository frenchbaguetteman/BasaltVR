import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia

public struct GameAudioDevice: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let sampleRate: Double

    public init(id: UInt32, name: String, sampleRate: Double) {
        self.id = id
        self.name = name
        self.sampleRate = sampleRate
    }
}

public enum GameAudioDeviceDiscovery {
    public static func inputDevices() throws -> [GameAudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount)
        guard status == noErr else {
            throw BasaltError("Could not enumerate CoreAudio devices (status \(status))")
        }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &byteCount, &ids)
        guard status == noErr else {
            throw BasaltError("Could not read CoreAudio devices (status \(status))")
        }

        return ids.compactMap { id in
            guard hasInputStreams(id), let name = deviceName(id) else { return nil }
            return GameAudioDevice(
                id: id, name: name, sampleRate: nominalSampleRate(id) ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func matchingInputDevice(_ substring: String) throws -> GameAudioDevice {
        let devices = try inputDevices()
        let matches = devices.filter {
            $0.name.range(of: substring, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if let exact = matches.first(where: {
            $0.name.compare(substring, options: [.caseInsensitive, .diacriticInsensitive]) ==
                .orderedSame
        }) {
            return exact
        }
        guard matches.count == 1, let match = matches.first else {
            let names = devices.map(\.name).joined(separator: ", ")
            if matches.isEmpty {
                throw BasaltError(
                    "No CoreAudio input device contains '\(substring)'; available: \(names)")
            }
            throw BasaltError(
                "Audio device name '\(substring)' is ambiguous: "
                    + matches.map(\.name).joined(separator: ", "))
        }
        return match
    }

    public static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}

/// Temporarily points the system's default application-audio output at the
/// selected loopback device. The previous output is restored only when the
/// route still points at the device Basalt selected, so a user change made
/// during streaming is never overwritten during teardown.
public final class GameAudioOutputRoute: @unchecked Sendable {
    public let device: GameAudioDevice

    private let previousDeviceID: AudioDeviceID
    private let stateLock = NSLock()
    private var restored = false

    public init(to device: GameAudioDevice) throws {
        guard GameAudioDeviceDiscovery.hasOutputStreams(device.id) else {
            throw BasaltError(
                "CoreAudio input '\(device.name)' cannot also receive application output")
        }
        self.device = device
        previousDeviceID = try Self.defaultOutputDeviceID()
        if previousDeviceID != device.id {
            try Self.setDefaultOutputDeviceID(device.id)
        }
    }

    public func restore() throws {
        stateLock.lock()
        guard !restored else {
            stateLock.unlock()
            return
        }
        let shouldRestore: Bool
        do {
            let currentDeviceID = try Self.defaultOutputDeviceID()
            shouldRestore = previousDeviceID != device.id && currentDeviceID == device.id
        } catch {
            stateLock.unlock()
            throw error
        }
        if shouldRestore {
            do {
                try Self.setDefaultOutputDeviceID(previousDeviceID)
            } catch {
                stateLock.unlock()
                throw error
            }
        }
        restored = true
        stateLock.unlock()
    }

    deinit {
        try? restore()
    }

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw BasaltError("Could not read the current CoreAudio output device (status \(status))")
        }
        return deviceID
    }

    private static func setDefaultOutputDeviceID(_ id: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
        guard status == noErr else {
            throw BasaltError(
                "Could not route application audio to CoreAudio device \(id) (status \(status))")
        }
    }
}

public enum StereoPCM16Encoder {
    public static func encode(left: [Float], right: [Float]) throws -> Data {
        guard left.count == right.count else {
            throw BasaltError("Stereo audio channels have different frame counts")
        }
        return encode(frameCount: left.count) { frame, channel in
            channel == 0 ? left[frame] : right[frame]
        }
    }

    static func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount >= 2,
              let channels = buffer.floatChannelData else { return nil }
        return encode(frameCount: Int(buffer.frameLength)) { frame, channel in
            channels[channel][frame]
        }
    }

    private static func encode(frameCount: Int,
                               sample: (_ frame: Int, _ channel: Int) -> Float) -> Data {
        var output = Data(count: frameCount * 2 * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frameCount {
                for channel in 0..<2 {
                    let encoded = pcm16(sample(frame, channel)).littleEndian
                    let offset = (frame * 2 + channel) * 2
                    bytes[offset] = UInt8(truncatingIfNeeded: encoded)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: encoded >> 8)
                }
            }
        }
        return output
    }

    private static func pcm16(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        if sample >= 1 { return .max }
        if sample <= -1 { return .min }
        return Int16(sample * 32_768)
    }
}

public final class GameAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
                                     @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    public static let channelCount: AVAudioChannelCount = 2

    public var onPCM16: ((Data) -> Void)?
    public let device: GameAudioDevice

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(
        label: "basalt.audio.capture", qos: .userInteractive)
    private let stateLock = NSLock()
    private var running = false

    public init(deviceNameContains: String) throws {
        let selectedDevice = try GameAudioDeviceDiscovery.matchingInputDevice(deviceNameContains)
        device = selectedDevice
        try MicrophoneAccess.ensureGranted(deviceName: selectedDevice.name)
        let captureDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio,
            position: .unspecified).devices
        guard let captureDevice = captureDevices.first(where: {
            $0.localizedName.compare(
                selectedDevice.name,
                options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            throw BasaltError(
                "CoreAudio input '\(selectedDevice.name)' is not available to AVFoundation")
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: captureDevice)
        } catch {
            throw BasaltError(
                "Could not open '\(selectedDevice.name)': \(error.localizedDescription). "
                    + MicrophoneAccess.denialHint(
                        state: MicrophoneAccess.currentState(),
                        hostApp: MicrophoneAccess.hostAppName()))
        }

        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else {
            throw BasaltError("Could not attach '\(device.name)' to audio capture")
        }
        session.addInput(input)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Int(Self.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            throw BasaltError("Could not configure PCM output for '\(device.name)'")
        }
        session.addOutput(output)
    }

    public func start() throws {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        session.startRunning()
        guard session.isRunning else {
            throw BasaltError("Could not start audio capture from '\(device.name)'")
        }
        stateLock.lock()
        running = true
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = running
        running = false
        stateLock.unlock()
        guard wasRunning else { return }
        session.stopRunning()
    }

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let byteCount = CMBlockBufferGetDataLength(block)
        guard frames > 0, byteCount == frames * 4 else { return }
        var pcm = Data(count: byteCount)
        let status = pcm.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: byteCount,
                destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        onPCM16?(pcm)
    }

    deinit { stop() }
}
