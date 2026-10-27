import SwiftUI
import AppKit
import BasaltManagerKit

@main
struct BasaltManagerApp: App {
    @NSApplicationDelegateAdaptor(BasaltApplicationDelegate.self) private var appDelegate
    @StateObject private var model = BasaltAppModel()

    var body: some Scene {
        WindowGroup("BasaltVR") {
            RootView(model: model)
                .frame(minWidth: 940, minHeight: 640)
                // Every session starts from this window, so the delegate has
                // the model before there is anything to stop at quit.
                .onAppear { appDelegate.model = model }
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
                Button("Stop Session") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.sessionState.isActive)
            }
            CommandGroup(after: .help) {
                Button("Diagnostic Report…") { model.showingDiagnostics = true }
            }
        }
    }
}

private final class BasaltApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: BasaltAppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// The window (and any view-level observer) may already be gone when the
    /// app quits; the game, Steam, and wineserver must not outlive it.
    func applicationWillTerminate(_ notification: Notification) {
        model?.stop(waitingForWine: true)
    }
}

private struct RootView: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch model.selection {
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
    }
}

private struct SidebarView: View {
    @ObservedObject var model: BasaltAppModel

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
            SessionSidebarCard(model: model)
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
