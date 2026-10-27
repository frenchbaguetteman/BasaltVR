import Foundation
import CoreMedia
import CoreVideo
import IOSurface
import BasaltCore

/// Counts a recurring event and logs only its first and every 120th
/// occurrence, so a sustained stall cannot flood stderr.
private final class ThrottledEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record(_ message: (_ count: Int) -> String) {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        if current == 1 || current.isMultiple(of: 120) {
            fputs(message(current) + "\n", stderr)
        }
    }

    func recordDroppedFrame(stage: String) {
        record { "\(stage): dropped \($0) frame(s) to bound latency" }
    }
}

private struct AlvrTrackingTimeoutError: LocalizedError {
    var errorDescription: String? {
        "Quest reported StreamReady but sent no tracking timestamps; "
            + "keep the headset awake with ALVR in the foreground, then retry"
    }
}

@main
struct BasaltStreamerApp {
    static func main() async {
        // The M7 management app captures this process through pipes. Keep
        // operational lines live instead of block-buffering them until exit.
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        if CommandLine.arguments.count >= 2,
           CommandLine.arguments[1] == "runtime-link-selftest" {
            await RuntimeLinkSelfTest.run(Array(CommandLine.arguments.dropFirst(2)))
            return
        }
        if CommandLine.arguments.count >= 2,
           CommandLine.arguments[1] == "audio-loopback-selftest" {
            AudioLoopbackSelfTest.run(Array(CommandLine.arguments.dropFirst(2)))
            return
        }

        let options: StreamerOptions?
        do {
            options = try StreamerOptions.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
        guard let options else {
            print(StreamerOptions.usage)
            return
        }

        if options.listAudioDevices {
            do {
                let devices = try GameAudioDeviceDiscovery.inputDevices()
                if devices.isEmpty {
                    print("No CoreAudio input devices found.")
                } else {
                    for device in devices {
                        print("\(device.name)\t\(Int(device.sampleRate)) Hz")
                    }
                }
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }

        do {
            try await run(options)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            fputs("(If this is a capture error, grant Screen Recording permission to your terminal in System Settings → Privacy & Security.)\n", stderr)
            exit(1)
        }
    }

    static func run(_ options: StreamerOptions) async throws {
        // Handle SIGINT/SIGTERM from the start: --route-audio switches the Mac
        // output and --wired opens adb forwards before the headset handshake,
        // and the manager may stop a session that never finished starting.
        let shutdown = ShutdownSignals()
        let systemState = SystemStateRestorer()
        do {
            try await runSession(options, shutdown: shutdown, systemState: systemState)
        } catch {
            systemState.restore()
            throw error
        }
    }

    private static func runSession(
        _ options: StreamerOptions,
        shutdown: ShutdownSignals,
        systemState: SystemStateRestorer
    ) async throws {
        // Runtime mode replaces desktop capture with frames the BasaltVR
        // OpenXR runtime submits over the control socket.
        let runtimeMode = options.runtimeControlFile != nil
        let capture = ScreenCapture()
        if !runtimeMode {
            try await capture.prepare(fps: options.fps)
        }
        // Balanced-resolution, near-native Quest aspect ratio for the temporary
        // monoscopic desktop preview. The real OpenXR path supplies native
        // per-eye game textures through RuntimeStereoComposer instead.
        let previewPerEyeWidth = options.perEyeResolution.width
        let previewPerEyeHeight = options.perEyeResolution.height
        let headsetMode = options.discover || options.wired
        let stereoComposer = (headsetMode && !runtimeMode)
            ? try StereoFrameComposer(sourceWidth: capture.width, sourceHeight: capture.height,
                                      perEyeWidth: previewPerEyeWidth,
                                      height: previewPerEyeHeight,
                                      contentScale: 0.84,
                                      convergenceShiftPixels: 12)
            : nil
        let encodedWidth = runtimeMode
            ? previewPerEyeWidth * 2
            : (stereoComposer?.outputWidth ?? capture.width)
        let encodedHeight = runtimeMode
            ? previewPerEyeHeight
            : (stereoComposer?.height ?? capture.height)
        let negotiateViewWidth = runtimeMode
            ? previewPerEyeWidth
            : (stereoComposer?.perEyeWidth ?? capture.width)
        let negotiateViewHeight = runtimeMode
            ? previewPerEyeHeight
            : (stereoComposer?.height ?? capture.height)

        let server = try TCPServer(port: options.port, bindHost: options.bindHost)
        server.onFailure = { error in
            fputs("server error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        let alvrVideo = AlvrVideoStreamRouter()
        var gameAudio: GameAudioCapture?
        if let audioDeviceName = options.audioDeviceName {
            if options.routeAudioToCaptureDevice {
                let device = try GameAudioDeviceDiscovery.matchingInputDevice(audioDeviceName)
                let route = try GameAudioOutputRoute(to: device)
                systemState.audioOutputRoute = route
                print("Game audio output routed to \(device.name) for this session")
            }
            let capture = try GameAudioCapture(deviceNameContains: audioDeviceName)
            capture.onPCM16 = { pcm in
                alvrVideo.sendAudioPCM16(pcm)
            }
            try capture.start()
            gameAudio = capture
            print("Game audio capture ready: \(capture.device.name), 48000 Hz stereo PCM16")
        }
        let latencyReporter = PipelineLatencyReporter()
        let headsetLatencyReporter = HeadsetLatencyReporter()
        let calibrationLogGate = CalibrationLogGate()
        let encoder = try H264Encoder(
            width: encodedWidth,
            height: encodedHeight,
            fps: options.fps,
            bitrate: options.megabits * 1_000_000) { annexB, isKeyframe, capturePTS in
                if !runtimeMode {
                    latencyReporter.recordEncoded(capturePTS: capturePTS)
                }
                server.broadcast(annexB)
                if runtimeMode {
                    guard let runtimeTrackingTimestamp =
                            H264Encoder.questTrackingTimestampNanoseconds(from: capturePTS) else {
                        fputs("encoded runtime frame lost its Quest tracking timestamp\n", stderr)
                        return
                    }
                    alvrVideo.send(
                        annexB: annexB, isIDR: isKeyframe,
                        timestampNanoseconds: runtimeTrackingTimestamp)
                } else {
                    alvrVideo.send(annexB: annexB, isIDR: isKeyframe)
                }
            }
        encoder.onError = { error in
            fputs("encoder error: \(error.localizedDescription)\n", stderr)
        }
        let streamRecovery = StreamRecoveryController(
            encoder: encoder,
            minimumIDRIntervalNanoseconds: options.wired
                ? 1_000_000_000 : 2_000_000_000)

        // A client joining mid-stream needs an IDR frame before it can
        // decode anything.
        server.onClientConnected = { encoder.forceKeyframe() }
        let droppedFrames = ThrottledEventLog()
        let runtimeWrapFailures = ThrottledEventLog()
        capture.onFrame = { pixelBuffer, pts in
            // Avoid spending GPU time composing a stereo frame that the
            // bounded encoder cannot accept. `encode` repeats this check
            // atomically in case a slot changes between here and submission.
            guard encoder.canAcceptFrame else {
                droppedFrames.recordDroppedFrame(stage: "encoder busy (capture)")
                return
            }

            let frame: CVPixelBuffer
            if let stereoComposer {
                guard let composed = stereoComposer.compose(pixelBuffer) else { return }
                frame = composed
            } else {
                frame = pixelBuffer
            }
            guard encoder.encode(frame, pts: pts) else {
                droppedFrames.recordDroppedFrame(stage: "encoder busy (capture)")
                return
            }
        }
        capture.onError = { error in
            fputs("capture stopped: \(error.localizedDescription)\n", stderr)
            raise(SIGTERM)
        }

        var runtimeLink: RuntimeLink?
        if let controlFile = options.runtimeControlFile {
            let runtimeComposer = try RuntimeStereoComposer(
                perEyeWidth: previewPerEyeWidth, height: previewPerEyeHeight)
            let link = try RuntimeLink(
                controlFilePath: controlFile,
                recommendedViewSize: options.perEyeResolution)
            link.onHello = { sessionId, renderer in
                print("OpenXR runtime connected (session \(sessionId), \(renderer))")
                encoder.forceKeyframe()
            }
            link.onTeardown = {
                print("OpenXR runtime disconnected")
            }
            link.onProtocolError = { reason in
                fputs(RuntimeLink.connectionRefusedLogPrefix + reason + "\n", stderr)
            }
            link.onFrame = { frame, consumption in
                guard encoder.canAcceptFrame else {
                    droppedFrames.recordDroppedFrame(stage: "encoder busy (runtime)")
                    consumption.complete()
                    return
                }
                func wrap(_ view: RuntimeLink.FrameView) -> CVPixelBuffer? {
                    var maybeBuffer: Unmanaged<CVPixelBuffer>?
                    let status = CVPixelBufferCreateWithIOSurface(
                        kCFAllocatorDefault, view.surface, nil, &maybeBuffer)
                    guard status == kCVReturnSuccess else {
                        runtimeWrapFailures.record { _ in
                            "runtime IOSurface wrap failed: CVPixelBuffer status \(status), "
                                + "DXGI format \(view.dxgiFormat), IOSurface fourcc "
                                + String(format: "0x%08x", IOSurfaceGetPixelFormat(view.surface))
                        }
                        return nil
                    }
                    return maybeBuffer?.takeRetainedValue()
                }
                guard let firstView = frame.views.first,
                      let lastView = frame.views.last,
                      let left = wrap(firstView),
                      let right = wrap(lastView) else {
                    consumption.complete()
                    return
                }
                guard let pts = H264Encoder.presentationTime(
                        questTrackingTimestampNanoseconds:
                            frame.questTrackingTimestampNanoseconds) else {
                    fputs("runtime supplied an invalid Quest tracking timestamp\n", stderr)
                    consumption.complete()
                    return
                }
                // A zero-sized rect tells the compositor the view covers the
                // whole image, so a malformed rect degrades to the previous
                // full-image behaviour.
                func rectVector(
                    _ rect: (x: Int32, y: Int32, width: Int32, height: Int32)
                ) -> SIMD4<Float> {
                    guard rect.width > 0, rect.height > 0 else {
                        return SIMD4<Float>(0, 0, 0, 0)
                    }
                    return SIMD4<Float>(
                        Float(rect.x), Float(rect.y),
                        Float(rect.width), Float(rect.height))
                }
                let leftRect = rectVector(firstView.rect)
                let rightRect = rectVector(lastView.rect)
                let scheduled = runtimeComposer.composeAsync(
                    left: left, right: right,
                    leftRect: leftRect, rightRect: rightRect) {
                    composed in
                    // Metal has finished reading the runtime swapchains. Let
                    // Beat Saber render its next frame before VideoToolbox
                    // finishes with this compositor output.
                    consumption.complete()
                    guard let composed else { return }
                    guard encoder.encode(
                            composed.pixelBuffer, pts: pts,
                            completion: { _ = composed }) else {
                        droppedFrames.recordDroppedFrame(stage: "encoder busy (runtime)")
                        return
                    }
                }
                guard scheduled else {
                    droppedFrames.recordDroppedFrame(stage: "compositor busy (runtime)")
                    consumption.complete()
                    return
                }
            }
            runtimeLink = link
        }

        var discovery: AlvrDiscoveryListener?
        if options.discover {
            let probeGate = AlvrControlProbeGate()
            discovery = try AlvrDiscoveryListener { beacon, ip in
                let clientKey = "\(beacon.hostname)@\(ip)"
                guard probeGate.begin(clientKey: clientKey) else { return }
                let protocolHex = String(format: "%016llx", beacon.protocolId)
                print("ALVR headset '\(beacon.hostname)' announced itself from \(ip) "
                    + "(protocol id \(protocolHex)); probing TCP control handshake…")
                Task {
                    var succeeded = false
                    defer { probeGate.finish(clientKey: clientKey, succeeded: succeeded) }
                    do {
                        let connected = try await connectHeadset(
                            host: ip, expectedProtocolId: beacon.protocolId, wired: false,
                            requestedViewWidth: negotiateViewWidth,
                            requestedViewHeight: negotiateViewHeight,
                            stereoComposer: stereoComposer, options: options,
                            alvrVideo: alvrVideo,
                            runtimeLink: runtimeLink,
                            headsetLatencyReporter: headsetLatencyReporter,
                            calibrationLogGate: calibrationLogGate,
                            encoder: encoder,
                            streamRecovery: streamRecovery)
                        probeGate.retain(connected.handshake, clientKey: clientKey)
                        succeeded = true
                    } catch {
                        fputs("ALVR control probe for \(ip) failed: \(error.localizedDescription)\n", stderr)
                    }
                }
            }
        } else if options.wired {
            let connection = try AlvrWiredConnection.setup()
            systemState.wiredConnection = connection
            print("USB Quest \(connection.serial) is authorized; adb control/video forwards are ready.")
        }

        func tearDown() async {
            print("\nShutting down…")
            discovery?.stop()
            runtimeLink?.stop()
            gameAudio?.stop()
            systemState.restore()
            if !runtimeMode {
                await capture.stop()
            }
            server.stop()
        }

        try await server.start()
        if options.wired {
            var lastError: Error?
            for attempt in 1...10 {
                do {
                    // nil (shutdown requested) also ends the retry loop.
                    _ = try await shutdown.unlessRequested {
                        try await connectHeadset(
                            host: "127.0.0.1", expectedProtocolId: nil, wired: true,
                            requestedViewWidth: negotiateViewWidth,
                            requestedViewHeight: negotiateViewHeight,
                            stereoComposer: stereoComposer, options: options,
                            alvrVideo: alvrVideo,
                            runtimeLink: runtimeLink,
                            headsetLatencyReporter: headsetLatencyReporter,
                            calibrationLogGate: calibrationLogGate,
                            encoder: encoder,
                            streamRecovery: streamRecovery)
                    }
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if error is AlvrTrackingTimeoutError { break }
                    guard attempt < 10 else { break }
                    fputs("ALVR USB handshake attempt \(attempt) failed; retrying…\n", stderr)
                    let slept: Void? = try await shutdown.unlessRequested {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    if slept == nil { break }
                }
            }
            if let lastError, !shutdown.isRequested {
                throw BasaltError("Could not start wired ALVR session: \(lastError.localizedDescription)")
            }
        }
        guard !shutdown.isRequested else {
            await tearDown()
            return
        }
        if let runtimeLink {
            try await runtimeLink.start()
        } else {
            try await capture.start()
        }

        let sourceLine = runtimeMode
            ? "OpenXR runtime frames via \(options.runtimeControlFile ?? "?") (BASALT_CONTROL)"
            : "capturing \(capture.width)x\(capture.height) @ \(options.fps) fps"
        print("""
        BasaltVR streamer — \(runtimeMode ? "M4 tracked OpenXR source" : "M1 capture") + M2/M6 ALVR media
          \(sourceLine)
          encoding \(encodedWidth)x\(encodedHeight)\(runtimeMode || stereoComposer != nil ? " side-by-side stereo" : "")
          H.264 High \(options.megabits) Mbps, VideoToolbox low-latency mode
          listening on tcp://\(options.bindHost):\(server.port ?? options.port)
        """)
        if options.bindIsLoopback {
            print("  local-only (pass --bind <ip> to accept LAN clients)")
        } else {
            print("  ⚠️  bound to \(options.bindHost): anyone on your network can connect and watch this screen")
        }
        if options.discover {
            print("  ALVR: discovery/control \(AlvrDiscoveryListener.alvrPort), UDP video \(AlvrVideoStreamSender.defaultPort)")
        } else if options.wired {
            print("  ALVR: USB via adb, TCP control \(AlvrDiscoveryListener.alvrPort)/video \(AlvrVideoStreamSender.defaultPort)")
        }
        if headsetMode {
            print("  stream settings: \(previewPerEyeWidth)x\(previewPerEyeHeight) per eye, "
                  + "\(options.latencyPreset.rawValue) latency")
            print("  game audio: " + (gameAudio.map {
                "\($0.device.name), 48 kHz stereo PCM16"
            } ?? "disabled (pass --audio-device 'BlackHole 2ch')"))
        }
        print("""

        View the stream:
          ffplay -probesize 32 -analyzeduration 0 -fflags nocache -flags low_delay -framedrop -f h264 tcp://127.0.0.1:\(options.port)

        Ctrl-C to stop.
        """)

        // Capture and networking run on their own queues; park main until
        // SIGINT/SIGTERM, then tear down cleanly (stops the capture stream
        // and closes client sockets instead of dying mid-write).
        await shutdown.wait()
        await tearDown()
    }

    private static func connectHeadset(
        host: String,
        expectedProtocolId: UInt64?,
        wired: Bool,
        requestedViewWidth: Int,
        requestedViewHeight: Int,
        stereoComposer: StereoFrameComposer?,
        options: StreamerOptions,
        alvrVideo: AlvrVideoStreamRouter,
        runtimeLink: RuntimeLink?,
        headsetLatencyReporter: HeadsetLatencyReporter,
        calibrationLogGate: CalibrationLogGate,
        encoder: H264Encoder,
        streamRecovery: StreamRecoveryController
    ) async throws -> (handshake: AlvrSessionHandshakeResult, displayName: String) {
        let handshake = try await AlvrControlProbe.negotiateSession(
            host: host,
            requestedViewWidth: UInt32(requestedViewWidth),
            requestedViewHeight: UInt32(requestedViewHeight),
            preferredRefreshRate: Float(options.fps),
            latencyPreset: options.latencyPreset,
            wired: wired)
        guard case .accepted(let protocolId, let displayName, _, let capabilities) =
                handshake.clientState else {
            throw BasaltError("ALVR headset is in standby")
        }
        if let expectedProtocolId, protocolId != expectedProtocolId {
            throw BasaltError("ALVR protocol mismatch between discovery and control packet")
        }
        if let capabilities {
            let rates = capabilities.refreshRates.map { String(format: "%.0f", $0) }
                .joined(separator: ", ")
            print("  headset capabilities: \(capabilities.width)x\(capabilities.height) per eye; "
                + "refresh rates [\(rates)] Hz; microphone \(capabilities.microphoneSampleRate) Hz")
            print("  codecs: H.264 high-profile=\(capabilities.supportsHighProfile), "
                + "10-bit=\(capabilities.supports10Bit), AV1=\(capabilities.supportsAV1)")
            let negotiated = try requireNegotiatedSettings(handshake.negotiatedSettings)
            print("  prepared stereo desktop preview: \(negotiated.width)x\(negotiated.height) per eye "
                + "@ \(String(format: "%.0f", negotiated.refreshRate)) Hz, H.264")
        } else {
            print("  headset did not provide streaming capabilities")
        }
        guard handshake.streamReady else {
            throw BasaltError("Quest did not report StreamReady")
        }

        handshake.onRequestIDR { streamRecovery.requestIDR() }
        handshake.onViewsConfig { config in
            stereoComposer?.updateViews(config)
            runtimeLink?.publishViewsConfig(config)
            if calibrationLogGate.shouldLog(ipdMeters: config.ipdMeters) {
                let ipd = String(format: "%.1f", config.ipdMeters * 1_000)
                print("  calibrated desktop preview from headset IPD/FOV (IPD \(ipd) mm)")
            }
        }
        handshake.onButtons { entries in
            runtimeLink?.publishButtons(entries)
        }
        handshake.onActiveInteractionProfile { deviceID, profileID in
            runtimeLink?.publishInteractionProfile(deviceID: deviceID, profileID: profileID)
        }
        handshake.onDisconnect {
            runtimeLink?.resetInputs()
        }
        let transport: AlvrStreamTransport = wired ? .tcp : .udp
        let videoSender = try AlvrVideoStreamSender(host: host, transport: transport)
        let transportReporter = VideoTransportReporter(name: wired ? "USB" : "Wi-Fi")
        let audioReporter = AudioTransportReporter(name: wired ? "USB" : "Wi-Fi")
        let adaptiveBitrate = wired ? nil : AdaptiveVideoBitrateController(
            configuredBitrate: options.megabits * 1_000_000,
            targetFramesPerSecond: options.fps)
        func applyAdaptiveBitrate(_ bitrate: Int) {
            guard encoder.updateAverageBitrate(bitrate) else { return }
            print("  Wi-Fi congestion control: encoder adjusted to "
                  + String(format: "%.1f Mbps", Double(bitrate) / 1_000_000))
        }
        videoSender.onError = { error in
            fputs("ALVR stream send error: \(error.localizedDescription)\n", stderr)
        }
        videoSender.onFrameSent = { report in
            transportReporter.record(report)
        }
        videoSender.onAudioSent = { report in
            audioReporter.record(report)
        }
        let networkDrops = ThrottledEventLog()
        videoSender.onFrameDropped = {
            networkDrops.record { "ALVR network busy: dropped \($0) stale video frame(s)" }
        }
        videoSender.onAudioDropped = {
            audioReporter.recordDrop()
        }
        videoSender.onCongestion = {
            // Packet loss corrupts the current H.264 access unit. Ask
            // VideoToolbox for a fresh recovery point. Repeated pressure also
            // lowers the encoder target before another large IDR is emitted.
            if let bitrate = adaptiveBitrate?.recordTransportCongestion() {
                applyAdaptiveBitrate(bitrate)
            }
            streamRecovery.requestIDR()
        }
        videoSender.onStatistics = { statistics in
            headsetLatencyReporter.record(statistics)
            if let bitrate = adaptiveBitrate?.recordClientStatistics(statistics) {
                applyAdaptiveBitrate(bitrate)
            }
        }
        videoSender.onHeadPose = { timestamp, pose in
            runtimeLink?.publishHeadPose(
                timestampNanoseconds: timestamp, pose: pose)
        }
        videoSender.onControllerMotion = { timestamp, hand, motion in
            runtimeLink?.publishControllerMotion(
                timestampNanoseconds: timestamp, hand: hand, motion: motion)
        }
        videoSender.onControllerMask = { timestamp, activeMask in
            runtimeLink?.publishControllerMask(
                timestampNanoseconds: timestamp, activeMask: activeMask)
        }
        runtimeLink?.onHaptic { [weak videoSender] hand, duration, frequency, amplitude in
            videoSender?.sendHaptics(
                hand: hand, durationNanoseconds: duration,
                frequency: frequency, amplitude: amplitude)
        }
        videoSender.start()

        // StreamReady means the client's control state advanced, but an ALVR
        // client left stale by a prior wired session can accept both TCP
        // connections without sending its tracking uplink. Video headers must
        // use the Quest clock, so the router intentionally drops frames until
        // that uplink exists. Treat tracking as part of connection readiness
        // and let the wired retry loop replace a half-open session.
        let trackingDeadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while videoSender.timestampForVideoFrame() == nil {
            guard DispatchTime.now().uptimeNanoseconds < trackingDeadline else {
                throw AlvrTrackingTimeoutError()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        videoSender.onTrackingReady { streamRecovery.forceIDR() }
        alvrVideo.install(videoSender, controlSession: handshake)
        print("ALVR control accepted by '\(displayName)': StreamConfig sent, "
            + "StartStream sent, and Quest replied StreamReady.")
        if wired {
            print("  ALVR TCP video stream connected through USB at \(host):\(AlvrVideoStreamSender.defaultPort); "
                + "tracking uplink ready; sending H.264 frames.")
        } else {
            print("  ALVR UDP video stream connected to \(host):\(AlvrVideoStreamSender.defaultPort); "
                + "sending H.264 desktop frames.")
        }
        return (handshake, displayName)
    }
}

private func requireNegotiatedSettings(_ settings: AlvrNegotiatedSettings?) throws
    -> AlvrNegotiatedSettings {
    guard let settings else { throw BasaltError("ALVR negotiation did not produce streaming settings") }
    return settings
}

/// Periodically reports the local capture-to-encode portion of the pipeline.
/// Headset decode, Wi-Fi transit, and display scanout happen after this value,
/// so it gives us a useful boundary when diagnosing real-device latency.
private final class PipelineLatencyReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let hostClock = CMClockGetHostTimeClock()
    private var sampleCount = 0
    private var totalMilliseconds = 0.0
    private var maximumMilliseconds = 0.0
    private var intervalStart: DispatchTime?
    private var nextReport: DispatchTime?

    func recordEncoded(capturePTS: CMTime) {
        let elapsed = CMTimeSubtract(CMClockGetTime(hostClock), capturePTS)
        let milliseconds = CMTimeGetSeconds(elapsed) * 1_000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 10_000 else { return }
        let now = DispatchTime.now()

        lock.lock()
        if intervalStart == nil {
            intervalStart = now
            nextReport = now + .seconds(5)
        }
        sampleCount += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        guard let nextReport, now >= nextReport, let intervalStart else {
            lock.unlock()
            return
        }
        let average = totalMilliseconds / Double(sampleCount)
        let maximum = maximumMilliseconds
        let elapsedSeconds = Double(now.uptimeNanoseconds &- intervalStart.uptimeNanoseconds)
            / 1_000_000_000
        let framesPerSecond = Double(sampleCount) / elapsedSeconds
        sampleCount = 0
        totalMilliseconds = 0
        maximumMilliseconds = 0
        self.intervalStart = now
        self.nextReport = now + .seconds(5)
        lock.unlock()

        print("  local encode: " + String(format: "%.1f fps; ", framesPerSecond)
              + String(format: "capture→encode %.1f ms average, %.1f ms max",
                       average, maximum))
    }
}

/// Aggregates ALVR statistics measured on the Quest. Unlike the local metric,
/// total pipeline latency starts when headset tracking is sampled and ends at
/// the target display vsync, spanning server, network, decode, and compositor.
private final class HeadsetLatencyReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleCount = 0
    private var totalMilliseconds = 0.0
    private var maximumMilliseconds = 0.0
    private var decodeMilliseconds = 0.0
    private var decoderQueueMilliseconds = 0.0
    private var vsyncQueueMilliseconds = 0.0
    private var frameIntervalMilliseconds = 0.0
    private var frameIntervalSampleCount = 0
    private var hasSeenFrameInterval = false
    private var nextReport: DispatchTime?

    func record(_ statistics: AlvrClientStatistics) {
        let milliseconds = Double(statistics.totalPipelineLatencyNanoseconds) / 1_000_000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 10_000 else { return }

        lock.lock()
        if nextReport == nil {
            nextReport = DispatchTime.now() + .seconds(2)
        }
        sampleCount += 1
        totalMilliseconds += milliseconds
        maximumMilliseconds = max(maximumMilliseconds, milliseconds)
        decodeMilliseconds += Double(statistics.videoDecodeNanoseconds) / 1_000_000
        decoderQueueMilliseconds += Double(statistics.videoDecoderQueueNanoseconds) / 1_000_000
        vsyncQueueMilliseconds += Double(statistics.vsyncQueueNanoseconds) / 1_000_000
        if hasSeenFrameInterval {
            frameIntervalMilliseconds += Double(statistics.frameIntervalNanoseconds) / 1_000_000
            frameIntervalSampleCount += 1
        } else {
            // The first interval is measured from client statistics-manager
            // construction, not from a prior displayed stream frame.
            hasSeenFrameInterval = true
        }
        guard let nextReport, DispatchTime.now() >= nextReport else {
            lock.unlock()
            return
        }
        let count = Double(sampleCount)
        let average = totalMilliseconds / count
        let maximum = maximumMilliseconds
        let decode = decodeMilliseconds / count
        let decoderQueue = decoderQueueMilliseconds / count
        let vsyncQueue = vsyncQueueMilliseconds / count
        let averageFrameInterval = frameIntervalSampleCount > 0
            ? frameIntervalMilliseconds / Double(frameIntervalSampleCount) : 0
        let framesPerSecond = averageFrameInterval > 0 ? 1_000 / averageFrameInterval : nil
        sampleCount = 0
        totalMilliseconds = 0
        maximumMilliseconds = 0
        decodeMilliseconds = 0
        decoderQueueMilliseconds = 0
        vsyncQueueMilliseconds = 0
        frameIntervalMilliseconds = 0
        frameIntervalSampleCount = 0
        self.nextReport = .now() + .seconds(2)
        lock.unlock()

        print(StreamReport.questLine(
            framesPerSecond: framesPerSecond,
            averageLatencyMilliseconds: average,
            maximumLatencyMilliseconds: maximum,
            decodeMilliseconds: decode,
            decoderQueueMilliseconds: decoderQueue,
            vsyncQueueMilliseconds: vsyncQueue))
    }
}

/// Reports what Basalt actually handed to the ALVR stream socket. Keeping
/// this separate from Quest decode statistics distinguishes a slow USB/UDP
/// write from a client decoder or compositor stall.
private final class VideoTransportReporter: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var frameCount = 0
    private var wireBytes = 0
    private var largestAccessUnitBytes = 0
    private var maximumSendMilliseconds = 0.0
    private var idrCount = 0
    private var repeatedTimestampCount = 0
    private var lastTimestampNanoseconds: UInt64?
    private var intervalStart: DispatchTime?
    private var nextReport: DispatchTime?

    init(name: String) {
        self.name = name
    }

    func record(_ report: AlvrVideoSendReport) {
        let now = DispatchTime.now()
        let sendMilliseconds = Double(report.durationNanoseconds) / 1_000_000

        lock.lock()
        if intervalStart == nil {
            intervalStart = now
            nextReport = now + .seconds(2)
        }
        frameCount += 1
        wireBytes += report.wireBytes
        largestAccessUnitBytes = max(largestAccessUnitBytes, report.accessUnitBytes)
        maximumSendMilliseconds = max(maximumSendMilliseconds, sendMilliseconds)
        if report.isIDR { idrCount += 1 }
        if report.timestampNanoseconds == lastTimestampNanoseconds {
            repeatedTimestampCount += 1
        }
        lastTimestampNanoseconds = report.timestampNanoseconds
        guard let nextReport, now >= nextReport, let intervalStart else {
            lock.unlock()
            return
        }
        let elapsedSeconds = Double(now.uptimeNanoseconds &- intervalStart.uptimeNanoseconds)
            / 1_000_000_000
        let framesPerSecond = Double(frameCount) / elapsedSeconds
        let megabitsPerSecond = Double(wireBytes) * 8 / elapsedSeconds / 1_000_000
        let largestKilobytes = Double(largestAccessUnitBytes) / 1_024
        let maximumSend = maximumSendMilliseconds
        let idrs = idrCount
        let repeatedTimestamps = repeatedTimestampCount
        frameCount = 0
        wireBytes = 0
        largestAccessUnitBytes = 0
        maximumSendMilliseconds = 0
        idrCount = 0
        repeatedTimestampCount = 0
        self.intervalStart = now
        self.nextReport = now + .seconds(2)
        lock.unlock()

        print(StreamReport.videoSendLine(
            transport: name,
            framesPerSecond: framesPerSecond,
            megabitsPerSecond: megabitsPerSecond,
            maximumWriteMilliseconds: maximumSend,
            largestFrameKibibytes: largestKilobytes,
            idrCount: idrs,
            repeatedTimestamps: repeatedTimestamps))
    }
}

private final class AudioTransportReporter: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var blocks = 0
    private var pcmBytes = 0
    private var wireBytes = 0
    private var maximumSendMilliseconds = 0.0
    private var drops = 0
    private var intervalStart: DispatchTime?
    private var nextReport: DispatchTime?

    init(name: String) { self.name = name }

    func record(_ report: AlvrAudioSendReport) {
        let now = DispatchTime.now()
        lock.lock()
        if intervalStart == nil {
            intervalStart = now
            nextReport = now + .seconds(2)
        }
        blocks += 1
        pcmBytes += report.pcmBytes
        wireBytes += report.wireBytes
        maximumSendMilliseconds = max(
            maximumSendMilliseconds,
            Double(report.durationNanoseconds) / 1_000_000)
        guard let nextReport, now >= nextReport, let intervalStart else {
            lock.unlock()
            return
        }
        let seconds = Double(now.uptimeNanoseconds &- intervalStart.uptimeNanoseconds)
            / 1_000_000_000
        let blocksPerSecond = Double(blocks) / seconds
        let pcmMegabits = Double(pcmBytes) * 8 / seconds / 1_000_000
        let wireMegabits = Double(wireBytes) * 8 / seconds / 1_000_000
        let maximumSend = maximumSendMilliseconds
        let dropped = drops
        blocks = 0
        pcmBytes = 0
        wireBytes = 0
        maximumSendMilliseconds = 0
        drops = 0
        self.intervalStart = now
        self.nextReport = now + .seconds(2)
        lock.unlock()

        print(StreamReport.audioSendLine(
            transport: name,
            blocksPerSecond: blocksPerSecond,
            pcmMegabits: pcmMegabits,
            wireMegabits: wireMegabits,
            maximumWriteMilliseconds: maximumSend,
            drops: dropped))
    }

    func recordDrop() {
        lock.lock()
        drops += 1
        let count = drops
        lock.unlock()
        if count == 1 || count.isMultiple(of: 200) {
            fputs("ALVR audio busy: dropped \(count) self-contained PCM block(s)\n", stderr)
        }
    }
}

/// Coordinates Quest decoder feedback with VideoToolbox. IDR requests are
/// rate-limited because a saturated decoder asks for recovery repeatedly; an
/// unbounded keyframe response makes saturation substantially worse.
private final class StreamRecoveryController: @unchecked Sendable {
    private weak var encoder: H264Encoder?
    private let minimumIDRIntervalNanoseconds: UInt64
    private let lock = NSLock()
    private var lastIDRNanoseconds: UInt64 = 0

    init(encoder: H264Encoder, minimumIDRIntervalNanoseconds: UInt64) {
        self.encoder = encoder
        self.minimumIDRIntervalNanoseconds = minimumIDRIntervalNanoseconds
    }

    func requestIDR() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard lastIDRNanoseconds == 0
                || now &- lastIDRNanoseconds >= minimumIDRIntervalNanoseconds else {
            lock.unlock()
            return
        }
        lastIDRNanoseconds = now
        lock.unlock()
        encoder?.forceKeyframe()
    }

    func forceIDR() {
        lock.lock()
        lastIDRNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        encoder?.forceKeyframe()
    }

}

private final class CalibrationLogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasLogged = false

    func shouldLog(ipdMeters: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasLogged else { return false }
        hasLogged = true
        return true
    }
}

/// Observes SIGINT and SIGTERM from creation, so a signal that arrives
/// while the session is still starting is never lost.
private final class ShutdownSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sources: [DispatchSourceSignal] = []

    init() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in self?.fire() }
            source.resume()
            sources.append(source)
        }
    }

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    /// Suspends until shutdown is requested; returns at once if it already was.
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !requested else {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Runs `operation` until it finishes, or returns nil as soon as shutdown
    /// is requested. The operation is then cancelled and abandoned: blocking
    /// handshake sockets do not observe cancellation, and the process exits
    /// once teardown completes.
    func unlessRequested<T>(_ operation: @escaping () async throws -> T) async throws -> T? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            let outcome = FirstOutcome(continuation)
            let task = Task {
                do {
                    outcome.resume(with: .success(try await operation()))
                } catch {
                    outcome.resume(with: .failure(error))
                }
            }
            Task {
                await self.wait()
                task.cancel()
                outcome.resume(with: .success(nil))
            }
        }
    }

    private func fire() {
        lock.lock()
        requested = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }
}

/// Resumes a continuation with whichever result arrives first.
private final class FirstOutcome<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Mac state a session changes outside this process. Restored on every exit
/// path, including a startup that failed or was interrupted.
private final class SystemStateRestorer: @unchecked Sendable {
    var audioOutputRoute: GameAudioOutputRoute?
    var wiredConnection: AlvrWiredConnection?

    func restore() {
        if let audioOutputRoute {
            self.audioOutputRoute = nil
            do {
                try audioOutputRoute.restore()
                print("Restored the previous Mac audio output")
            } catch {
                fputs("Could not restore the previous Mac audio output: "
                    + "\(error.localizedDescription)\n", stderr)
            }
        }
        wiredConnection?.stop()
    }
}
