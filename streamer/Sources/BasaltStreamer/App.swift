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
        if CommandLine.arguments.count >= 2,
           CommandLine.arguments[1] == "encoder-bench" {
            EncoderBenchmark.run(Array(CommandLine.arguments.dropFirst(2)))
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
        let alvrVideo = AlvrVideoStreamRouter(codec: options.codec)
        var audioOutputRoute: GameAudioOutputRoute?
        var gameAudio: GameAudioCapture?
        if let audioDeviceName = options.audioDeviceName {
            if options.routeAudioToCaptureDevice {
                let device = try GameAudioDeviceDiscovery.matchingInputDevice(audioDeviceName)
                let route = try GameAudioOutputRoute(to: device)
                audioOutputRoute = route
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
        let pipelineStatistics = PipelineStatistics()
        // Keeps the headset's reference chain intact (H.264 and HEVC alike):
        // frames are skipped before encoding while the ALVR transport is
        // busy, and after any lost access unit only an IDR is sent until one
        // gets through.
        let videoRecovery = VideoLossRecoveryGate(
            clientRequestThrottleNanoseconds: options.wired ? 100_000_000 : 250_000_000,
            recoveryKeyframeMinimumGapNanoseconds: options.wired ? 0 : 250_000_000)
        let videoLossLog = ThrottledEventLog()
        let noteVideoLoss: @Sendable (String) -> Void = { reason in
            guard videoRecovery.frameLost() else { return }
            videoLossLog.record {
                "ALVR video: \(reason); holding P-frames until a recovery IDR is sent "
                    + "(\($0) loss(es) so far)"
            }
        }
        // ALVR's client keeps showing its last decoded picture when no video
        // arrives. While the game submits nothing, the filler only repairs
        // what the headset shows: the last game image when it was not
        // delivered or the chain broke, or black before the first game frame.
        let idleFiller = (runtimeMode && headsetMode)
            ? RuntimeIdleVideoFiller<RuntimeStereoComposer.ComposedFrame>() : nil
        let encoder = try VideoEncoder(
            width: encodedWidth,
            height: encodedHeight,
            fps: options.fps,
            bitrate: options.megabits * 1_000_000,
            keyframeIntervalSeconds: options.keyframeIntervalSeconds,
            codec: options.codec,
            entropyMode: options.entropyMode) { annexB, isKeyframe, capturePTS in
                if !runtimeMode {
                    latencyReporter.recordEncoded(capturePTS: capturePTS)
                }
                server.broadcast(annexB)
                // A P-frame after a lost access unit references a picture the
                // Quest never got (`Frame num gap is not allowed`).
                guard videoRecovery.admit(isIDR: isKeyframe) else {
                    pipelineStatistics.recordDrop(.awaitingIDR)
                    return
                }
                let delivered: Bool
                if runtimeMode {
                    guard let presentation =
                            H264Encoder.questTrackingTimestampNanoseconds(from: capturePTS) else {
                        fputs("encoded runtime frame lost its Quest tracking timestamp\n", stderr)
                        noteVideoLoss("an encoded frame lost its Quest tracking timestamp")
                        return
                    }
                    // A repeated game image is encoded at a later presentation
                    // time but keeps its own frame's tracking timestamp, so the
                    // client reprojects it with the pose it was rendered for.
                    let runtimeTrackingTimestamp = idleFiller?.videoTimestamp(
                        forPresentationNanoseconds: presentation) ?? presentation
                    delivered = alvrVideo.send(
                        annexB: annexB, isIDR: isKeyframe,
                        timestampNanoseconds: runtimeTrackingTimestamp)
                    if delivered, alvrVideo.hasStream {
                        idleFiller?.recordDelivered(presentationNanoseconds: presentation)
                    }
                } else {
                    delivered = alvrVideo.send(annexB: annexB, isIDR: isKeyframe)
                }
                if !delivered {
                    noteVideoLoss("an encoded frame could not be sent")
                }
            }
        encoder.onError = { error in
            fputs("encoder error: \(error.localizedDescription)\n", stderr)
        }
        encoder.onFrameEncoded = { duration, dropped in
            pipelineStatistics.recordEncode(durationNanoseconds: duration, droppedByEncoder: dropped)
        }
        // A client joining mid-stream needs an IDR frame before it can
        // decode anything.
        server.onClientConnected = { encoder.forceKeyframe() }
        let droppedFrames = ThrottledEventLog()
        // The throttled log shows the first and every 120th drop; the
        // pipeline line counts every drop per interval.
        let noteDrop: @Sendable (String, PipelineStatistics.DropStage) -> Void = { stage, kind in
            droppedFrames.recordDroppedFrame(stage: stage)
            pipelineStatistics.recordDrop(kind)
        }
        let runtimeWrapFailures = ThrottledEventLog()
        // While no ALVR client is attached (Quest asleep, ALVR closed, or
        // still reconnecting) and nobody watches the local preview, frames
        // are dropped before any GPU or encoder work.
        let hasVideoConsumer: @Sendable () -> Bool = {
            !headsetMode || alvrVideo.hasStream || server.hasClients
        }
        // Desktop frames take the newest tracking timestamp at send time, so
        // they cannot be sent without one; runtime frames carry their own.
        let videoTransportBusy: @Sendable () -> Bool = {
            alvrVideo.isBusy(requiringTrackingTimestamp: !runtimeMode)
        }
        // Every encode goes through the loss-recovery gate. A frame the
        // transport would drop is not encoded at all: an unencoded frame
        // leaves no `frame_num` gap, so no IDR is needed. After a loss, the
        // next encode is a forced IDR. `completion` runs exactly once.
        // Returns whether the frame was submitted.
        let encodeVideoFrame: @Sendable (
            _ frame: CVPixelBuffer, _ pts: CMTime, _ source: String,
            _ completion: (@Sendable () -> Void)?
        ) -> Bool = { frame, pts, source, completion in
            switch videoRecovery.prepareEncode(transportBusy: videoTransportBusy()) {
            case .skipTransportBusy:
                completion?()
                noteDrop("network busy, not encoded (\(source))", .networkBusy)
                return false
            case .skipRecoveryBackoff:
                completion?()
                noteDrop("awaiting recovery IDR (\(source))", .awaitingIDR)
                return false
            case .encodeKeyframe:
                encoder.forceKeyframe()
            case .encode:
                break
            }
            guard encoder.encode(frame, pts: pts, completion: completion) else {
                noteDrop("encoder busy (\(source))", .encoderBusy)
                return false
            }
            return true
        }
        capture.onFrame = { pixelBuffer, pts in
            guard hasVideoConsumer() else { return }
            // Avoid spending GPU time composing a stereo frame that the
            // bounded encoder cannot accept. `encode` repeats this check
            // atomically in case a slot changes between here and submission.
            guard encoder.canAcceptFrame else {
                noteDrop("encoder busy (capture)", .encoderBusy)
                return
            }
            guard !videoTransportBusy() else {
                noteDrop("network busy, not encoded (capture)", .networkBusy)
                return
            }

            let frame: CVPixelBuffer
            if let stereoComposer {
                guard let composed = stereoComposer.compose(pixelBuffer) else { return }
                frame = composed
            } else {
                frame = pixelBuffer
            }
            _ = encodeVideoFrame(frame, pts, "capture", nil)
        }
        capture.onError = { error in
            fputs("capture stopped: \(error.localizedDescription)\n", stderr)
            raise(SIGTERM)
        }

        // While a client is attached but the game submits nothing (a slow
        // game, a hitch, loading, between OpenXR sessions, or not started),
        // the idle filler re-sends the last game image when the headset does
        // not have it, or sends black before the first game frame.
        var idleFillerTimer: DispatchSourceTimer?
        if let idleFiller {
            let blackFrame = try makeBlackFrame(width: encodedWidth, height: encodedHeight)
            let blackLog = ThrottledEventLog()
            let repeatLog = ThrottledEventLog()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler {
                guard alvrVideo.hasStream, !videoTransportBusy(), encoder.canAcceptFrame,
                      let filler = idleFiller.nextFrame(
                        latestTrackingTimestamp: alvrVideo.timestampForVideoFrame(),
                        hasStream: alvrVideo.hasStream,
                        referenceChainBroken: videoRecovery.isAwaitingIDR),
                      let pts = H264Encoder.presentationTime(
                        questTrackingTimestampNanoseconds: filler.presentationNanoseconds)
                else { return }
                switch filler {
                case .black:
                    guard encodeVideoFrame(blackFrame, pts, "idle filler", nil) else { return }
                    blackLog.record {
                        "OpenXR runtime idle with no game frame yet: sent \($0) black "
                            + "filler frame(s)"
                    }
                case .repeatLast(let image, _, _):
                    guard encodeVideoFrame(image.pixelBuffer, pts, "idle repeat",
                                           { _ = image }) else { return }
                    repeatLog.record {
                        "OpenXR runtime idle: re-sent the last game image \($0) time(s) "
                            + "(not delivered, or the headset needed an IDR)"
                    }
                }
            }
            timer.resume()
            idleFillerTimer = timer
        }

        var runtimeLink: RuntimeLink?
        if let controlFile = options.runtimeControlFile {
            // One extra output holds the newest composed frame for idle repeats.
            let runtimeComposer = try RuntimeStereoComposer(
                perEyeWidth: previewPerEyeWidth, height: previewPerEyeHeight,
                retainedOutputs: idleFiller == nil ? 0 : 1)
            let link = try RuntimeLink(
                controlFilePath: controlFile,
                recommendedViewSize: options.perEyeResolution,
                handTracking: options.handTracking)
            // Replaced by the negotiated headset rate once the Quest connects.
            link.setDisplayRefreshRate(Float(options.fps))
            link.onHello = { sessionId, renderer in
                print("OpenXR runtime connected (session \(sessionId), \(renderer))")
                idleFiller?.discardHeldFrame()
                encoder.forceKeyframe()
            }
            link.onTeardown = {
                print("OpenXR runtime disconnected")
                idleFiller?.discardHeldFrame()
            }
            link.onReplaced = {
                print("OpenXR runtime: a new game session replaced the previous one "
                      + "(e.g. The Lab launching Robot Repair)")
                idleFiller?.discardHeldFrame()
            }
            link.onProtocolError = { reason in
                fputs(RuntimeLink.connectionRefusedLogPrefix + reason + "\n", stderr)
            }
            link.onFrame = { frame, consumption in
                pipelineStatistics.recordRuntimeFrame(
                    trackingTimestampNanoseconds: frame.questTrackingTimestampNanoseconds)
                // Runs before the consumer check so the filler stays quiet
                // while the game renders, even with no headset attached.
                let admitted = idleFiller?.admitRuntimeFrame(
                    trackingTimestampNanoseconds: frame.questTrackingTimestampNanoseconds) ?? true
                guard admitted, hasVideoConsumer() else {
                    consumption.complete()
                    return
                }
                guard encoder.canAcceptFrame else {
                    noteDrop("encoder busy (runtime)", .encoderBusy)
                    consumption.complete()
                    return
                }
                // Skip the GPU work too when the output could not be sent.
                guard !videoTransportBusy() else {
                    noteDrop("network busy, not encoded (runtime)", .networkBusy)
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
                    idleFiller?.holdComposedFrame(
                        composed,
                        trackingTimestampNanoseconds: frame.questTrackingTimestampNanoseconds)
                    _ = encodeVideoFrame(composed.pixelBuffer, pts, "runtime") { _ = composed }
                }
                guard scheduled else {
                    noteDrop("compositor busy (runtime)", .compositorBusy)
                    consumption.complete()
                    return
                }
            }
            runtimeLink = link
        }

        var discovery: AlvrDiscoveryListener?
        var wiredConnection: AlvrWiredConnection?
        let beaconMailbox = AlvrBeaconMailbox()
        if options.discover {
            discovery = try AlvrDiscoveryListener { beacon, ip in
                beaconMailbox.post(.init(beacon: beacon, ip: ip))
            }
        } else if options.wired {
            let connection = try AlvrWiredConnection.setup()
            wiredConnection = connection
            print("USB Quest \(connection.serial) is authorized; adb control/video forwards are ready.")
        }

        // One supervisor owns the ALVR client session for the whole run. When
        // the Quest sleeps or ALVR closes, it ends that session (the OpenXR
        // runtime and the game keep running) and accepts the next one.
        var supervisor: AlvrSessionSupervisor?
        if headsetMode {
            let sessionRuntimeLink = runtimeLink
            let wired = options.wired
            let linkName = wired ? "USB" : "Wi-Fi"
            let configuredBitrate = options.megabits * 1_000_000
            let connectSession: @Sendable (AlvrClientSessionRequest) async throws
                -> AlvrClientSession = { request in
                try await connectHeadset(
                    request: request,
                    stereoComposer: stereoComposer, options: options,
                    alvrVideo: alvrVideo,
                    runtimeLink: sessionRuntimeLink,
                    headsetLatencyReporter: headsetLatencyReporter,
                    calibrationLogGate: calibrationLogGate,
                    encoder: encoder,
                    videoRecovery: videoRecovery,
                    pipelineStatistics: pipelineStatistics)
            }
            let request: @Sendable (_ host: String, _ protocolId: UInt64?) -> AlvrClientSessionRequest = {
                host, protocolId in
                AlvrClientSessionRequest(
                    host: host, wired: wired, expectedProtocolId: protocolId,
                    requestedViewWidth: UInt32(negotiateViewWidth),
                    requestedViewHeight: UInt32(negotiateViewHeight),
                    preferredRefreshRate: Float(options.fps),
                    latencyPreset: options.latencyPreset,
                    controllerPrediction: options.controllerPrediction,
                    codec: options.codec)
            }
            let sessionSupervisor = AlvrSessionSupervisor(
                initialAttemptLimit: wired ? 10 : nil,
                retryDelayNanoseconds: wired ? 500_000_000 : 1_000_000_000,
                isFatalBeforeFirstSession: { $0 is AlvrTrackingTimeoutError }
            ) { _ in
                if wired {
                    return try await connectSession(request("127.0.0.1", nil))
                }
                guard let announcement = await beaconMailbox.next() else {
                    throw BasaltError("ALVR discovery stopped")
                }
                let beacon = announcement.beacon
                let protocolHex = String(format: "%016llx", beacon.protocolId)
                print("ALVR headset '\(beacon.hostname)' announced itself from \(announcement.ip) "
                    + "(protocol id \(protocolHex)); probing TCP control handshake…")
                return try await connectSession(request(announcement.ip, beacon.protocolId))
            }
            let everStreamed = SessionFlag()
            sessionSupervisor.onSessionStarted = { _, generation in
                everStreamed.set()
                if generation > 1 {
                    print("ALVR headset reconnected (session \(generation)); "
                        + "sent a fresh IDR and the headset's view configuration resumes.")
                }
            }
            sessionSupervisor.onSessionEnded = { session, reason in
                if let session = session as? AlvrClientSession {
                    alvrVideo.uninstall(session.stream)
                }
                // The next client has its own pose history: start it on black
                // until the game's next frame instead of a stale image.
                idleFiller?.discardHeldFrame()
                // INPUT_RESET: the game sees both controllers go inactive and
                // head tracking go stale until the next session's samples.
                sessionRuntimeLink?.resetInputs()
                // Wi-Fi congestion control may have lowered the target; the
                // next session starts from the configured bitrate.
                encoder.updateAverageBitrate(configuredBitrate)
                calibrationLogGate.reset()
                guard reason != "closed by Basalt" else { return }
                print("ALVR headset disconnected (\(reason)). The OpenXR runtime keeps running; "
                    + "waiting for ALVR to reconnect over \(linkName)…")
            }
            sessionSupervisor.onConnectFailed = { error, attempt in
                if everStreamed.isSet {
                    // The Quest may stay asleep for a long time; report the
                    // first failures and then only occasionally.
                    guard attempt <= 1 || attempt.isMultiple(of: 60) else { return }
                    fputs("ALVR \(linkName) reconnect attempt \(attempt) failed: "
                        + "\(error.localizedDescription); still waiting…\n", stderr)
                } else if wired {
                    fputs("ALVR USB handshake attempt \(attempt) failed; retrying…\n", stderr)
                } else {
                    fputs("ALVR control probe failed: \(error.localizedDescription)\n", stderr)
                }
            }
            let connection = wiredConnection
            let forwardLog = ThrottledEventLog()
            sessionSupervisor.beforeReconnect = { failedAttempts in
                if failedAttempts == 0 { beaconMailbox.discardPending() }
                // adb removes forwards when the Quest's USB transport drops.
                guard let connection, failedAttempts.isMultiple(of: 10) else { return }
                do {
                    let ports = try connection.rearmForwards()
                    if !ports.isEmpty {
                        print("  re-created adb forwards for ports "
                            + ports.map(String.init).joined(separator: ", "))
                    }
                } catch {
                    forwardLog.record {
                        "adb forward check failed (\($0)x): \(error.localizedDescription)"
                    }
                }
            }
            supervisor = sessionSupervisor
        }

        try await server.start()
        if options.wired, let supervisor {
            do {
                try await supervisor.startAndWaitForFirstSession()
            } catch {
                throw BasaltError("Could not start wired ALVR session: \(error.localizedDescription)")
            }
        } else {
            supervisor?.start()
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
          \(options.codec == .hevc ? "HEVC Main" : "H.264 High") \(options.megabits) Mbps, VideoToolbox low-latency mode
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
        print("  encoder: \(options.codec.displayName)"
              + (options.codec == .h264 ? " \(options.entropyMode.rawValue.uppercased())" : "")
              + ", periodic IDR every "
              + "\(options.keyframeIntervalSeconds) s, \(options.fps) fps target, "
              + "\(options.controllerPrediction.rawValue) controller prediction, "
              + "hand tracking \(options.handTracking ? "on" : "off")"
              + (options.profile.map { ", profile \($0.rawValue)" } ?? ""))
        if !encoder.rejectedProperties.isEmpty {
            print("  VideoToolbox ignored: " + encoder.rejectedProperties.joined(separator: ", "))
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
          ffplay -probesize 32 -analyzeduration 0 -fflags nocache -flags low_delay -framedrop -f \(options.codec.ffmpegFormat) tcp://127.0.0.1:\(options.port)

        Ctrl-C to stop.
        """)

        // Timer-driven, so a complete stall (no frames, no tracking) still
        // prints a line with a growing tracking gap instead of going quiet.
        var pipelineTimer: DispatchSourceTimer?
        if headsetMode {
            _ = pipelineStatistics.snapshot()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
            timer.setEventHandler {
                print(StreamReport.pipelineLine(pipelineStatistics.snapshot()))
            }
            timer.resume()
            pipelineTimer = timer
        }

        // Capture and networking run on their own queues; park main until
        // SIGINT/SIGTERM, then tear down cleanly (stops the capture stream
        // and closes client sockets instead of dying mid-write).
        await ShutdownSignals().wait()
        pipelineTimer?.cancel()
        idleFillerTimer?.cancel()
        print("\nShutting down…")
        discovery?.stop()
        beaconMailbox.close()
        supervisor?.stop()
        runtimeLink?.stop()
        gameAudio?.stop()
        if let audioOutputRoute {
            do {
                try audioOutputRoute.restore()
                print("Restored the previous Mac audio output")
            } catch {
                fputs("Could not restore the previous Mac audio output: "
                    + "\(error.localizedDescription)\n", stderr)
            }
        }
        if !runtimeMode {
            await capture.stop()
        }
        server.stop()
        wiredConnection?.stop()
    }

    /// One ALVR handshake plus this streamer's callbacks. The returned
    /// session is already installed in `alvrVideo`; the supervisor detaches
    /// and closes it when it ends.
    private static func connectHeadset(
        request: AlvrClientSessionRequest,
        stereoComposer: StereoFrameComposer?,
        options: StreamerOptions,
        alvrVideo: AlvrVideoStreamRouter,
        runtimeLink: RuntimeLink?,
        headsetLatencyReporter: HeadsetLatencyReporter,
        calibrationLogGate: CalibrationLogGate,
        encoder: H264Encoder,
        videoRecovery: VideoLossRecoveryGate,
        pipelineStatistics: PipelineStatistics
    ) async throws -> AlvrClientSession {
        var displayName = "headset"
        let session = try await AlvrClientSession.connect(request) { handshake, videoSender in
            displayName = try configureHeadsetSession(
                handshake: handshake, videoSender: videoSender, wired: request.wired,
                stereoComposer: stereoComposer, options: options,
                runtimeLink: runtimeLink,
                headsetLatencyReporter: headsetLatencyReporter,
                calibrationLogGate: calibrationLogGate,
                encoder: encoder, videoRecovery: videoRecovery,
                pipelineStatistics: pipelineStatistics)
        }
        // Earlier encoder output was skipped while no session existed, so the
        // first frame of every session, including a reconnect, is an IDR, and
        // no P-frame reaches the new session before it.
        videoRecovery.restart()
        session.stream.onTrackingReady { videoRecovery.restart() }
        alvrVideo.install(session.stream, controlSession: session.control)
        print("ALVR control accepted by '\(displayName)': StreamConfig sent, "
            + "StartStream sent, and Quest replied StreamReady.")
        if request.wired {
            print("  ALVR TCP video stream connected through USB at \(request.host):\(request.streamPort); "
                + "tracking uplink ready; sending \(request.codec.displayName) frames.")
        } else {
            print("  ALVR UDP video stream connected to \(request.host):\(request.streamPort); "
                + "sending \(request.codec.displayName) desktop frames.")
        }
        return session
    }

    /// Logs the negotiated settings and wires the control and stream
    /// callbacks of a session that is not yet streaming. Returns the
    /// headset's display name.
    private static func configureHeadsetSession(
        handshake: AlvrSessionHandshakeResult,
        videoSender: AlvrVideoStreamSender,
        wired: Bool,
        stereoComposer: StereoFrameComposer?,
        options: StreamerOptions,
        runtimeLink: RuntimeLink?,
        headsetLatencyReporter: HeadsetLatencyReporter,
        calibrationLogGate: CalibrationLogGate,
        encoder: H264Encoder,
        videoRecovery: VideoLossRecoveryGate,
        pipelineStatistics: PipelineStatistics
    ) throws -> String {
        guard case .accepted(_, let displayName, _, let capabilities) =
                handshake.clientState else {
            throw BasaltError("ALVR headset is in standby")
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
                + "@ \(String(format: "%.0f", negotiated.refreshRate)) Hz, "
                + options.codec.displayName)
            // The runtime paces xrWaitFrame to the rate the Quest displays,
            // not to the requested --fps, so a 90 Hz headset gets 90 Hz frames.
            if let runtimeLink, runtimeLink.setDisplayRefreshRate(negotiated.refreshRate) {
                print("  OpenXR frame pacing: "
                    + String(format: "%.0f Hz", negotiated.refreshRate)
                    + (abs(negotiated.refreshRate - Float(options.fps)) >= 0.5
                        ? " (closest headset rate to --fps \(options.fps))" : ""))
            }
        } else {
            print("  headset did not provide streaming capabilities")
        }
        handshake.onRequestIDR { videoRecovery.clientRequestedIDR() }
        handshake.onViewsConfig { config in
            stereoComposer?.updateViews(config)
            runtimeLink?.publishViewsConfig(config)
            if calibrationLogGate.shouldLog(ipdMeters: config.ipdMeters) {
                let ipd = String(format: "%.1f", config.ipdMeters * 1_000)
                print("  calibrated desktop preview from headset IPD/FOV (IPD \(ipd) mm)")
            }
        }
        // One router per ALVR session: it decides per hand whether the game
        // sees the Touch controller or Quest hand tracking (an emulated Touch
        // controller driven by gestures, plus the hand skeleton).
        var routerOutputs = HandTrackingInputRouter.Outputs()
        routerOutputs.controllerMotion = { timestamp, hand, motion in
            runtimeLink?.publishControllerMotion(
                timestampNanoseconds: timestamp, hand: hand, motion: motion)
        }
        routerOutputs.controllerMask = { timestamp, activeMask in
            runtimeLink?.publishControllerMask(
                timestampNanoseconds: timestamp, activeMask: activeMask)
        }
        routerOutputs.handSkeleton = { timestamp, hand, skeleton in
            runtimeLink?.publishHandSkeleton(
                timestampNanoseconds: timestamp, hand: hand, skeleton: skeleton)
        }
        routerOutputs.buttons = { entries in runtimeLink?.publishButtons(entries) }
        routerOutputs.interactionProfile = { deviceID, profileID in
            runtimeLink?.publishInteractionProfile(deviceID: deviceID, profileID: profileID)
        }
        routerOutputs.modeChanged = { hand, handTracked in
            let name = hand == .left ? "left" : "right"
            print(handTracked
                ? "  \(name) hand: Quest hand tracking (pinch = trigger, fist = grip)"
                : "  \(name) hand: Touch controller")
        }
        let handInput = HandTrackingInputRouter(
            handTrackingEnabled: options.handTracking, outputs: routerOutputs)
        handshake.onButtons { entries in
            handInput.handleClientButtons(entries)
        }
        handshake.onActiveInteractionProfile { deviceID, profileID in
            handInput.handleClientInteractionProfile(deviceID: deviceID, profileID: profileID)
        }
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
            if report.isIDR { videoRecovery.idrDelivered() }
            transportReporter.record(report)
            if let age = report.trackingAgeNanoseconds {
                pipelineStatistics.recordPoseAge(nanoseconds: age)
            }
        }
        videoSender.onAudioSent = { report in
            audioReporter.record(report)
        }
        videoSender.onTrackingTimestamp = { timestamp in
            pipelineStatistics.recordTracking(timestampNanoseconds: timestamp)
        }
        let networkDrops = ThrottledEventLog()
        videoSender.onFrameDropped = {
            networkDrops.record { "ALVR network busy: dropped \($0) stale video frame(s)" }
            pipelineStatistics.recordDrop(.network)
            // A dropped access unit leaves no gap in ALVR's packet index, so
            // the Quest cannot notice it; every later P-frame would reference
            // the missing picture. Hold P-frames and force an IDR.
            videoRecovery.frameLost()
        }
        videoSender.onAudioDropped = {
            audioReporter.recordDrop()
        }
        videoSender.onCongestion = {
            // The lost shard was already reported through `onFrameDropped`,
            // which starts IDR recovery. Repeated pressure also lowers the
            // encoder target before another large IDR is emitted.
            if let bitrate = adaptiveBitrate?.recordTransportCongestion() {
                applyAdaptiveBitrate(bitrate)
            }
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
        videoSender.onTrackingSample = { sample in
            handInput.handleTracking(sample)
        }
        let logsHaptics = AlvrHapticsLog.isEnabled()
        if logsHaptics, runtimeLink != nil {
            fputs("BASALT_HAPTIC_LOG: logging every runtime haptic sent to ALVR\n", stderr)
        }
        runtimeLink?.onHaptic { [weak videoSender] hand, duration, frequency, amplitude in
            if logsHaptics {
                fputs(AlvrHapticsLog.line(
                    hand: hand, durationNanoseconds: duration,
                    frequency: frequency, amplitude: amplitude,
                    uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) + "\n", stderr)
            }
            videoSender?.sendHaptics(
                hand: hand, durationNanoseconds: duration,
                frequency: frequency, amplitude: amplitude)
        }
        return displayName
    }
}

/// A zeroed BGRA IOSurface frame of the encoded size, for idle filler video.
private func makeBlackFrame(width: Int, height: Int) throws -> CVPixelBuffer {
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var maybeBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        nil, width, height, kCVPixelFormatType_32BGRA,
        attributes as CFDictionary, &maybeBuffer)
    guard status == kCVReturnSuccess, let buffer = maybeBuffer else {
        throw BasaltError("Could not create the idle filler frame (\(status))")
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 0, CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// Set once, read from any thread.
private final class SessionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
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

    /// A reconnected headset logs its calibration again.
    func reset() {
        lock.lock()
        hasLogged = false
        lock.unlock()
    }
}

/// Suspends until the process receives SIGINT or SIGTERM.
private final class ShutdownSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            for signalNumber in [SIGINT, SIGTERM] {
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber, queue: .global())
                source.setEventHandler { [weak self] in self?.fire() }
                source.resume()
                sources.append(source)
            }
        }
    }

    private func fire() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
