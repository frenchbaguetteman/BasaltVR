import Foundation
import CoreMedia
import CoreVideo
import BasaltCore

/// Measures the streamer's VideoToolbox encoder on this Mac with the exact
/// session settings the headset stream uses: per-codec submit-to-output time
/// and the frames that low-latency rate control drops, at a real-time pace.
///
/// The content is synthetic but game-like: a detailed texture that pans
/// (two layers at different speeds, like head rotation with parallax) plus a
/// moving object. Absolute drop rates depend on content; compare codecs and
/// bitrates with each other, not with a real game.
///
/// Usage: basalt-streamer encoder-bench [--codec h264|hevc|both]
///            [--resolution balanced,quality,1680x1760] [--mbps 30,60,80]
///            [--fps 72] [--seconds 5] [--output-dir <dir>]
///
/// `--output-dir` writes each run's Annex-B stream (for example
/// `hevc-1152x1216-30mbps.hevc`) so ffprobe or ffmpeg can check that it decodes.
enum EncoderBenchmark {
    struct Configuration {
        var codecs: [VideoCodec] = VideoCodec.allCases
        var resolutions: [PerEyeResolution] = [
            .balanced, .quality, try! PerEyeResolution(width: 1_680, height: 1_760),
        ]
        var megabits = [30, 60, 80]
        var fps = 72
        var seconds = 5
        var outputDirectory: URL?
    }

    struct Result {
        let codec: VideoCodec
        let perEye: PerEyeResolution
        let megabits: Int
        let submitted: Int
        let rejectedBusy: Int
        let droppedByEncoder: Int
        let encodeMilliseconds: [Double]
        let outputBytes: Int
        let keyframes: Int
        let seconds: Double
    }

    static func run(_ arguments: [String]) {
        let configuration: Configuration
        do {
            configuration = try parse(arguments)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
        print("codec  per-eye    encoded    Mbps  frames  busy  VT-drop  drop%   "
            + "enc-med  enc-p95  enc-max  out-Mbps  IDRs")
        var failed = false
        for perEye in configuration.resolutions {
            let width = perEye.width * 2
            let height = perEye.height
            let content = SyntheticContent(width: width, height: height)
            for codec in configuration.codecs {
                for megabits in configuration.megabits {
                    do {
                        let result = try measure(codec: codec, perEye: perEye,
                                                 megabits: megabits,
                                                 configuration: configuration,
                                                 content: content)
                        print(format(result))
                    } catch {
                        failed = true
                        print("\(codec.rawValue) \(perEye.width)x\(perEye.height) "
                            + "\(megabits) Mbps: \(error.localizedDescription)")
                    }
                }
            }
        }
        if failed { exit(1) }
    }

    private static func parse(_ arguments: [String]) throws -> Configuration {
        var configuration = Configuration()
        var arguments = arguments
        func next(_ flag: String) throws -> String {
            guard !arguments.isEmpty else { throw BasaltError("\(flag) requires a value") }
            return arguments.removeFirst()
        }
        func numbers(_ flag: String) throws -> [Int] {
            let values = try next(flag).split(separator: ",").map { Int($0) }
            guard !values.isEmpty, values.allSatisfy({ ($0 ?? 0) > 0 }) else {
                throw BasaltError("\(flag) expects positive numbers")
            }
            return values.compactMap { $0 }
        }
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            switch flag {
            case "--codec":
                let value = try next(flag).lowercased()
                if value == "both" {
                    configuration.codecs = VideoCodec.allCases
                } else if let codec = VideoCodec(rawValue: value) {
                    configuration.codecs = [codec]
                } else {
                    throw BasaltError("--codec expects h264, hevc, or both")
                }
            case "--resolution":
                configuration.resolutions = try next(flag).split(separator: ",")
                    .map { try PerEyeResolution.parse(String($0)) }
            case "--mbps": configuration.megabits = try numbers(flag)
            case "--fps":
                guard let fps = try numbers(flag).first,
                      StreamerOptions.fpsRange.contains(fps) else {
                    throw BasaltError("--fps must be between 1 and 240")
                }
                configuration.fps = fps
            case "--seconds":
                guard let seconds = try numbers(flag).first else {
                    throw BasaltError("--seconds expects a positive number")
                }
                configuration.seconds = seconds
            case "--output-dir":
                let url = URL(fileURLWithPath: try next(flag), isDirectory: true)
                try FileManager.default.createDirectory(at: url,
                                                        withIntermediateDirectories: true)
                configuration.outputDirectory = url
            default:
                throw BasaltError("Unknown encoder-bench flag \(flag)")
            }
        }
        return configuration
    }

    private static func measure(codec: VideoCodec, perEye: PerEyeResolution, megabits: Int,
                                configuration: Configuration,
                                content: SyntheticContent) throws -> Result {
        let width = perEye.width * 2
        let height = perEye.height
        let lock = NSLock()
        var durations = [Double]()
        var drops = 0
        var outputBytes = 0
        var keyframes = 0
        var stream = Data()
        let keepStream = configuration.outputDirectory != nil
        var encodeError: Error?

        // The streamer's settings: periodic IDR every 2 s, CABAC for H.264.
        let encoder = try VideoEncoder(
            width: width, height: height, fps: configuration.fps,
            bitrate: megabits * 1_000_000, keyframeIntervalSeconds: 2,
            codec: codec) { annexB, isKeyframe, _ in
                lock.lock()
                outputBytes += annexB.count
                if isKeyframe { keyframes += 1 }
                if keepStream { stream.append(annexB) }
                lock.unlock()
            }
        encoder.onFrameEncoded = { nanoseconds, dropped in
            lock.lock()
            durations.append(Double(nanoseconds) / 1_000_000)
            if dropped { drops += 1 }
            lock.unlock()
        }
        encoder.onError = { error in
            lock.lock()
            encodeError = error
            lock.unlock()
        }

        let pool = try makePool(width: width, height: height)
        let frameCount = configuration.fps * configuration.seconds
        let interval = 1_000_000_000 / UInt64(configuration.fps)
        var rejected = 0
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<frameCount {
            let deadline = start + UInt64(index) * interval
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                let ticks = (deadline - now) * UInt64(timebase.denom) / UInt64(timebase.numer)
                mach_wait_until(mach_absolute_time() + ticks)
            }
            guard encoder.canAcceptFrame else {
                rejected += 1
                continue
            }
            var maybeBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer) == kCVReturnSuccess,
                  let buffer = maybeBuffer else {
                throw BasaltError("Could not allocate a benchmark frame")
            }
            content.render(frame: index, into: buffer)
            if !encoder.encode(buffer,
                               pts: CMTime(value: Int64(index), timescale: Int32(configuration.fps))) {
                rejected += 1
            }
        }
        encoder.flush()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

        lock.lock()
        defer { lock.unlock() }
        if let encodeError { throw encodeError }
        if let directory = configuration.outputDirectory {
            let name = "\(codec.rawValue)-\(perEye.width)x\(perEye.height)-\(megabits)mbps"
                + ".\(codec.ffmpegFormat)"
            try stream.write(to: directory.appendingPathComponent(name))
        }
        return Result(codec: codec, perEye: perEye, megabits: megabits,
                      submitted: frameCount - rejected, rejectedBusy: rejected,
                      droppedByEncoder: drops, encodeMilliseconds: durations,
                      outputBytes: outputBytes, keyframes: keyframes, seconds: elapsed)
    }

    private static func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
                == kCVReturnSuccess, let pool else {
            throw BasaltError("Could not create a benchmark pixel-buffer pool")
        }
        return pool
    }

    private static func format(_ result: Result) -> String {
        let sorted = result.encodeMilliseconds.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let encoded = "\(result.perEye.width * 2)x\(result.perEye.height)"
        let total = result.submitted + result.rejectedBusy
        let dropPercent = 100 * Double(result.droppedByEncoder + result.rejectedBusy)
            / Double(max(1, total))
        let outMbps = Double(result.outputBytes * 8) / result.seconds / 1_000_000
        return [
            result.codec.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0),
            "\(result.perEye.width)x\(result.perEye.height)"
                .padding(toLength: 10, withPad: " ", startingAt: 0),
            encoded.padding(toLength: 10, withPad: " ", startingAt: 0),
            String(format: "%4d", result.megabits),
            String(format: "%6d", total),
            String(format: "%5d", result.rejectedBusy),
            String(format: "%7d", result.droppedByEncoder),
            String(format: "%5.1f", dropPercent),
            String(format: "%8.1f", percentile(0.5)),
            String(format: "%8.1f", percentile(0.95)),
            String(format: "%8.1f", sorted.last ?? 0),
            String(format: "%9.1f", outMbps),
            String(format: "%5d", result.keyframes),
        ].joined(separator: " ")
    }
}

/// Deterministic game-like frames: a detailed texture panning in two layers
/// at different speeds, plus a moving high-contrast object. Rendering is a
/// row copy from precomputed textures, fast enough for 72 fps at 3360×1760.
private final class SyntheticContent {
    private let width: Int
    private let height: Int
    private let textureWidth: Int
    private let textureHeight: Int
    private let texture: [UInt32]
    private let objectSize: Int
    private let object: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        textureWidth = width + 1_024
        textureHeight = height + 256
        texture = Self.makeTexture(width: textureWidth, height: textureHeight, seed: 1)
        objectSize = max(64, height / 5)
        object = Self.makeTexture(width: objectSize, height: objectSize, seed: 7)
            .map { $0 ^ 0x00FF_FFFF }
    }

    func render(frame: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // Background (top 60%) pans slowly; foreground pans faster, with a
        // slow vertical bob: head rotation with parallax.
        let horizon = height * 3 / 5
        let slowX = (frame * 3) % 1_024
        let fastX = (frame * 9) % 1_024
        let bob = Int(64 + 48 * sin(Double(frame) / 23))
        texture.withUnsafeBufferPointer { source in
            for row in 0..<height {
                let offsetX = row < horizon ? slowX : fastX
                let sourceRow = row + bob
                let from = source.baseAddress! + sourceRow * textureWidth + offsetX
                memcpy(base + row * bytesPerRow, from, width * 4)
            }
        }
        // A moving object over the scene, in both eyes.
        object.withUnsafeBufferPointer { source in
            let phase = Double(frame) / 40
            let eyeWidth = width / 2
            let x = Int(Double(eyeWidth - objectSize) * (0.5 + 0.45 * sin(phase)))
            let y = Int(Double(height - objectSize) * (0.5 + 0.4 * cos(phase * 1.3)))
            for eye in 0..<2 {
                for row in 0..<objectSize {
                    let destination = base + (y + row) * bytesPerRow + (eye * eyeWidth + x) * 4
                    memcpy(destination, source.baseAddress! + row * objectSize, objectSize * 4)
                }
            }
        }
    }

    /// Multi-octave value noise (terrain-like gradients) with hard-edged
    /// tiles and fine stripes for high-frequency detail.
    private static func makeTexture(width: Int, height: Int, seed: UInt64) -> [UInt32] {
        func hash(_ x: Int, _ y: Int, _ octave: Int) -> Double {
            var value = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663
                ^ octave &* 83_492_791)) &+ seed &* 0x9E37_79B9_7F4A_7C15
            value ^= value >> 33
            value = value &* 0xFF51_AFD7_ED55_8CCD
            value ^= value >> 33
            return Double(value & 0xFFFF) / 65_535
        }
        func noise(_ x: Double, _ y: Double, _ octave: Int) -> Double {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let fx = x - Double(x0), fy = y - Double(y0)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let top = hash(x0, y0, octave) * (1 - sx) + hash(x0 + 1, y0, octave) * sx
            let bottom = hash(x0, y0 + 1, octave) * (1 - sx) + hash(x0 + 1, y0 + 1, octave) * sx
            return top * (1 - sy) + bottom * sy
        }
        var pixels = [UInt32](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    var value = 0.0
                    var amplitude = 0.5
                    var scale = 1.0 / 160
                    for octave in 0..<5 {
                        value += amplitude * noise(Double(x) * scale, Double(y) * scale, octave)
                        amplitude *= 0.5
                        scale *= 2.2
                    }
                    // Hard-edged tiles ("buildings") and fine stripes.
                    let tile = hash(x / 96, y / 64, 99)
                    if tile > 0.72 { value = 0.25 + 0.5 * tile }
                    if (x + y / 3) % 7 == 0 { value *= 0.6 }
                    let detail = noise(Double(x) / 2.5, Double(y) / 2.5, 11) * 0.12
                    let level = max(0, min(1, value + detail - 0.06))
                    let r = UInt32(255 * level)
                    let g = UInt32(255 * max(0, min(1, level * 0.8 + 0.1 * tile)))
                    let b = UInt32(255 * max(0, min(1, 1 - level * 0.7)))
                    output[y * width + x] = 0xFF00_0000 | (r << 16) | (g << 8) | b
                }
            }
        }
        return pixels
    }
}
