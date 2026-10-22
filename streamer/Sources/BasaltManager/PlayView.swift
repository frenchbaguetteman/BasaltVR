import SwiftUI
import AppKit
import BasaltManagerKit

/// The simple screen: pick a game, press Play. Everything else is automatic.
struct PlayView: View {
    @ObservedObject var model: BasaltAppModel
    @ObservedObject var play: PlayController
    @State private var confirmReplace: PlayReadinessItem.Fix?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)]

    var body: some View {
        let games = model.playGames
        let selected = games.first { $0.id == play.selectedGameID }
            ?? games.first { $0.appID == "450390" } ?? games.first   // The Lab by default
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatusCard(play: play, game: selected, otherSessionActive: model.sessionState.isActive)
                if games.isEmpty {
                    ContentUnavailableView {
                        Label("No games yet", systemImage: "gamecontroller")
                    } description: {
                        Text("Games appear here once they have a launch profile. Open All Games to create one.")
                    } actions: {
                        Button("Open All Games") { model.selection = .library }
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Games").font(.title3.weight(.semibold))
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(games) { game in
                                PlayGameTile(game: game, selected: game.id == selected?.id)
                                    .onTapGesture(count: 2) {
                                        guard !play.isActive, !model.sessionState.isActive else { return }
                                        play.play(game)
                                    }
                                    .onTapGesture {
                                        guard !play.isActive else { return }
                                        play.selectedGameID = game.id
                                    }
                            }
                        }
                    }
                }
                ReadinessCard(model: model, play: play, confirmReplace: $confirmReplace)
                DetailsCard(play: play)
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Play")
        .task {
            // A light look at adb every few seconds while this screen is open.
            while !Task.isCancelled {
                await play.refreshQuest()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .confirmationDialog(
            "Replace ALVR on the Quest?",
            isPresented: Binding(get: { confirmReplace != nil },
                                 set: { if !$0 { confirmReplace = nil } })
        ) {
            Button("Replace with ALVR \(QuestStatus.expectedALVRVersion)", role: .destructive) {
                if let fix = confirmReplace { Task { await play.perform(fix) } }
                confirmReplace = nil
            }
        } message: {
            Text("The ALVR app on the Quest is removed and the checked ALVR \(QuestStatus.expectedALVRVersion) is installed. ALVR settings on the Quest are reset.")
        }
    }
}

private struct StatusCard: View {
    @ObservedObject var play: PlayController
    let game: PlayGame?
    let otherSessionActive: Bool

    var body: some View {
        let progress = play.progress
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                StatusDot(color: tint(progress.phase), pulsing: progress.isActive)
                    .padding(.top, 9)
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.headline)
                        .font(.title.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !progress.detail.isEmpty {
                        Text(progress.detail)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if progress.isActive, let summary = sessionSummary(progress) {
                        Text(summary).font(.callout).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 12)
                if progress.isActive || !play.stats.isEmpty {
                    LiveStats(stats: play.stats, live: progress.isActive)
                }
            }
            HStack(spacing: 16) {
                playButton(progress)
                if !progress.isActive {
                    Picker("Connection", selection: $play.options.transport) {
                        ForEach(PlayTransport.allCases) { Text($0.label).tag($0) }
                    }
                    .frame(maxWidth: 330)
                    Picker("Quality", selection: $play.options.quality) {
                        ForEach(PlayQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
            if !progress.isActive {
                Text(play.options.quality.explanation + " " + transportHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle(padding: 22, cornerRadius: 16)
    }

    @ViewBuilder
    private func playButton(_ progress: PlayProgress) -> some View {
        if progress.phase == .stopping {
            Button {} label: {
                Label("Stopping…", systemImage: "hourglass").frame(minWidth: 180)
            }
            .controlSize(.extraLarge)
            .disabled(true)
        } else if progress.isActive {
            Button(role: .destructive) { play.stop() } label: {
                Label("Stop", systemImage: "stop.fill").frame(minWidth: 180)
            }
            .controlSize(.extraLarge)
        } else {
            Button {
                if let game { play.play(game) }
            } label: {
                Label(game.map { "Play \($0.title)" } ?? "Play", systemImage: "play.fill")
                    .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(game == nil || otherSessionActive || play.fixInProgress != nil)
            .help(otherSessionActive ? "Stop the session on the Stream page first." : "Start the game on your Quest")
        }
    }

    private var transportHint: String {
        switch play.options.transport {
        case .auto: return "Automatic uses the USB cable when it is plugged in, else Wi-Fi."
        case .usb: return "The Quest must be plugged in."
        case .wifi: return "The Quest and this Mac must use the same Wi-Fi."
        }
    }

    private func sessionSummary(_ progress: PlayProgress) -> String? {
        var parts = [String]()
        if let link = progress.link { parts.append(link.label) }
        if let quality = progress.qualitySummary { parts.append(quality) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func tint(_ phase: PlayProgress.Phase) -> Color {
        switch phase {
        case .idle, .finished: return .secondary
        case .preparing, .connecting, .starting, .stopping: return .yellow
        case .playing: return .green
        case .reconnecting: return .orange
        case .failed: return .red
        }
    }
}

private struct LiveStats: View {
    let stats: PlayLiveStats
    let live: Bool

    var body: some View {
        HStack(spacing: 10) {
            stat(stats.framesPerSecond.map { String(format: "%.0f", $0) } ?? "–", "fps")
            stat(stats.latencyMilliseconds.map { String(format: "%.0f", $0) } ?? "–", "ms delay")
            stat(stats.megabits.map { String(format: "%.0f", $0) } ?? "–", "Mbps")
        }
        .opacity(live ? 1 : 0.5)
        .help("Frames per second on the Quest, motion-to-photon delay, and stream rate")
    }

    private func stat(_ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 64)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PlayGameTile: View {
    let game: PlayGame
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { artwork }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.basaltLava : Color.primary.opacity(0.08),
                                      lineWidth: selected ? 3 : 1))
                .overlay(alignment: .topLeading) {
                    if game.isVerified {
                        ArtworkChip(text: "VERIFIED", systemImage: "checkmark.seal.fill")
                            .padding(8)
                    }
                }
            Text(game.title)
                .font(.headline)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
        .help("Click to choose. Double-click to play.")
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = game.artwork {
            LocalArtwork(url: url)
        } else {
            ZStack {
                LinearGradient(colors: [.basaltSlate, .black], startPoint: .top, endPoint: .bottom)
                Image(systemName: "visionpro")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.basaltLava)
            }
        }
    }
}

/// Loads Steam's local library art off the main thread.
private struct LocalArtwork: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.basaltSlate
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .task(id: url) {
            let url = url
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

private struct ReadinessCard: View {
    @ObservedObject var model: BasaltAppModel
    @ObservedObject var play: PlayController
    @Binding var confirmReplace: PlayReadinessItem.Fix?

    var body: some View {
        let items = play.readiness(audioDevices: model.audioDevices)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Before you play").font(.title3.weight(.semibold))
                Spacer()
                if let running = play.fixInProgress {
                    ProgressView().controlSize(.small)
                    Text(running).font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Check Again") {
                        Task {
                            await model.refresh()
                            await play.refreshQuest()
                        }
                    }
                    .disabled(play.isActive)
                }
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol(item.level))
                        .foregroundStyle(color(item.level))
                        .font(.title3)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.body.weight(.semibold))
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let fix = item.fix {
                        HStack(spacing: 6) {
                            if fix == .installBlackHole {
                                Button("Copy Command") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        PlayReadiness.blackHoleCommand, forType: .string)
                                }
                            }
                            Button(fix.title) {
                                if case .replaceALVR = fix {
                                    confirmReplace = fix
                                } else {
                                    Task { await play.perform(fix) }
                                }
                            }
                            .disabled(play.isActive || play.fixInProgress != nil)
                        }
                    }
                }
            }
            if let message = play.fixMessage {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { play.fixMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .cardStyle()
    }

    private func symbol(_ level: PlayReadinessItem.Level) -> String {
        switch level {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocking: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func color(_ level: PlayReadinessItem.Level) -> Color {
        switch level {
        case .ready: return .green
        case .warning: return .orange
        case .blocking: return .red
        case .unknown: return .secondary
        }
    }
}

private struct DetailsCard: View {
    @ObservedObject var play: PlayController
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(play.logLines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                HStack {
                    Button("Open Logs Folder") {
                        let logs = PlayTools.logsDirectory()
                        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(logs)
                    }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            play.logLines.joined(separator: "\n"), forType: .string)
                    }
                    .disabled(play.logLines.isEmpty)
                    Spacer()
                    Toggle("Save the Quest log", isOn: $play.options.saveQuestLog)
                        .disabled(play.isActive)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Details").font(.title3.weight(.semibold))
        }
        .cardStyle()
    }
}
