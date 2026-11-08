import Foundation
import Network

/// Command-line options for the streamer. Parsing is pure so it can be
/// unit-tested.
///
/// `bindHost` defaults to loopback: running the demo never exposes the
/// screen stream beyond the local machine unless the user opts in with
/// `--bind`.
public struct StreamerOptions: Equatable {
    public static let fpsRange = 1...240
    public static let megabitsRange = 1...500
    public static let keyframeIntervalRange = 1...60

    /// Named hardware presets. A profile only supplies defaults: an explicit
    /// `--fps`, `--mbps`, `--resolution`, or `--latency` wins, whatever its
    /// position on the command line.
    public enum Profile: String, CaseIterable, Sendable {
        /// M3 Pro (18 GB) + Quest 3 over USB. The balanced per-eye size keeps
        /// VideoToolbox near 8 ms per frame, and 30 Mbps avoids the frame
        /// drops that low-latency rate control makes at 12 Mbps on
        /// game-like content (docs/PERFORMANCE.md).
        case m3pro

        public var fps: Int { 72 }
        public var megabits: Int { 30 }
        public var perEyeResolution: PerEyeResolution { .balanced }
        public var latencyPreset: StreamLatencyPreset { .low }
    }

    public var port: UInt16 = 9999
    public var fps = 72
    public var megabits = 30
    public var perEyeResolution = PerEyeResolution.quality
    public var latencyPreset = StreamLatencyPreset.low
    public var bindHost = "127.0.0.1"
    public var discover = false
    public var wired = false
    public var runtimeControlFile: String?
    public var audioDeviceName: String?
    public var routeAudioToCaptureDevice = false
    public var listAudioDevices = false
    /// The applied `--profile`, if any.
    public var profile: Profile?
    /// Longest time between periodic IDR frames. IDRs that the headset
    /// requests for recovery do not depend on this.
    public var keyframeIntervalSeconds = 2
    public var entropyMode = H264EntropyMode.cabac
    /// The stream codec. Not part of a profile until HEVC has a headset A/B.
    public var codec = VideoCodec.h264
    public var controllerPrediction = ControllerPrediction.full

    public init() {}

    public static let usage = """
        usage: basalt-streamer [options]

        Captures the main display, hardware-encodes H.264 or HEVC (low-latency),
        and serves the raw Annex-B stream to connected TCP clients.

        options:
          --port <n>    TCP port to listen on (default 9999)
          --fps <n>     capture frame rate, 1–240 (default 72)
          --mbps <n>    encoder bitrate in Mbit/s, 1–500 (default 30)
          --resolution <preset|WIDTHxHEIGHT>
                        per-eye headset resolution: performance (896x944),
                        balanced (1152x1216), quality (1344x1408, default),
                        or custom even dimensions
          --latency <balanced|low|ultra>
                        Quest decoder buffering (default low; ultra targets
                        one frame with less history and may expose jitter)
          --profile <m3pro>
                        hardware preset; m3pro = balanced, 72 fps, 30 Mbps,
                        low latency. Explicit flags override the preset
          --idr-interval <seconds>
                        longest gap between periodic IDR frames, 1–60
                        (default 2); headset recovery requests still apply
          --codec <h264|hevc>
                        stream codec (default h264); hevc is HEVC Main,
                        8-bit, hardware VideoToolbox
          --entropy <cabac|cavlc>
                        H.264 entropy coding (default cabac; ALVR's own
                        encoders default to cavlc); h264 only
          --controller-prediction <full|alvr>
                        full (default) asks the Quest to predict controllers
                        as far ahead as the head; alvr keeps ALVR's shorter
                        SteamVR-oriented controller prediction
          --bind <ip>   address to listen on (default 127.0.0.1, i.e.
                        this machine only; 0.0.0.0 accepts LAN clients
                        and exposes your screen to the network)
          --wireless    discover an ALVR headset on the local network,
                        negotiate a session, and stream over Wi-Fi/UDP
          --discover    legacy alias for --wireless
          --wired       connect to an authorized USB headset through adb and
                        stream the ALVR session over forwarded TCP ports
          --runtime <control-file>
                        stream frames submitted by the BasaltVR OpenXR
                        runtime instead of capturing the desktop; writes
                        "<port> <token> <width> <height>" to <control-file>, which the game
                        bottle receives as BASALT_CONTROL
          --audio-device <name>
                        capture 48 kHz stereo game audio from the matching
                        CoreAudio input (normally "BlackHole 2ch") and send
                        raw PCM on the ALVR stream; requires headset mode
          --route-audio route the Mac's default application output to the
                        selected audio device for this session, then restore
                        the previous output on shutdown; requires
                        --audio-device
          --list-audio-devices
                        print CoreAudio input devices and exit
          --help        show this help
        """

    /// Returns nil when --help was requested.
    public static func parse(_ argv: [String]) throws -> StreamerOptions? {
        var options = StreamerOptions()
        var arguments = argv
        var explicitFPS = false
        var explicitMegabits = false
        var explicitResolution = false
        var explicitLatency = false
        var explicitEntropy = false

        func nextValue(for flag: String) throws -> String {
            guard !arguments.isEmpty else { throw BasaltError("\(flag) requires a value") }
            return arguments.removeFirst()
        }
        func number<T: FixedWidthInteger>(for flag: String) throws -> T {
            let value = try nextValue(for: flag)
            guard let parsed = T(value), parsed > 0 else {
                throw BasaltError("\(flag) expects a positive number, got '\(value)'")
            }
            return parsed
        }

        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            switch flag {
            case "--port": options.port = try number(for: flag)
            case "--fps":
                explicitFPS = true
                options.fps = try number(for: flag)
                guard fpsRange.contains(options.fps) else {
                    throw BasaltError("--fps must be between \(fpsRange.lowerBound) and \(fpsRange.upperBound)")
                }
            case "--mbps":
                explicitMegabits = true
                options.megabits = try number(for: flag)
                guard megabitsRange.contains(options.megabits) else {
                    throw BasaltError("--mbps must be between \(megabitsRange.lowerBound) and \(megabitsRange.upperBound)")
                }
            case "--resolution":
                explicitResolution = true
                options.perEyeResolution = try PerEyeResolution.parse(nextValue(for: flag))
            case "--latency":
                let value = try nextValue(for: flag).lowercased()
                guard let preset = StreamLatencyPreset(rawValue: value) else {
                    throw BasaltError("--latency expects balanced, low, or ultra")
                }
                explicitLatency = true
                options.latencyPreset = preset
            case "--profile":
                let value = try nextValue(for: flag).lowercased()
                guard let profile = Profile(rawValue: value) else {
                    throw BasaltError("--profile expects "
                        + Profile.allCases.map(\.rawValue).joined(separator: ", "))
                }
                options.profile = profile
            case "--idr-interval":
                options.keyframeIntervalSeconds = try number(for: flag)
                guard keyframeIntervalRange.contains(options.keyframeIntervalSeconds) else {
                    throw BasaltError("--idr-interval must be between "
                        + "\(keyframeIntervalRange.lowerBound) and "
                        + "\(keyframeIntervalRange.upperBound) seconds")
                }
            case "--entropy":
                let value = try nextValue(for: flag).lowercased()
                guard let mode = H264EntropyMode(rawValue: value) else {
                    throw BasaltError("--entropy expects cabac or cavlc")
                }
                options.entropyMode = mode
                explicitEntropy = true
            case "--codec":
                let value = try nextValue(for: flag).lowercased()
                let aliases: [String: VideoCodec] = ["h265": .hevc, "avc": .h264]
                guard let codec = VideoCodec(rawValue: value) ?? aliases[value] else {
                    throw BasaltError("--codec expects h264 or hevc")
                }
                options.codec = codec
            case "--controller-prediction":
                let value = try nextValue(for: flag).lowercased()
                guard let prediction = ControllerPrediction(rawValue: value) else {
                    throw BasaltError("--controller-prediction expects full or alvr")
                }
                options.controllerPrediction = prediction
            case "--bind":
                let host = try nextValue(for: flag)
                guard IPv4Address(host) != nil || IPv6Address(host) != nil else {
                    throw BasaltError("--bind expects an IP address, got '\(host)'")
                }
                options.bindHost = host
            case "--wireless", "--discover": options.discover = true
            case "--wired": options.wired = true
            case "--runtime": options.runtimeControlFile = try nextValue(for: flag)
            case "--audio-device":
                let name = try nextValue(for: flag)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    throw BasaltError("--audio-device expects a non-empty device name")
                }
                options.audioDeviceName = name
            case "--route-audio": options.routeAudioToCaptureDevice = true
            case "--list-audio-devices": options.listAudioDevices = true
            case "--help", "-h": return nil
            default: throw BasaltError("Unknown flag \(flag) (try --help)")
            }
        }
        if let profile = options.profile {
            if !explicitFPS { options.fps = profile.fps }
            if !explicitMegabits { options.megabits = profile.megabits }
            if !explicitResolution { options.perEyeResolution = profile.perEyeResolution }
            if !explicitLatency { options.latencyPreset = profile.latencyPreset }
        }
        guard !explicitEntropy || options.codec == .h264 else {
            throw BasaltError("--entropy applies only to --codec h264 (HEVC always uses CABAC)")
        }
        guard !(options.discover && options.wired) else {
            throw BasaltError("--wireless and --wired cannot be used together")
        }
        guard options.audioDeviceName == nil || options.discover || options.wired else {
            throw BasaltError("--audio-device requires --wireless or --wired")
        }
        guard !options.routeAudioToCaptureDevice || options.audioDeviceName != nil else {
            throw BasaltError("--route-audio requires --audio-device")
        }
        return options
    }

    public var bindIsLoopback: Bool {
        if let address = IPv4Address(bindHost) { return address.isLoopback }
        if let address = IPv6Address(bindHost) { return address.isLoopback }
        return false
    }
}
