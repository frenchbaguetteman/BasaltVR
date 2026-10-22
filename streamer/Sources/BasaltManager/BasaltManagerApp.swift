import SwiftUI
import AppKit
import BasaltManagerKit

@main
struct BasaltManagerApp: App {
    @NSApplicationDelegateAdaptor(BasaltApplicationDelegate.self) private var appDelegate
    @StateObject private var model = BasaltAppModel()

    init() {
        // Opened from Finder: no shell, so find the checkout (or packaged support
        // folder) and a usable PATH before the model looks for them.
        let overrides = AppBundleEnvironment.overrides(
            bundleURL: Bundle.main.bundleURL,
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            environment: ProcessInfo.processInfo.environment)
        for (key, value) in overrides { setenv(key, value, 1) }
        if let root = overrides["BASALT_REPO_ROOT"] {
            FileManager.default.changeCurrentDirectoryPath(root)
        }
    }

    var body: some Scene {
        WindowGroup("BasaltVR") {
            RootView(model: model)
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.selection = .settings }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(ManagerSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.rawValue) { model.selection = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                }
                Divider()
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
            }
            CommandMenu("Session") {
                Button("Stop Session") {
                    if model.play.isActive { model.play.stop() } else { model.stop() }
                }
                .keyboardShortcut(".")
            }
            CommandGroup(after: .help) {
                Button("Diagnostic Report…") { model.showingDiagnostics = true }
            }
        }
    }
}

/// The running Play session, for the quit path. Set by RootView.
@MainActor
enum PlaySessionTermination {
    static weak var controller: PlayController?
    static weak var model: BasaltAppModel?
}

private final class BasaltApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Quitting during a game first closes the game, Steam, Wine, and the stream
    /// (play.zsh's own cleanup, or the Stream page's Stop), then quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let play = PlaySessionTermination.controller.flatMap { $0.isActive ? $0 : nil }
            let model = PlaySessionTermination.model.flatMap { $0.hasWineWork ? $0 : nil }
            guard play != nil || model != nil else { return .terminateNow }
            var replied = false
            let reply = {
                guard !replied else { return }
                replied = true
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            var pending = (play == nil ? 0 : 1) + (model == nil ? 0 : 1)
            let finished = {
                pending -= 1
                if pending == 0 { reply() }
            }
            play?.stop { finished() }
            model?.stopForTermination { finished() }
            // play.zsh force-kills after 120 s; never hang the quit longer than that.
            DispatchQueue.main.asyncAfter(deadline: .now() + 130) { reply() }
            return .terminateLater
        }
    }
}

private struct RootView: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, play: model.play)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch model.selection {
                case .play: PlayView(model: model, play: model.play)
                case .library: LibraryView(model: model)
                case .stream: StreamDashboardView(model: model)
                case .bottles: BottlesView(model: model)
                case .setup: SetupView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .toolbar {
                ToolbarItem {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .help("Scanning bottles and games…")
                    } else {
                        Button { Task { await model.refresh() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Rescan bottles, games, and setup (⌘R)")
                    }
                }
            }
        }
        .tint(.basaltLava)
        .sheet(isPresented: $model.showingDiagnostics) {
            DiagnosticReportSheet(model: model)
        }
        .alert("BasaltVR", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in
            model.stop()
        }
        .onAppear {
            PlaySessionTermination.controller = model.play
            PlaySessionTermination.model = model
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var model: BasaltAppModel
    @ObservedObject var play: PlayController

    /// Sidebar selection is optional in List's API; clicking empty space
    /// clears it, which must not leave the detail column blank.
    private var selection: Binding<ManagerSection?> {
        Binding(
            get: { model.selection },
            set: { if let section = $0 { model.selection = section } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Play") {
                row(.play, badge: play.progress.phase == .playing ? Text("LIVE") : nil)
                row(.library, badge: Text("\(model.libraryItemCount)"))
                row(.stream, badge: model.sessionState.isStreaming ? Text("LIVE") : nil)
            }
            Section("Manage") {
                row(.bottles, badge: Text("\(model.discoveredBottles.count)"))
                row(.setup, badge: model.missingRequiredSetupCount > 0 ? Text("\(model.missingRequiredSetupCount)") : nil)
                row(.settings, badge: nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if play.isActive {
                    PlaySidebarCard(model: model, play: play)
                } else {
                    SessionSidebarCard(model: model)
                }
            }
            .padding(10)
        }
    }

    /// The tag must be the row's outermost modifier or List cannot match it
    /// to the selection, leaving rows unclickable.
    private func row(_ section: ManagerSection, badge: Text?) -> some View {
        Label(section.rawValue, systemImage: section.symbol)
            .badge(badge)
            .tag(section)
    }
}

private struct SessionSidebarCard: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        let state = model.sessionState
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(color: state.tint, pulsing: state.isActive)
                Text(state.shortTitle)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if model.selection != .stream {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(state.shortDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if state.isActive {
                Button(role: .destructive) { model.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .stream }
        .help("Open the Stream dashboard")
        .animation(.easeInOut(duration: 0.2), value: state)
    }
}

private struct PlaySidebarCard: View {
    @ObservedObject var model: BasaltAppModel
    @ObservedObject var play: PlayController

    var body: some View {
        let progress = play.progress
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(color: progress.phase == .playing ? .green : .yellow, pulsing: true)
                Text(progress.gameTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(progress.headline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button(role: .destructive) { play.stop() } label: {
                Label(progress.phase == .stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(progress.phase == .stopping)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .play }
        .help("Open the Play page")
    }
}
