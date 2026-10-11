import SwiftUI
import AppKit
import BasaltBottleKit
import BasaltManagerKit

struct BottlesView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var showingNewBottle = false
    @State private var importing: DiscoveredBottle?

    var body: some View {
        let managed = model.discoveredBottles.filter(\.isManaged)
        let external = model.discoveredBottles.filter { !$0.isManaged }

        Form {
            Section {
                if managed.isEmpty {
                    HStack(spacing: 12) {
                        Text("No Basalt bottles yet. Create one, or copy a Whisky or CrossOver bottle below.")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("New Bottle…") { showingNewBottle = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(managed) { bottle in
                    BottleRow(bottle: bottle, model: model) { importing = bottle }
                }
            } header: {
                Text("Basalt Bottles")
            } footer: {
                Text("Prepare installs the Basalt DXMT handoff and OpenXR runtime, then verifies the loader.")
                    .formFooterStyle()
            }

            if !external.isEmpty {
                Section {
                    ForEach(external) { bottle in
                        BottleRow(bottle: bottle, model: model) { importing = bottle }
                    }
                } header: {
                    Text("Whisky & CrossOver")
                } footer: {
                    Text("External bottles stay read-only. Copying makes an isolated APFS clone for Basalt; the original is never patched.")
                        .formFooterStyle()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Bottles")
        .navigationSubtitle(plural(model.discoveredBottles.count, "bottle"))
        .toolbar {
            ToolbarItem {
                Button { showingNewBottle = true } label: {
                    Label("New Bottle", systemImage: "plus")
                }
                .help("Create a Basalt bottle (⇧⌘N)")
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $showingNewBottle) { NewBottleSheet(model: model) }
        .sheet(item: $importing) { ImportBottleSheet(bottle: $0, model: model) }
    }
}

private struct BottleRow: View {
    let bottle: DiscoveredBottle
    @ObservedObject var model: BasaltAppModel
    let onImport: () -> Void

    private var hasSteam: Bool {
        model.steamGames.contains { $0.bottleID == bottle.id }
    }

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(symbol: originSymbol, tint: originTint, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(bottle.name).fontWeight(.semibold)
                if let managed = bottle.managed {
                    Text(managed.engineID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    PathText(path: bottle.prefix.path)
                }
            }
            Spacer(minLength: 12)

            if let managed = bottle.managed {
                componentChip("DXMT", ready: managed.dxmtInstalled)
                componentChip("OpenXR", ready: managed.runtimeInstalled)
                if !bottle.isReadyForVR {
                    Button("Prepare") {
                        Task { await model.prepareBottle(bottle.name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
            } else {
                Chip(text: bottle.origin.label)
                Button("Copy into Basalt…", action: onImport)
                    .disabled(model.isBusy)
            }

            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([bottle.prefix])
                }
                if bottle.isManaged {
                    Divider()
                    if hasSteam {
                        Button("Launch Steam") { model.launchSteam(in: bottle) }
                    }
                    Button("Run Windows Installer…") { chooseInstaller() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 3)
    }

    private var originSymbol: String {
        switch bottle.origin {
        case .managed: return "mountain.2.fill"
        case .whisky: return "wineglass.fill"
        case .crossover: return "shippingbox.fill"
        }
    }

    private var originTint: Color {
        switch bottle.origin {
        case .managed: return .basaltLava
        case .whisky: return .purple
        case .crossover: return .blue
        }
    }

    private func componentChip(_ name: String, ready: Bool) -> some View {
        Chip(
            text: name,
            systemImage: ready ? "checkmark" : "xmark",
            tint: ready ? .green : .secondary)
            .help(ready ? "\(name) is installed" : "\(name) is not installed yet")
    }

    private func chooseInstaller() {
        guard let url = FilePanels.chooseFile(
            title: "Choose a Windows Installer", extensions: ["exe", "msi"]) else { return }
        model.runInstaller(url, in: bottle)
    }
}

private struct NewBottleSheet: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var engineID = ""
    @State private var isCreating = false

    var body: some View {
        SheetScaffold(
            symbol: "plus",
            title: "New Bottle",
            subtitle: "An isolated Windows environment for VR games."
        ) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("beat-saber"))
                    Picker("Engine", selection: $engineID) {
                        Text("Select an engine").tag("")
                        ForEach(model.engines, id: \.id) { engine in
                            Text(engine.supportsBasaltDXMT
                                 ? engine.id : "\(engine.id) (no VR handoff)")
                                .tag(engine.id)
                        }
                    }
                } footer: {
                    Text("After the bottle is created, choose Prepare to install the DXMT handoff and OpenXR runtime.")
                        .formFooterStyle()
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
        } actions: {
            if isCreating {
                ProgressView().controlSize(.small)
                Text("Creating bottle…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            Button("Create Bottle") {
                isCreating = true
                Task {
                    if await model.createBottle(name: name, engineID: engineID) {
                        dismiss()
                    } else {
                        isCreating = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(name.isEmpty || engineID.isEmpty || isCreating || model.isBusy)
        }
        .frame(width: 520, height: 280)
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            if engineID.isEmpty {
                engineID = model.engines.first(where: \.supportsBasaltDXMT)?.id ?? ""
            }
        }
    }
}
