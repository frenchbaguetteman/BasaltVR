import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BasaltCore
import BasaltManagerKit

/// "1 game", "2 games": a count with a regular English plural.
func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

extension Color {
    /// The molten seam in the BasaltVR icon; the app-wide tint.
    static let basaltLava = Color(red: 1.0, green: 0.47, blue: 0.12)
    static let basaltSlate = Color(red: 0.16, green: 0.16, blue: 0.18)
}

// MARK: - Session presentation

extension SessionState {
    var tint: Color {
        switch self {
        case .stopped: return .secondary
        case .starting: return .yellow
        case .streaming: return .green
        case .utility: return .blue
        case .failed: return .red
        }
    }

    var eyebrow: String {
        switch self {
        case .stopped: return "READY"
        case .starting: return "CONNECTING"
        case .streaming: return "LIVE"
        case .utility: return "RUNNING"
        case .failed: return "FAILED"
        }
    }

    var shortTitle: String {
        switch self {
        case .stopped: return "Idle"
        case .starting: return "Connecting…"
        case .streaming: return "Streaming"
        case .utility: return "Windows app running"
        case .failed: return "Session failed"
        }
    }

    var shortDetail: String {
        switch self {
        case .stopped: return "No VR session running"
        case .starting: return "Preparing the bottle and headset"
        case .streaming(let profile): return profile
        case .utility(let name): return name
        case .failed(let message): return message
        }
    }
}

extension StreamConnectionMode {
    var shortLabel: String { self == .wired ? "USB Cable" : "Wi-Fi" }
    var symbol: String { self == .wired ? "cable.connector" : "wifi" }
}

extension StreamLatencyPreset {
    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .low: return "Low"
        case .ultra: return "Ultra Low"
        }
    }
}

// MARK: - Surfaces

struct CardStyle: ViewModifier {
    var padding: CGFloat
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background(.background.secondary, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }
}

extension View {
    /// Confirms clearing Recent Sessions; shared by Stream and Settings.
    func clearSessionHistoryDialog(
        isPresented: Binding<Bool>, model: BasaltAppModel
    ) -> some View {
        confirmationDialog("Clear session history?", isPresented: isPresented) {
            Button("Clear History", role: .destructive) { model.clearSessionHistory() }
        } message: {
            Text("Games, bottles, and stream settings are not affected.")
        }
    }

    func cardStyle(padding: CGFloat = 16, cornerRadius: CGFloat = 12) -> some View {
        modifier(CardStyle(padding: padding, cornerRadius: cornerRadius))
    }

    /// Grouped-form footers otherwise inherit the primary label color and
    /// trailing alignment on recent macOS releases.
    func formFooterStyle() -> some View {
        font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small tinted capsule for states such as "VR" or "DXMT ✓".
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.15), in: Capsule())
    }
}

/// A chip that stays legible on top of artwork.
struct ArtworkChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

struct SymbolTile: View {
    let symbol: String
    var tint: Color = .basaltLava
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.16),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if pulsing { PulseRing(color: color) }
            }
    }
}

private struct PulseRing: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .scaleEffect(expanded ? 2.6 : 1)
            .opacity(expanded ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

struct ProgressRing: View {
    let progress: Double
    var tint: Color = .basaltLava
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.4), value: progress)
    }
}

/// A home-relative, middle-truncated path that still exposes the full value.
struct PathText: View {
    let path: String

    var body: some View {
        Text((path as NSString).abbreviatingWithTildeInPath)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

struct SectionTitle<Accessory: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if let count {
                Text("\(count)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

extension SectionTitle where Accessory == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Shared sheet chrome: an icon header, scrollable form content, and a
/// bottom action bar.
struct SheetScaffold<Content: View, Actions: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var tint: Color = .basaltLava
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(symbol: symbol, tint: tint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 2)

            content

            Divider()
            HStack(spacing: 10) { actions }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
    }
}

/// Wraps children onto new lines when they no longer fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - File panels

@MainActor
enum FilePanels {
    static func chooseFile(
        title: String, message: String? = nil, extensions: [String]
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = extensions.compactMap {
            UTType(filenameExtension: $0)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(
        title: String, message: String? = nil, startingAt directory: URL? = nil,
        canCreate: Bool = false
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks where to save an export. `baseName` gets a local timestamp and
    /// `fileExtension`, e.g. "BasaltVR-session-2026-10-09-2130.log".
    static func saveFile(title: String, baseName: String, fileExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "\(baseName)-\(stamp.string(from: Date())).\(fileExtension)"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
