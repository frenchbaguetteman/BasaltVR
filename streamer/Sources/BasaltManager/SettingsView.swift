import SwiftUI
import AppKit
import BasaltCore
import BasaltManagerKit

struct SettingsView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var confirmingClearHistory = false

    var body: some View {
        Form {
            Section {
                StreamSettingsFields(settings: $model.settings, audioDevices: model.audioDevices)
            } header: {
                Text("Default Stream")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Used by every game without its own stream settings. Changes apply to the next session.")
                        .formFooterStyle()
                    Button("Restore Defaults") { model.settings = StreamLaunchSettings() }
                        .disabled(model.settings == StreamLaunchSettings())
                }
            }

            Section("Storage") {
                LabeledContent("Data folder") {
                    HStack(spacing: 10) {
                        PathText(path: model.dataRoot.path)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([model.dataRoot])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        Button("Change…") { chooseDataRoot() }
                            .disabled(model.sessionState.isActive)
                    }
                }
                LabeledContent("Contents") {
                    Text("\(plural(model.bottles.count, "managed bottle")) · \(plural(model.profiles.count, "profile"))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Repository") {
                    PathText(path: model.repoRoot.path)
                }
            }

            Section("Discovery & Safety") {
                Label(
                    "\(plural(model.discoveredBottles.count, "bottle")) found across Basalt, Whisky, and CrossOver",
                    systemImage: "shippingbox")
                Label(
                    "\(plural(model.steamGames.filter { !$0.isTool }.count, "installed Steam game")) found",
                    systemImage: "gamecontroller")
                Label("External bottles are read-only until copied into Basalt", systemImage: "lock.shield")
                Label("OpenComposite remains user-supplied and is never downloaded", systemImage: "doc.badge.gearshape")
            }

            Section {
                LabeledContent("Diagnostic report") {
                    Button("Create Report…") { model.showingDiagnostics = true }
                }
                LabeledContent("Session history") {
                    HStack(spacing: 10) {
                        Text(plural(model.sessionHistory.count, "recorded session"))
                            .foregroundStyle(.secondary)
                        Button("Clear…") { confirmingClearHistory = true }
                            .disabled(model.sessionHistory.isEmpty)
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Reports are built on this Mac and redacted before you copy or save them; BasaltVR never uploads them. History keeps the last \(SessionHistoryStore.defaultLimit) sessions in the data folder.")
                    .formFooterStyle()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .clearSessionHistoryDialog(isPresented: $confirmingClearHistory, model: model)
    }

    private func chooseDataRoot() {
        guard let url = FilePanels.chooseFolder(
            title: "Choose BasaltVR Data Folder",
            startingAt: model.dataRoot,
            canCreate: true) else { return }
        Task { await model.changeDataRoot(to: url) }
    }
}

/// Stream controls as grouped-form rows, shared by Settings and the
/// per-game sheet.
struct StreamSettingsFields: View {
    @Binding var settings: StreamLaunchSettings
    let audioDevices: [GameAudioDevice]

    /// Refresh rates Quest headsets offer; a stored custom value stays listed.
    private static let frameRates = [60, 72, 80, 90, 120]
    private static let bitrateRange = 10.0...200.0

    var body: some View {
        Picker("Connection", selection: $settings.connection) {
            ForEach(StreamConnectionMode.allCases, id: \.self) {
                Text($0.shortLabel).tag($0)
            }
        }
        .pickerStyle(.segmented)

        Picker("Resolution", selection: $settings.resolution) {
            ForEach(ResolutionSelection.allCases, id: \.self) {
                Text($0.label).tag($0)
            }
        }

        Picker("Frame rate", selection: $settings.fps) {
            ForEach(Array(Set(Self.frameRates + [settings.fps])).sorted(), id: \.self) {
                Text("\($0) fps").tag($0)
            }
        }

        LabeledContent("Bitrate") {
            HStack(spacing: 10) {
                Slider(value: bitrate, in: Self.bitrateRange)
                    .frame(minWidth: 160)
                Text("\(settings.megabits) Mbps")
                    .monospacedDigit()
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }

        Picker("Latency", selection: $settings.latency) {
            ForEach([StreamLatencyPreset.balanced, .low, .ultra], id: \.self) {
                Text($0.title).tag($0)
            }
        }
        .pickerStyle(.segmented)

        Picker("Game audio", selection: $settings.audioDeviceName) {
            Text("Off").tag(String?.none)
            ForEach(audioDevices, id: \.id) { device in
                Text("\(device.name) · \(Int(device.sampleRate)) Hz")
                    .tag(String?.some(device.name))
            }
            if let name = settings.audioDeviceName,
               !audioDevices.contains(where: { $0.name == name }) {
                Text("\(name) (unavailable)").tag(String?.some(name))
            }
        }
    }

    /// Snaps to 5 Mbps without the tick marks a stepped slider would draw.
    private var bitrate: Binding<Double> {
        Binding(
            get: { Double(settings.megabits) },
            set: { settings.megabits = Int(($0 / 5).rounded()) * 5 })
    }
}
