import Foundation

/// The `opencomposite.ini` Basalt writes next to OpenComposite.
///
/// OpenComposite's `openxr` branch aborts the game on an unknown option or a malformed value
/// (`OpenOVR/Misc/Config.cpp`), so every option is checked against that parser before it is
/// written.
public struct OpenCompositeConfiguration: Equatable, Sendable {
    public enum Preset: String, CaseIterable, Sendable {
        /// D3D11 initialisation; suits Beat Saber-like games.
        case standard = "default"
        /// Half-Life: Alyx: also flip images with shaders. Without it, Alyx's menus and
        /// overlays appear upside down.
        case alyx
    }

    public enum ValueKind: Sendable {
        case boolean
        case decimal
        case colour
    }

    public struct Option: Equatable, Sendable {
        public let key: String
        public let value: String
    }

    /// The `[default]` options OpenComposite's `openxr` branch accepts.
    public static let supportedOptions: [String: ValueKind] = [
        "renderCustomHands": .boolean,
        "handColour": .colour,
        "supersampleRatio": .decimal,
        "haptics": .boolean,
        "admitUnknownProps": .boolean,
        "logGetTrackedProperty": .boolean,
        "stopOnSoftAbort": .boolean,
        "dx10Mode": .boolean,
        "enableHiddenMeshFix": .boolean,
        "invertUsingShaders": .boolean,
        "initUsingVulkan": .boolean,
        "hiddenMeshVerticalScale": .decimal,
        "logAllOpenVRCalls": .boolean,
    ]

    private static let booleanValues: Set<String> = [
        "true", "on", "enabled", "false", "off", "disabled",
    ]

    /// The first line of every `opencomposite.ini` Basalt writes.
    public static let managedHeader =
        "; Managed by BasaltVR. OpenComposite remains a separately built GPLv3 artifact."

    public private(set) var options: [Option] = []

    public static let standard = OpenCompositeConfiguration(preset: .standard)
    public static let alyx = OpenCompositeConfiguration(preset: .alyx)

    public init(preset: Preset = .standard) {
        // Basalt's runtime only offers XR_KHR_D3D11_enable.
        options = [Option(key: "initUsingVulkan", value: "false")]
        if preset == .alyx {
            options.append(Option(key: "invertUsingShaders", value: "true"))
        }
    }

    /// Sets or replaces one option, keeping the first position of an existing key.
    public mutating func set(_ key: String, to value: String) throws {
        guard let kind = Self.supportedOptions[key] else {
            let known = Self.supportedOptions.keys.sorted().joined(separator: ", ")
            throw BottleToolError(
                "Unknown OpenComposite option '\(key)'; OpenComposite aborts on unknown options. Supported: \(known)")
        }
        guard Self.isValid(value, for: kind) else {
            throw BottleToolError(
                "Invalid value '\(value)' for OpenComposite option '\(key)'; expected \(Self.describe(kind))")
        }
        let option = Option(key: key, value: value)
        if let index = options.firstIndex(where: { $0.key == key }) {
            options[index] = option
        } else {
            options.append(option)
        }
    }

    /// Applies a `key=value` assignment.
    public mutating func apply(_ assignment: String) throws {
        guard let separator = assignment.firstIndex(of: "=") else {
            throw BottleToolError("OpenComposite option '\(assignment)' must be KEY=VALUE")
        }
        try set(String(assignment[..<separator]),
                to: String(assignment[assignment.index(after: separator)...]))
    }

    public func value(for key: String) -> String? {
        options.first { $0.key == key }?.value
    }

    public var iniText: String {
        var lines = [Self.managedHeader]
        lines += options.map { "\($0.key)=\($0.value)" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isValid(_ value: String, for kind: ValueKind) -> Bool {
        switch kind {
        case .boolean:
            return booleanValues.contains(value.lowercased())
        case .decimal:
            // OpenComposite uses strtof and requires it to consume the whole value.
            guard !value.isEmpty, value.allSatisfy({ "0123456789.-+eE".contains($0) }),
                  let number = Double(value) else { return false }
            return number.isFinite
        case .colour:
            return value.count == 7 && value.first == "#" &&
                value.dropFirst().allSatisfy(\.isHexDigit)
        }
    }

    private static func describe(_ kind: ValueKind) -> String {
        switch kind {
        case .boolean: return "true/on/enabled/false/off/disabled"
        case .decimal: return "a decimal number such as 1.0"
        case .colour: return "a CSS hex colour such as #ff8800"
        }
    }
}
