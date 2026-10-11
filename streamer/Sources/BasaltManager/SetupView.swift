import SwiftUI
import BasaltManagerKit

struct SetupView: View {
    @ObservedObject var model: BasaltAppModel

    private var required: [SetupCheck] { model.setupChecks.filter(\.required) }
    private var optional: [SetupCheck] { model.setupChecks.filter { !$0.required } }
    private var readyCount: Int { model.setupChecks.filter { $0.status == .ready }.count }

    var body: some View {
        Form {
            Section { summary }

            Section {
                ForEach(required) { row(for: $0) }
            } header: {
                Text("Required")
            } footer: {
                Text("These enable VR game streaming. Build steps open the repository instructions.")
                    .formFooterStyle()
            }

            Section {
                ForEach(optional) { row(for: $0) }
            } header: {
                Text("Optional")
            } footer: {
                Text("Android Platform Tools are only needed for USB cable mode; wireless uses the local Wi-Fi network. Screen Recording is only needed for the desktop preview, and BlackHole is only needed for game audio in the headset.")
                    .formFooterStyle()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .navigationSubtitle("\(readyCount) of \(model.setupChecks.count) ready")
    }

    private var summary: some View {
        let ready = !model.setupChecks.isEmpty && model.missingRequiredSetupCount == 0
        let hasReadyBottle = model.bottles.contains(where: \.isReadyForVR)
        return HStack(spacing: 16) {
            ZStack {
                ProgressRing(
                    progress: Double(readyCount) / Double(max(model.setupChecks.count, 1)),
                    tint: ready ? .green : .basaltLava)
                Text("\(readyCount)/\(model.setupChecks.count)")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(ready
                     ? "Your Mac is ready for VR"
                     : "\(plural(model.missingRequiredSetupCount, "required step")) left")
                    .font(.title3.weight(.semibold))
                Text(ready
                     ? (hasReadyBottle
                        ? "Pick a game in the Library and press Play."
                        : "Next, create and prepare a Basalt bottle for your games.")
                     : "Finish the required items below, then create a bottle and add a game.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if ready {
                if hasReadyBottle {
                    Button("Open Library") { model.selection = .library }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Set Up a Bottle") { model.selection = .bottles }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func row(for check: SetupCheck) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: check))
                .font(.title3)
                .foregroundStyle(color(for: check))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                if check.detail.hasPrefix("/") {
                    PathText(path: check.detail)
                } else {
                    Text(check.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if check.status != .ready, let action = check.action {
                Button(action) {
                    Task { await model.installDependency(for: check) }
                }
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 2)
    }

    private func symbol(for check: SetupCheck) -> String {
        switch check.status {
        case .ready: return "checkmark.circle.fill"
        case .actionNeeded: return check.required ? "exclamationmark.circle.fill" : "minus.circle"
        case .unavailable: return "xmark.octagon.fill"
        }
    }

    private func color(for check: SetupCheck) -> Color {
        switch check.status {
        case .ready: return .green
        case .actionNeeded: return check.required ? .orange : .secondary
        case .unavailable: return .red
        }
    }
}
