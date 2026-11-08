import Foundation

/// The streamer's periodic stdout reports. The management app charts them by
/// parsing its captured output, so the wording and the parser live together
/// here and a round-trip test pins one to the other.
public enum StreamReport {
    /// The dashboard series one report line carries.
    public struct Values: Equatable, Sendable {
        /// Frames per second the Quest actually displayed.
        public var questFPS: Double?
        /// Video bitrate written to the ALVR stream socket.
        public var videoMegabits: Double?
        /// Average Quest input-to-display latency.
        public var latencyMilliseconds: Double?
    }

    private static let questMarker = "  Quest "
    private static let latencyMarker = "input→display latency: "
    private static let videoMarker = " video send: "

    /// Quest decoder statistics; the source of the FPS and latency series.
    public static func questLine(
        framesPerSecond: Double?,
        averageLatencyMilliseconds: Double,
        maximumLatencyMilliseconds: Double,
        decodeMilliseconds: Double,
        decoderQueueMilliseconds: Double,
        vsyncQueueMilliseconds: Double
    ) -> String {
        questMarker
            + (framesPerSecond.map { String(format: "%.1f fps; ", $0) } ?? "")
            + latencyMarker
            + String(format: "%.1f ms average, %.1f ms max",
                     averageLatencyMilliseconds, maximumLatencyMilliseconds)
            + String(format: " (decode %.1f, decoder queue %.1f, vsync %.1f ms)",
                     decodeMilliseconds, decoderQueueMilliseconds, vsyncQueueMilliseconds)
    }

    /// What Basalt handed to the video socket; the source of the wire-rate
    /// series. `transport` names the link ("USB", "Wi-Fi").
    public static func videoSendLine(
        transport: String,
        framesPerSecond: Double,
        megabitsPerSecond: Double,
        maximumWriteMilliseconds: Double,
        largestFrameKibibytes: Double,
        idrCount: Int,
        repeatedTimestamps: Int
    ) -> String {
        "  \(transport)" + videoMarker
            + String(format: "%.1f fps, %.1f Mbps on wire, ",
                     framesPerSecond, megabitsPerSecond)
            + String(format: "%.1f ms max write, %.0f KiB largest frame, %d IDR",
                     maximumWriteMilliseconds, largestFrameKibibytes, idrCount)
            + ", \(repeatedTimestamps) repeated timestamp(s)"
    }

    /// Game audio sent alongside video. It also reports Mbps, so it must
    /// never be mistaken for the video wire rate.
    public static func audioSendLine(
        transport: String,
        blocksPerSecond: Double,
        pcmMegabits: Double,
        wireMegabits: Double,
        maximumWriteMilliseconds: Double,
        drops: Int
    ) -> String {
        "  \(transport) audio send: "
            + String(format: "%.1f blocks/s, %.3f Mbps PCM, %.3f Mbps wire, ",
                     blocksPerSecond, pcmMegabits, wireMegabits)
            + String(format: "%.1f ms max write, %d drop(s)",
                     maximumWriteMilliseconds, drops)
    }

    /// Where frames were lost between tracking and the socket, with the time
    /// since the streamer started so stalls can be lined up with other logs.
    /// Printed on a timer, so it also appears while no frame flows at all.
    /// It deliberately carries neither the Quest nor the video-send marker.
    public static func pipelineLine(_ snapshot: PipelineStatistics.Snapshot) -> String {
        func rate(_ count: Int) -> String {
            snapshot.intervalSeconds > 0
                ? String(format: "%.1f/s", Double(count) / snapshot.intervalSeconds)
                : "\(count)"
        }
        func milliseconds(_ value: Double?) -> String {
            value.map { String(format: "%.1f", $0) } ?? "-"
        }
        return String(format: "  pipeline t=%.1fs: ", snapshot.elapsedSeconds)
            + "tracking \(rate(snapshot.trackingPackets)) "
            + "(max gap \(milliseconds(snapshot.trackingMaximumGapMilliseconds)) ms, "
            + "\(snapshot.trackingBackwardTimestamps) backward); "
            + "runtime \(rate(snapshot.runtimeFrames)) "
            + "(\(snapshot.runtimeUntrackedFrames) untracked, "
            + "\(snapshot.runtimeRepeatedTimestamps) repeated pose); "
            + "encoded \(rate(snapshot.encodedFrames)) "
            + "(\(milliseconds(snapshot.encodeAverageMilliseconds)) ms avg, "
            + "\(milliseconds(snapshot.encodeMaximumMilliseconds)) ms max); "
            + "drops encoder-busy \(snapshot.encoderBusyDrops), "
            + "compositor-busy \(snapshot.compositorBusyDrops), "
            + "rate-control \(snapshot.encoderDroppedFrames), "
            + "network-busy \(snapshot.networkBusyDrops), "
            + "network \(snapshot.networkDrops), "
            + "awaiting-IDR \(snapshot.awaitingIDRDrops); "
            + "pose age at send \(milliseconds(snapshot.poseAgeAverageMilliseconds)) ms avg, "
            + "\(milliseconds(snapshot.poseAgeMaximumMilliseconds)) ms max"
    }

    /// The dashboard values in a Quest or video-send line; nil for any other
    /// output. Transport and encoder lines also mention fps, but only the
    /// Quest's own count is the headset frame rate.
    public static func parse(_ line: some StringProtocol) -> Values? {
        var values = Values()
        if let quest = line.range(of: questMarker) {
            let rest = line[quest.upperBound...]
            if let latency = rest.range(of: latencyMarker) {
                values.questFPS = number(in: rest[..<latency.lowerBound], before: " fps;")
                values.latencyMilliseconds = number(
                    in: rest[latency.upperBound...], before: " ms average")
            }
        } else if let video = line.range(of: videoMarker) {
            values.videoMegabits = number(in: line[video.upperBound...], before: " Mbps on wire")
        }
        return values == Values() ? nil : values
    }

    /// The decimal number that ends right before `suffix`'s first occurrence.
    private static func number(in text: some StringProtocol, before suffix: String) -> Double? {
        guard let end = text.range(of: suffix)?.lowerBound else { return nil }
        let start = text[..<end].lastIndex { !($0.isNumber || $0 == ".") }
            .map(text.index(after:)) ?? text.startIndex
        return Double(text[start..<end]).flatMap { $0.isFinite ? $0 : nil }
    }
}
