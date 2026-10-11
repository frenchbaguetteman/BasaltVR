import SwiftUI
import Charts
import AppKit
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

extension BasaltAppModel {
    /// Profiles whose bottle has both the DXMT handoff and OpenXR runtime.
    var launchableProfiles: [LaunchProfile] {
        profiles.filter { profile in
            bottles.contains {
                $0.name == profile.bottleName && $0.isReadyForVR
            }
        }
    }

    /// The profile Play launches: the preferred one while it is launchable,
    /// otherwise the first launchable profile.
    var selectedLaunchProfileName: String? {
        let launchable = launchableProfiles
        if let preferredProfileName,
           launchable.contains(where: { $0.name == preferredProfileName }) {
            return preferredProfileName
        }
        return launchable.first?.name
    }

    /// The session's profile, or the profile Play launches.
    var displayedProfileName: String? {
        sessionState.profileName ?? selectedLaunchProfileName
    }

    var displayedStreamSettings: StreamLaunchSettings {
        displayedProfileName.map(streamSettings(for:)) ?? settings
    }
}

struct StreamDashboardView: View {
    @ObservedObject var model: BasaltAppModel

    private var activeSettings: StreamLaunchSettings { model.displayedStreamSettings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SessionHero(model: model)

                StreamHealthBanner(model: model)

                MetricTiles(console: model.console, settings: activeSettings)

                SessionLogCard(model: model, console: model.console)

                RecentSessionsCard(model: model)
            }
            .padding(24)
        }
        .navigationTitle("Stream")
        .navigationSubtitle(model.sessionState.shortTitle)
    }
}

/// Observes the console itself so only the tiles re-render per sample.
private struct MetricTiles: View {
    @ObservedObject var console: SessionConsole
    let settings: StreamLaunchSettings

    var body: some View {
        let samples = console.recentSamples
        HStack(spacing: 14) {
            MetricTile(
                title: "Quest FPS", symbol: "speedometer", unit: "fps",
                tint: .green, samples: samples, keyPath: \.fps,
                reference: "target \(settings.fps)")
            MetricTile(
                title: "Wire rate", symbol: "arrow.up.arrow.down", unit: "Mbps",
                tint: .blue, samples: samples, keyPath: \.megabits,
                reference: "limit \(settings.megabits)")
            MetricTile(
                title: "Input → display", symbol: "timer", unit: "ms",
                tint: .basaltLava, samples: samples,
                keyPath: \.latencyMilliseconds)
        }
    }
}

// MARK: - Session hero

private struct SessionHero: View {
    @ObservedObject var model: BasaltAppModel
    @State private var editingProfileSettings: ProfileSettingsSelection?

    private var state: SessionState { model.sessionState }
    private var launchable: [LaunchProfile] { model.launchableProfiles }

    private var selectedProfile: String? { model.selectedLaunchProfileName }
    private var displayedSettings: StreamLaunchSettings { model.displayedStreamSettings }

    private var hasOverride: Bool {
        model.displayedProfileName.map { model.profileSettings[$0] != nil } ?? false
    }

    private var glow: Color {
        if case .failed = state { return .red }
        return .basaltLava
    }

    private var glowIntensity: Double {
        switch state {
        case .streaming: return 0.55
        case .starting, .utility: return 0.38
        case .failed: return 0.35
        case .stopped: return 0.22
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusDot(
                            color: state == .stopped ? .basaltLava : state.tint,
                            pulsing: state.isActive)
                        Text(state.eyebrow)
                            .font(.caption.weight(.bold))
                            .tracking(1.4)
                            .foregroundStyle(state == .stopped ? .basaltLava : state.tint)
                    }
                    Text(title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Group {
                        if case .starting = state {
                            LatestLogLine(console: model.console)
                        } else {
                            Text(subtitle)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                primaryControls
            }

            FlowLayout(spacing: 6) {
                let settings = displayedSettings
                HeroChip(text: settings.connection.shortLabel, systemImage: settings.connection.symbol)
                HeroChip(text: "\(settings.fps) fps", systemImage: "speedometer")
                HeroChip(text: "\(settings.megabits) Mbps", systemImage: "arrow.up.arrow.down")
                HeroChip(text: settings.resolution.dimensions, systemImage: "rectangle.split.2x1")
                HeroChip(text: "\(settings.latency.title) latency", systemImage: "bolt")
                HeroChip(
                    text: settings.audioDeviceName ?? "No game audio",
                    systemImage: settings.audioDeviceName == nil
                        ? "speaker.slash" : "speaker.wave.2")
                if hasOverride {
                    HeroChip(text: "Custom for this game", systemImage: "slider.horizontal.3", tint: .basaltLava)
                }
                settingsMenu
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { HeroBackground(glow: glow, intensity: glowIntensity) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.35), value: state)
        .sheet(item: $editingProfileSettings) { selection in
            PerGameSettingsSheet(profileName: selection.name, model: model)
        }
    }

    private var title: String {
        switch state {
        case .stopped:
            return launchable.isEmpty ? "No games ready yet" : "Ready to stream"
        case .starting(let profile), .streaming(let profile):
            return profile
        case .utility(let name):
            return name
        case .failed:
            return "Session failed"
        }
    }

    private var subtitle: String {
        switch state {
        case .stopped:
            return launchable.isEmpty
                ? "Prepare a Basalt bottle, then create a launch profile for a game in the Library."
                : "Put on your headset and open ALVR, then press Play."
        case .starting:
            return "Preparing the session…"
        case .streaming:
            return displayedSettings.connection == .wired
                ? "Streaming to the headset over a USB cable."
                : "Streaming to the headset over Wi-Fi."
        case .utility:
            return "A Windows app is running in its bottle. VR sessions are unavailable until it exits."
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder private var primaryControls: some View {
        if state.isActive {
            HStack(spacing: 10) {
                if case .starting = state { ProgressView().controlSize(.small) }
                Button(role: .destructive) { model.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .help("Stop the session (⌘.)")
            }
        } else if launchable.isEmpty {
            Button { model.selection = .library } label: {
                Label("Open Library", systemImage: "gamecontroller")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            HStack(spacing: 10) {
                Picker("Game", selection: Binding(
                    get: { selectedProfile ?? "" },
                    set: { model.preferredProfileName = $0 })) {
                    ForEach(launchable, id: \.name) { profile in
                        Text(profile.name).tag(profile.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)
                .controlSize(.large)
                Button {
                    guard let selectedProfile else { return }
                    Task { await model.launch(profileName: selectedProfile) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            if let selectedProfile {
                Button("Stream Settings for \(selectedProfile)…") {
                    editingProfileSettings = ProfileSettingsSelection(name: selectedProfile)
                }
            }
            Button("Default Stream Settings…") { model.selection = .settings }
        } label: {
            Label("Adjust", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .disabled(state.isActive)
    }
}

private struct ProfileSettingsSelection: Identifiable {
    var id: String { name }
    let name: String
}

private struct HeroChip: View {
    let text: String
    let systemImage: String
    var tint: Color = .primary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())
    }
}

/// Dark basalt with a lava seam that glows brighter while streaming.
private struct HeroBackground: View {
    let glow: Color
    let intensity: Double

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.16), Color(white: 0.075)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [glow.opacity(intensity), .clear],
                center: UnitPoint(x: 0.88, y: 1.15),
                startRadius: 8, endRadius: 440)
            Canvas { context, size in
                context.addFilter(.blur(radius: 3))
                context.stroke(Self.seam(in: size),
                               with: .color(glow.opacity(intensity * 0.9)), lineWidth: 3)
            }
            Canvas { context, size in
                context.stroke(Self.seam(in: size),
                               with: .color(glow.opacity(min(1, intensity * 1.4))), lineWidth: 1)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: intensity)
    }

    /// The icon's molten crack, drawn once blurred as a glow and once sharp.
    private static func seam(in size: CGSize) -> Path {
        Path { seam in
            seam.move(to: CGPoint(x: size.width * 0.74, y: 0))
            seam.addLine(to: CGPoint(x: size.width * 0.77, y: size.height * 0.28))
            seam.addLine(to: CGPoint(x: size.width * 0.745, y: size.height * 0.52))
            seam.addLine(to: CGPoint(x: size.width * 0.79, y: size.height * 0.78))
            seam.addLine(to: CGPoint(x: size.width * 0.775, y: size.height))
        }
    }
}

// MARK: - Metrics

private struct MetricPoint: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
}

private struct MetricTile: View {
    let title: String
    let symbol: String
    let unit: String
    let tint: Color
    let samples: [StreamMetricSample]
    let keyPath: KeyPath<StreamMetricSample, Double?>
    var reference: String?

    var body: some View {
        let points = samples.compactMap { sample in
            sample[keyPath: keyPath].map {
                MetricPoint(id: sample.id, date: sample.date, value: $0)
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let reference {
                    Text(reference)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(points.last.map { String(format: "%.1f", $0.value) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: points.last?.value)
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
            Sparkline(points: points, tint: tint)
                .frame(height: 48)
            Text(summary(of: points))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func summary(of points: [MetricPoint]) -> String {
        let statistics = MetricStatistics(points.lazy.map(\.value))
        guard let average = statistics.average,
              let low = statistics.minimum, let high = statistics.maximum else {
            return "No samples yet"
        }
        return String(format: "avg %.1f · min %.1f · max %.1f", average, low, high)
    }
}

private struct Sparkline: View {
    let points: [MetricPoint]
    let tint: Color

    var body: some View {
        if points.count < 2 {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 24))
                    path.addLine(to: CGPoint(x: 2000, y: 24))
                }
                .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Text("Waiting for the headset")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .background(.background.secondary)
            }
            .clipped()
        } else {
            let values = points.map(\.value)
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let padding = max((high - low) * 0.2, 0.5)
            Chart(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Floor", low - padding),
                    yEnd: .value("Value", point.value))
                    .foregroundStyle(LinearGradient(
                        colors: [tint.opacity(0.32), tint.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Value", point.value))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: (low - padding)...(high + padding))
        }
    }
}

/// While connecting, the hero follows the newest output line; observing the
/// console here keeps that from re-rendering the whole hero.
private struct LatestLogLine: View {
    @ObservedObject var console: SessionConsole

    var body: some View {
        Text(console.latestLine ?? "Preparing the session…")
    }
}

// MARK: - Log

private struct SessionLogCard: View {
    @ObservedObject var model: BasaltAppModel
    @ObservedObject var console: SessionConsole

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Session Log", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(console.log, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the session log")
                .disabled(console.log.isEmpty)
                Menu {
                    Button("Save Log…") { saveLog() }
                        .disabled(console.log.isEmpty)
                    Button("Export Metrics as CSV…") { saveMetrics() }
                        .disabled(console.samples.isEmpty)
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Save the log or every metric sample of this session")
                .disabled(console.log.isEmpty && console.samples.isEmpty)
                Button {
                    model.clearLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear the log and charts")
                .disabled(console.log.isEmpty || model.sessionState.isActive)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            SessionLogView(
                text: console.log.isEmpty
                    ? "Session output will appear here." : console.log)
                .frame(height: 240)
        }
        .cardStyle(padding: 0)
    }

    private func saveLog() {
        guard let url = FilePanels.saveFile(
            title: "Save Session Log", baseName: "BasaltVR-session", fileExtension: "log")
        else { return }
        model.export(console.log, to: url)
    }

    private func saveMetrics() {
        guard let url = FilePanels.saveFile(
            title: "Export Stream Metrics", baseName: "BasaltVR-metrics", fileExtension: "csv")
        else { return }
        model.export(StreamMetricCSV.render(console.samples), to: url)
    }
}

/// A fixed-size AppKit text container avoids SwiftUI repeatedly measuring the
/// full selectable log inside two nested scroll views as telemetry arrives.
/// The diagnostic report sheet reuses it for its preview.
struct SessionLogView: NSViewRepresentable {
    let text: String
    /// Keep the newest output in view while the reader is at the end.
    var followsTail = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    final class Coordinator {
        /// The text last handed to the view, so updates can append.
        var shown = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let shown = context.coordinator.shown
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage, text != shown else { return }
        let wasAtBottom = shown.isEmpty
            || scrollView.contentView.bounds.maxY >= textView.bounds.maxY - 24
        if !shown.isEmpty, text.utf8.starts(with: shown.utf8) {
            // Output only grows between trims; appending avoids replacing
            // and relaying out the whole log for every chunk.
            let added = Substring(text.utf8.dropFirst(shown.utf8.count))
            storage.append(NSAttributedString(string: String(added), attributes: [
                .font: textView.font as Any,
                .foregroundColor: textView.textColor ?? .labelColor,
            ]))
        } else {
            textView.string = text
        }
        context.coordinator.shown = text
        if followsTail, wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}

// MARK: - Health

/// Explains a degraded live stream. A timer re-evaluates it so a headset
/// that goes silent is noticed even though no new samples arrive.
private struct StreamHealthBanner: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        if case .streaming = model.sessionState {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                // Sampled on the timer instead of observed, so the banner
                // does not re-render for every log chunk.
                let issues = StreamHealthAdvisor.evaluate(
                    samples: model.console.recentSamples,
                    settings: model.displayedStreamSettings,
                    thermalState: ProcessInfo.processInfo.thermalState,
                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    now: context.date)
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(issues) { issue in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: issue.kind.symbol)
                                    .foregroundStyle(.orange)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.title)
                                        .font(.callout.weight(.semibold))
                                    Text(issue.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        Color.orange.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.3)))
                }
            }
        }
    }
}

private extension StreamHealthIssue.Kind {
    var symbol: String {
        switch self {
        case .headsetSilent: return "wifi.exclamationmark"
        case .lowFrameRate: return "speedometer"
        case .highLatency: return "timer"
        case .thermalPressure: return "thermometer.high"
        case .lowPowerMode: return "battery.25"
        }
    }
}

// MARK: - History

private struct RecentSessionsCard: View {
    @ObservedObject var model: BasaltAppModel
    @State private var confirmingClear = false

    private static let visibleCount = 6

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Recent Sessions", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Button { confirmingClear = true } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget the recorded sessions")
                .disabled(model.sessionHistory.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if model.sessionHistory.isEmpty {
                Text("Sessions you play appear here with their duration, frame rate, and latency.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                let visible = Array(model.sessionHistory.prefix(Self.visibleCount))
                ForEach(visible) { record in
                    SessionHistoryRow(record: record, model: model)
                    if record.id != visible.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
        .cardStyle(padding: 0)
        .clearSessionHistoryDialog(isPresented: $confirmingClear, model: model)
    }
}

private struct SessionHistoryRow: View {
    let record: SessionRecord
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.profileName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let share = record.metrics.lowFrameRateShare, share >= 0.1 {
                        Chip(text: "\(Int((share * 100).rounded()))% below target fps", tint: .orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(record.failureReason ?? subtitle)
            }
            Spacer(minLength: 12)
            if let stats {
                Text(stats)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await model.launch(profileName: record.profileName) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help(canReplay ? "Play \(record.profileName) again" : "This game is not ready to launch")
            .disabled(!canReplay)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var canReplay: Bool {
        !model.sessionState.isActive
            && model.launchableProfiles.contains { $0.name == record.profileName }
    }

    private var symbol: String {
        switch record.outcome {
        case .ended: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .stopped, nil: return "stop.circle.fill"
        }
    }

    private var tint: Color {
        switch record.outcome {
        case .ended: return .green
        case .failed: return .red
        case .stopped, nil: return .secondary
        }
    }

    private var subtitle: String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let duration = record.streamingDuration {
            parts.append(Duration.seconds(duration).formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated,
                       maximumUnitCount: 2)))
        }
        if record.outcome == .failed {
            parts.append("Failed: \(record.failureReason ?? "unknown error")")
        } else {
            parts.append("\(record.settings.connection.shortLabel) · \(record.settings.fps) fps")
        }
        return parts.joined(separator: " · ")
    }

    private var stats: String? {
        var parts = [String]()
        if let fps = record.metrics.fps.average {
            parts.append(String(format: "%.1f fps", fps))
        }
        if let latency = record.metrics.latencyMilliseconds.average {
            parts.append(String(format: "%.0f ms", latency))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
