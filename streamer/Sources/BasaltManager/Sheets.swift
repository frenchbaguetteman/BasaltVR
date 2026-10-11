import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

struct PerGameSettingsSheet: View {
    let profileName: String
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: StreamLaunchSettings

    init(profileName: String, model: BasaltAppModel) {
        self.profileName = profileName
        self.model = model
        _settings = State(initialValue: model.streamSettings(for: profileName))
    }

    private var hasOverride: Bool { model.profileSettings[profileName] != nil }

    var body: some View {
        SheetScaffold(symbol: "slider.horizontal.3", title: "Stream Settings", subtitle: profileName) {
            Form {
                Section {
                    StreamSettingsFields(settings: $settings, audioDevices: model.audioDevices)
                } footer: {
                    Text(hasOverride
                         ? "This game uses its own stream settings. Use Defaults returns it to the settings in Settings."
                         : "This game follows your default stream settings. Saving gives it its own copy.")
                        .formFooterStyle()
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Use Defaults") {
                model.resetStreamSettings(for: profileName)
                dismiss()
            }
            .disabled(!hasOverride)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                model.saveStreamSettings(settings, for: profileName)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .frame(width: 600, height: 440)
    }
}

struct ProfileEditorSheet: View {
    let profile: LaunchProfile
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: LaunchSource
    @State private var executable: String
    @State private var workingDirectory: String
    @State private var arguments: String
    @State private var environment: String
    @State private var confirmingDelete = false

    init(profile: LaunchProfile, model: BasaltAppModel) {
        self.profile = profile
        self.model = model
        _source = State(initialValue: profile.source)
        _executable = State(initialValue: profile.executable)
        _workingDirectory = State(initialValue: profile.workingDirectory ?? "")
        _arguments = State(initialValue: profile.arguments.joined(separator: "\n"))
        _environment = State(initialValue: profile.environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        SheetScaffold(
            symbol: "doc.text",
            title: "Launch Profile",
            subtitle: "\(profile.name) · \(profile.bottleName)"
        ) {
            Form {
                Section {
                    Picker("Source", selection: $source) {
                        ForEach(LaunchSource.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    StackedField(title: "Windows executable", text: $executable,
                                 prompt: "C:\\Games\\Game.exe")
                    StackedField(title: "Working directory", text: $workingDirectory,
                                 prompt: "Optional host folder")
                }

                Section {
                    TextEditor(text: $arguments)
                        .font(.body.monospaced())
                        .frame(minHeight: 60)
                } header: {
                    Text("Arguments")
                } footer: {
                    Text("One argument per line.")
                        .formFooterStyle()
                }

                Section {
                    TextEditor(text: $environment)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                } header: {
                    Text("Environment")
                } footer: {
                    Text("One KEY=VALUE entry per line.")
                        .formFooterStyle()
                }

                Section {
                    HStack {
                        Text("Replace the game's openvr_api.dll with a copy of OpenComposite you supply.")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Button("Install…") { installOpenComposite() }
                    }
                } header: {
                    Text("OpenComposite")
                }
            }
            .formStyle(.grouped)
        } actions: {
            Button("Delete Profile…", role: .destructive) { confirmingDelete = true }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .frame(width: 640, height: 640)
        .confirmationDialog(
            "Delete '\(profile.name)'?", isPresented: $confirmingDelete,
            titleVisibility: .visible) {
                Button("Delete Profile", role: .destructive) {
                    Task { await model.deleteProfile(profile.name); dismiss() }
                }
            } message: {
                Text("The bottle and installed game will not be removed.")
            }
    }

    private func save() {
        var values = [String: String]()
        for line in environment.components(separatedBy: .newlines) {
            guard let split = line.firstIndex(of: "="), split != line.startIndex else { continue }
            values[String(line[..<split])] = String(line[line.index(after: split)...])
        }
        let updated = LaunchProfile(
            name: profile.name, bottleName: profile.bottleName, source: source,
            executable: executable.trimmingCharacters(in: .whitespacesAndNewlines),
            arguments: arguments.components(separatedBy: .newlines).filter { !$0.isEmpty },
            workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
            environment: values)
        Task { await model.updateProfile(updated); dismiss() }
    }

    private func installOpenComposite() {
        guard let bottle = model.bottles.first(where: { $0.name == profile.bottleName }) else {
            model.alertMessage = "The managed bottle for this profile is missing."
            return
        }
        let dll = UTType(filenameExtension: "dll")!
        guard let source = FilePanels.chooseFile(
            title: "Choose the OpenComposite openvr_api.dll", extensions: ["dll"]) else { return }

        let targetPanel = NSSavePanel()
        targetPanel.title = "Choose the game's openvr_api.dll location"
        targetPanel.allowedContentTypes = [dll]
        targetPanel.nameFieldStringValue = "openvr_api.dll"
        targetPanel.directoryURL = URL(fileURLWithPath: bottle.prefixPath)
            .appendingPathComponent("drive_c", isDirectory: true)
        guard targetPanel.runModal() == .OK, let target = targetPanel.url else { return }
        Task {
            await model.installOpenComposite(
                profileName: profile.name, artifact: source, target: target)
        }
    }
}

struct ImportBottleSheet: View {
    let bottle: DiscoveredBottle
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isCopying = false

    init(bottle: DiscoveredBottle, model: BasaltAppModel) {
        self.bottle = bottle
        self.model = model
        let lowered = bottle.name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        _name = State(initialValue: String((lowered.isEmpty ? "imported-bottle" : lowered).prefix(56)))
    }

    var body: some View {
        SheetScaffold(
            symbol: "square.on.square",
            title: "Copy into Basalt",
            subtitle: "\(bottle.name) · \(bottle.origin.label)"
        ) {
            Form {
                Section {
                    TextField("New bottle name", text: $name)
                    LabeledContent("Source") { PathText(path: bottle.prefix.path) }
                }
                Section {
                    Label("The original prefix remains untouched.", systemImage: "lock.shield")
                    Label("Files use APFS copy-on-write cloning when supported, so the copy is fast and space-efficient.", systemImage: "internaldrive")
                    Label("Copying never launches Steam. Prepare installs Basalt DXMT and OpenXR afterward.", systemImage: "wrench.and.screwdriver")
                }
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .disabled(isCopying)
        } actions: {
            if isCopying {
                ProgressView().controlSize(.small)
                Text("Cloning… keep BasaltVR open.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCopying)
            Button(isCopying ? "Copying…" : "Copy Bottle") {
                let destination = name
                isCopying = true
                Task {
                    if await model.importBottle(bottle, as: destination) {
                        dismiss()
                    } else {
                        isCopying = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(name.isEmpty || isCopying)
        }
        .frame(width: 580, height: 380)
        .interactiveDismissDisabled(isCopying)
    }
}

struct BSManagerInstallerSheet: View {
    let installer: URL
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBottle = ""

    var body: some View {
        SheetScaffold(
            symbol: "arrow.down.circle",
            title: "Install BSManager",
            subtitle: "Runs the Windows installer inside a Basalt bottle.",
            tint: .purple
        ) {
            Form {
                Section {
                    LabeledContent("Installer") {
                        Text(installer.lastPathComponent).font(.callout.monospaced())
                    }
                    BottlePicker(selection: $selectedBottle, bottles: model.bottles)
                } footer: {
                    Text("BSManager and the Beat Saber versions it creates stay isolated in that bottle.")
                        .formFooterStyle()
                }
            }
            .formStyle(.grouped)
        } actions: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Run Installer") {
                guard let bottle = model.bottles.first(where: {
                    $0.name == selectedBottle
                }) else { return }
                model.runBSManagerInstaller(installer, in: bottle)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selectedBottle.isEmpty)
        }
        .frame(width: 560, height: 300)
        .onAppear {
            if selectedBottle.isEmpty {
                selectedBottle = model.bsManagerInstallations.first?.bottleName
                    ?? (model.bottles.count == 1 ? model.bottles[0].name : "")
            }
        }
    }
}

struct BSManagerBottleSheet: View {
    let instance: BSManagerInstance
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBottle = ""

    var body: some View {
        SheetScaffold(
            symbol: "wand.and.stars",
            title: "Create BSManager Profile",
            subtitle: "Beat Saber \(instance.name)",
            tint: .purple
        ) {
            if model.bottles.isEmpty {
                ContentUnavailableView(
                    "No Basalt bottle",
                    systemImage: "shippingbox",
                    description: Text("Create and prepare a bottle before adding this instance."))
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        BottlePicker(selection: $selectedBottle, bottles: model.bottles)
                    } footer: {
                        Text("The bottle that will run this version. The BSManager instance stays in place and is not modified.")
                            .formFooterStyle()
                    }
                }
                .formStyle(.grouped)
            }
        } actions: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Profile") {
                guard let bottle = model.bottles.first(where: {
                    $0.name == selectedBottle
                }) else { return }
                Task {
                    await model.createBSManagerProfile(for: instance, in: bottle)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selectedBottle.isEmpty)
        }
        .frame(width: 540, height: 280)
        .onAppear {
            if selectedBottle.isEmpty {
                selectedBottle = instance.bottleName
                    ?? (model.bottles.count == 1 ? model.bottles[0].name : "")
            }
        }
    }
}

/// A full-width monospaced field under its label, for long Windows and host
/// paths that an inline form field would truncate.
private struct StackedField: View {
    let title: String
    @Binding var text: String
    var prompt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        }
        .padding(.vertical, 2)
    }
}

private struct BottlePicker: View {
    @Binding var selection: String
    let bottles: [ManagedBottle]

    var body: some View {
        Picker("Basalt bottle", selection: $selection) {
            Text("Select a bottle").tag("")
            ForEach(bottles, id: \.name) { bottle in
                Text(bottle.name).tag(bottle.name)
            }
        }
    }
}

// MARK: - Diagnostics

/// Shows exactly what a bug report contains before it is copied or saved.
/// The report is a snapshot taken when the sheet opens; nothing is sent.
struct DiagnosticReportSheet: View {
    let model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var includeLog = true
    @State private var report: DiagnosticReport?
    @State private var markdown = ""
    @State private var copied = false
    @State private var errorMessage: String?

    private let redactor = DiagnosticRedactor()
    private static let bugReportURL = URL(
        string: "https://github.com/frenchbaguetteman/BasaltVR/issues/new?template=bug_report.yml")!

    var body: some View {
        SheetScaffold(
            symbol: "stethoscope", title: "Diagnostic Report",
            subtitle: "Review what will be shared. BasaltVR never uploads it."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Include the session log", isOn: $includeLog)
                SessionLogView(text: markdown, followsTail: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08)))
                Text("Your home folder and user name, email addresses, Steam IDs, headset serials and names, Mac host names, IP and MAC addresses, and tokens are replaced with placeholders. Launch-profile environment values are never included.")
                    .formFooterStyle()
            }
            .padding(20)
        } actions: {
            Button("Open Bug Report Form") { NSWorkspace.shared.open(Self.bugReportURL) }
                .help("Opens GitHub in your browser; paste the copied report into the logs field")
            Spacer()
            Menu("Save") {
                Button("Markdown…") { save(asJSON: false) }
                Button("JSON…") { save(asJSON: true) }
            }
            .fixedSize()
            .disabled(report == nil)
            Button(copied ? "Copied" : "Copy Markdown") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                copied = true
            }
            .disabled(report == nil)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .frame(width: 760, height: 620)
        .onAppear(perform: rebuild)
        .onChange(of: includeLog) { rebuild() }
        .alert("BasaltVR", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func rebuild() {
        let snapshot = model.makeDiagnosticReport(includeLog: includeLog)
        report = snapshot
        markdown = snapshot.markdown(redactedWith: redactor)
        copied = false
    }

    private func save(asJSON: Bool) {
        guard let report, let url = FilePanels.saveFile(
            title: "Save Diagnostic Report", baseName: "BasaltVR-diagnostics",
            fileExtension: asJSON ? "json" : "md") else { return }
        do {
            let text = asJSON ? try report.json(redactedWith: redactor) : markdown
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
