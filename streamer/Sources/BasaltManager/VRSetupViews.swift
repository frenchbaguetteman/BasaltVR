import SwiftUI
import AppKit
import BasaltBottleKit
import BasaltManagerKit

extension VRMode {
    var pickerLabel: String {
        switch self {
        case .auto: return "Auto"
        case .openXR: return "Native OpenXR"
        case .openVR: return "OpenVR (OpenComposite)"
        case .alyx: return "Half-Life: Alyx"
        }
    }
}

/// What Basalt found, the VR mode picker, and whether the local builds Basalt needs exist.
/// Shared by Add Game and Prepare VR so both run the same setup.
struct VRSetupSection: View {
    let detection: VRGameDetection?
    let detectionError: String?
    @Binding var mode: VRMode
    let artifacts: VRArtifacts

    private var kind: VRRuntimeKind? { detection?.resolve(mode) }

    var body: some View {
        Section {
            if let detectionError {
                Label(detectionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let detection {
                Label(detection.summary, systemImage: icon(detection.verdict))
                    .fixedSize(horizontal: false, vertical: true)
                Picker("VR mode", selection: $mode) {
                    ForEach(VRMode.allCases, id: \.self) { mode in
                        if mode == .auto, let suggested = detection.suggestedKind {
                            Text("Auto (\(suggested.label))").tag(mode)
                        } else {
                            Text(mode.pickerLabel).tag(mode)
                        }
                    }
                }
                if kind == nil {
                    Label("Basalt is not sure. Choose the mode the game uses.",
                          systemImage: "questionmark.circle")
                        .foregroundStyle(.orange)
                    if !artifacts.isSourceCheckout,
                       let problem = artifacts.missingProblem(for: .openVR) {
                        // Said before a mode is chosen: a release build cannot set up OpenVR.
                        Label(problem, systemImage: "shippingbox")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let kind, let problem = artifacts.missingProblem(for: kind) {
                    Label(problem, systemImage: artifacts.isSourceCheckout ? "hammer" : "shippingbox")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let kind {
                    Text(plan(kind))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for VR files…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("VR Setup")
        } footer: {
            Text("Basalt keeps the game's own files and can restore them. A ready setup means the files are in place, not that the game is known to work.")
                .formFooterStyle()
        }
    }

    private func icon(_ verdict: VRGameDetection.Verdict) -> String {
        switch verdict {
        case .knownAlyx, .openVR, .openXR: return "visionpro"
        case .uncertain: return "questionmark.circle"
        case .nothingFound: return "magnifyingglass"
        }
    }

    private func plan(_ kind: VRRuntimeKind) -> String {
        switch kind {
        case .openXR:
            return "Native OpenXR: Basalt changes no game files."
        case .openVR:
            return "Basalt installs your local OpenComposite build as the game's openvr_api.dll and keeps the original."
        case .alyx:
            return "Basalt installs its OpenVR proxy and OpenComposite in game/bin/win64, writes the Alyx settings, and starts the game with -vr -dx11."
        }
    }
}

/// One line about the files Basalt last installed for a profile.
struct VRStatusLabel: View {
    let status: VRSetupStatus

    var body: some View {
        switch status {
        case .notPrepared:
            Label("Not prepared", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .nativeOpenXR:
            Label("Native OpenXR: no files needed", systemImage: "checkmark.circle")
        case .ready(let kind, let checked):
            Label("Setup ready: \(kind.label) files checked \(checked.formatted(date: .omitted, time: .shortened))",
                  systemImage: "checkmark.seal")
        case .changed(_, let issues):
            Label("Files changed since setup: \(issues.joined(separator: "; ")). Prepare VR again.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Prepare VR for an existing profile, or restore the game's own files.
struct PrepareVRSheet: View {
    let profile: LaunchProfile
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var location: VRGameLocation?
    @State private var detection: VRGameDetection?
    @State private var detectionError: String?
    @State private var mode = VRMode.auto
    @State private var isWorking = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var customFiles: VRCustomFilesError?
    @State private var confirmingRestore = false

    private var status: VRSetupStatus { model.vrStatuses[profile.name] ?? .notPrepared }
    private var kind: VRRuntimeKind? { detection?.resolve(mode) }

    private var canPrepare: Bool {
        guard !isWorking, location != nil, let kind else { return false }
        return model.vrArtifacts.missingProblem(for: kind) == nil
    }

    /// Why Prepare VR is off when the build it needs is missing. Restore needs no build.
    private var prepareHelp: String {
        kind.flatMap { model.vrArtifacts.missingProblem(for: $0) } ?? ""
    }

    var body: some View {
        SheetScaffold(
            symbol: "visionpro",
            title: "Prepare VR",
            subtitle: "\(profile.name) · \(profile.bottleName)"
        ) {
            Form {
                Section {
                    VRStatusLabel(status: status)
                } header: {
                    Text("Current Setup")
                }
                VRSetupSection(detection: detection, detectionError: detectionError,
                               mode: $mode, artifacts: model.vrArtifacts)
                if let message {
                    Section {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
        } actions: {
            if status.hasRecord {
                Button("Restore Game Files…") { confirmingRestore = true }
                    .disabled(isWorking)
            }
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Prepare VR") { prepare(replacing: false) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canPrepare)
                .help(prepareHelp)
        }
        .frame(width: 620, height: 560)
        .interactiveDismissDisabled(isWorking)
        .task { await inspect() }
        .confirmationDialog(
            "Replace files Basalt did not write?",
            isPresented: Binding(get: { customFiles != nil }, set: { if !$0 { customFiles = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace and Keep Copies") { prepare(replacing: true) }
            Button("Cancel", role: .cancel) { customFiles = nil }
        } message: {
            Text(customFiles?.localizedDescription ?? "")
        }
        .confirmationDialog(
            "Restore the game's own files?", isPresented: $confirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Basalt puts back the original openvr_api.dll, removes the files it installed, and undoes its launch-argument changes. Files that changed since setup are left alone. If a game update replaced openvr_api.dll, Basalt keeps the newer DLL.")
        }
    }

    private func inspect() async {
        do {
            let location = try model.vrLocation(for: profile)
            self.location = location
            switch await model.inspectVR(location, bottleName: profile.bottleName) {
            case .success(let detection): self.detection = detection
            case .failure(let error): detectionError = error.localizedDescription
            }
        } catch {
            detectionError = error.localizedDescription
        }
    }

    private func prepare(replacing: Bool) {
        guard let location else { return }
        customFiles = nil
        isWorking = true
        message = nil
        errorMessage = nil
        Task {
            switch await model.prepareVR(profileName: profile.name, location: location,
                                         mode: mode, replaceCustomFiles: replacing) {
            case .success(let result):
                message = VRMessages.prepared(result)
            case .failure(let error as VRCustomFilesError):
                customFiles = error
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func restore() {
        isWorking = true
        message = nil
        errorMessage = nil
        Task {
            switch await model.restoreVR(profileName: profile.name) {
            case .success(let report): message = VRMessages.restored(report)
            case .failure(let error): errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

enum VRMessages {
    static func prepared(_ result: VRPrepareResult) -> String {
        var text: String
        switch result.kind {
        case .openXR:
            text = "Native OpenXR: no game files changed."
        case .openVR, .alyx:
            let count = result.targets.count
            text = "Setup ready: \(result.kind.label) installed in \(count == 1 ? "1 folder" : "\(count) folders") and checked. Test the game with the headset to know if it works."
        }
        if !result.replacedCopies.isEmpty {
            text += " Copies of the replaced files: " + result.replacedCopies.map(\.lastPathComponent).joined(separator: ", ") + "."
        }
        if !result.skipped.isEmpty {
            text += " Left unchanged because they do not match the OpenComposite build: "
                + result.skipped.map { "\($0.url.path) (\($0.architecture))" }.joined(separator: ", ")
                + "."
        }
        if !result.updatedByGame.isEmpty {
            text += " The game's openvr_api.dll changed since Basalt kept the original, so the newer DLL is the original now. "
                + staleOriginalsSentence(result.staleOriginals)
        }
        return text
    }

    private static func staleOriginalsSentence(_ urls: [URL]) -> String {
        "The older original is kept as " + urls.map(\.path).joined(separator: ", ") + "."
    }

    static func restored(_ report: VRRestoreReport) -> String {
        let keptFolders = Set(report.unrestored.map { $0.deletingLastPathComponent().path })
        let updated = Set(report.updatedByGame)
        let changed = report.kept.filter {
            !keptFolders.contains($0.deletingLastPathComponent().path) && !updated.contains($0)
        }
        var text: String
        if report.isComplete {
            text = "Restored the game's files."
        } else {
            text = "Restore is not complete: the game's original openvr_api.dll is missing, so Basalt kept its setup in "
                + keptFolders.sorted().joined(separator: ", ")
                + ". Put the original back as openvr_api.dll.basalt-original, or let Steam verify the game's files, then Restore again."
            if !report.restored.isEmpty { text += " Other files were restored." }
        }
        if !report.updatedByGame.isEmpty {
            text += " The game updated " + report.updatedByGame.map(\.path).joined(separator: ", ")
                + " after setup, so Basalt left the newer DLL in place and will treat it as the original next time. "
                + staleOriginalsSentence(report.staleOriginals)
        }
        if !changed.isEmpty {
            text += " Left alone because they changed after setup: "
                + changed.map(\.path).joined(separator: ", ") + "."
        }
        return text
    }
}
