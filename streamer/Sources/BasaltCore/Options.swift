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

    public init() {}

    public static let usage = """
        usage: basalt-streamer [options]

        Captures the main display, hardware-encodes H.264 (low-latency),
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
                options.fps = try number(for: flag)
                guard fpsRange.contains(options.fps) else {
                    throw BasaltError("--fps must be between \(fpsRange.lowerBound) and \(fpsRange.upperBound)")
                }
            case "--mbps":
                options.megabits = try number(for: flag)
                guard megabitsRange.contains(options.megabits) else {
                    throw BasaltError("--mbps must be between \(megabitsRange.lowerBound) and \(megabitsRange.upperBound)")
                }
            case "--resolution":
                options.perEyeResolution = try PerEyeResolution.parse(nextValue(for: flag))
            case "--latency":
                let value = try nextValue(for: flag).lowercased()
                guard let preset = StreamLatencyPreset(rawValue: value) else {
                    throw BasaltError("--latency expects balanced, low, or ultra")
                }
                options.latencyPreset = preset
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
