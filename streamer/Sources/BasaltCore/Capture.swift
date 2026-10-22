import Foundation
import ScreenCaptureKit
import CoreMedia

/// A desktop-capture (ScreenCaptureKit) failure. Only this kind of fatal error gets the
/// Screen Recording hint; an adb or ALVR error does not.
public struct ScreenCaptureError: LocalizedError {
    public let underlying: Error

    public init(_ underlying: Error) { self.underlying = underlying }

    public var errorDescription: String? { underlying.localizedDescription }

    /// The Screen Recording hint to print after `error`, or nil if it is not a capture error.
    public static func permissionHint(for error: Error) -> String? {
        guard error is ScreenCaptureError
                || (error as NSError).domain == SCStreamErrorDomain else { return nil }
        return "(Screen capture failed: grant Screen Recording permission to your terminal in System Settings → Privacy & Security.)"
    }

    static func wrapping<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ScreenCaptureError {
            throw error
        } catch {
            throw ScreenCaptureError(error)
        }
    }
}

/// Captures the main display with ScreenCaptureKit and hands raw frames
/// (NV12 CVPixelBuffers) to `onFrame`.
///
/// In the full pipeline this component is replaced by the OpenXR runtime's
/// swapchain capture (games submit frames directly); screen capture is the
/// M1 stand-in that exercises the same downstream encode/transport path.
public final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    public var onError: ((Error) -> Void)?
    public private(set) var width = 0
    public private(set) var height = 0

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "basalt.capture")
    private let pacingQueue = DispatchQueue(
        label: "basalt.capture.pacer", qos: .userInteractive)
    private let pacingQueueKey = DispatchSpecificKey<Void>()
    private let pacingLock = NSLock()
    private var pacingTimer: DispatchSourceTimer?
    private var latestFrame: CVPixelBuffer?
    private var frameIntervalNanoseconds: UInt64 = 1_000_000_000 / 60
    private var nextTickNanoseconds: UInt64 = 0
    private var pacingGeneration: UInt64 = 0
    private var isPacing = false

    public override init() {
        super.init()
        pacingQueue.setSpecific(key: pacingQueueKey, value: ())
    }

    /// Discovers the main display and configures the stream. Must be called
    /// before `start()`; `width`/`height` are valid afterwards.
    public func prepare(fps: Int) async throws {
        try await ScreenCaptureError.wrapping { try await prepareStream(fps: fps) }
    }

    private func prepareStream(fps: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw BasaltError("No displays found")
        }

        // H.264 wants even dimensions. Capturing at 1x (points) keeps the
        // demo bitrate modest; the real pipeline encodes at headset res.
        width = display.width & ~1
        height = display.height & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // The pacer retains the newest capture surface while ScreenCaptureKit
        // fills the next one, so three surfaces are the minimum useful ring.
        // Pacing itself remains latest-frame-only and does not queue frames.
        config.queueDepth = 3
        config.showsCursor = true

        pacingLock.withLock {
            frameIntervalNanoseconds = max(1, 1_000_000_000 / UInt64(fps))
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        self.stream = stream
    }

    public func start() async throws {
        guard let stream else { throw BasaltError("prepare() was not called") }
        // Clear any prior run before ScreenCaptureKit can begin delivering the
        // next run's surfaces.
        stopPacing()
        try await ScreenCaptureError.wrapping { try await stream.startCapture() }
        startPacing()
    }

    public func stop() async {
        stopPacing()
        try? await stream?.stopCapture()
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit may only deliver complete frames when display
        // content changes. Cache rendered surfaces here and let the fixed-rate
        // pacer repeat the newest one with a fresh host-clock timestamp. Idle
        // means the previous surface is still current. Blank, suspended, and
        // stopped states must clear it so stale screen contents are not replayed.
        guard let attachments = (CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let statusRaw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else { return }

        switch status {
        case .complete, .started:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            pacingLock.lock()
            latestFrame = pixelBuffer
            pacingLock.unlock()
        case .blank, .suspended, .stopped:
            pacingLock.lock()
            latestFrame = nil
            pacingLock.unlock()
        case .idle:
            break
        @unknown default:
            break
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopPacing()
        onError?(error)
    }

    // MARK: Constant-cadence latest-frame pacing

    private func startPacing() {
        let timer = DispatchSource.makeTimerSource(queue: pacingQueue)

        pacingLock.lock()
        pacingGeneration &+= 1
        let generation = pacingGeneration
        isPacing = true
        nextTickNanoseconds = DispatchTime.now().uptimeNanoseconds
            &+ frameIntervalNanoseconds
        let firstTick = nextTickNanoseconds
        pacingTimer = timer
        pacingLock.unlock()

        timer.setEventHandler { [weak self] in
            self?.paceFrame(generation: generation)
        }
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: firstTick),
            leeway: .microseconds(100))
        timer.activate()
    }

    private func paceFrame(generation: UInt64) {
        pacingLock.lock()
        guard isPacing, generation == pacingGeneration else {
            pacingLock.unlock()
            return
        }
        let frame = latestFrame
        pacingLock.unlock()

        // Repeating an unchanged retained surface is intentional. It keeps
        // the video/ALVR clocks advancing without mistaking an idle capture
        // sample for newly rendered content.
        if let frame {
            onFrame?(frame, CMClockGetTime(CMClockGetHostTimeClock()))
        }

        pacingLock.lock()
        guard isPacing, generation == pacingGeneration, let timer = pacingTimer else {
            pacingLock.unlock()
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        var next = nextTickNanoseconds &+ frameIntervalNanoseconds
        if next <= now {
            // Skip elapsed cadence slots instead of dispatching a burst of
            // catch-up frames after a slow compose/encode callback.
            let missedIntervals = ((now - next) / frameIntervalNanoseconds) &+ 1
            next = next &+ missedIntervals &* frameIntervalNanoseconds
        }
        nextTickNanoseconds = next
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: next),
            leeway: .microseconds(100))
        pacingLock.unlock()
    }

    private func stopPacing() {
        pacingLock.lock()
        isPacing = false
        pacingGeneration &+= 1
        latestFrame = nil
        let timer = pacingTimer
        pacingTimer = nil
        pacingLock.unlock()

        timer?.cancel()

        // Once stop returns, no already-running pacing callback should retain
        // or submit the old capture surface. Avoid self-deadlock if a caller
        // ever stops capture from inside `onFrame`.
        if DispatchQueue.getSpecific(key: pacingQueueKey) == nil {
            pacingQueue.sync {}
        }
    }
}
