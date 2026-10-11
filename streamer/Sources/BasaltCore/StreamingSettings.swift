import Foundation

/// Per-eye dimensions shared by the CLI today and launch profiles / SwiftUI
/// controls later. The encoded side-by-side frame is twice `width`.
public struct PerEyeResolution: Equatable, Codable, Sendable {
    public static let dimensionRange = 256...4_096

    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard Self.dimensionRange.contains(width), Self.dimensionRange.contains(height) else {
            throw BasaltError("Per-eye resolution must be between "
                              + "\(Self.dimensionRange.lowerBound) and "
                              + "\(Self.dimensionRange.upperBound) pixels per dimension")
        }
        guard width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw BasaltError("Per-eye resolution must use even dimensions for H.264")
        }
        self.width = width
        self.height = height
    }

    public static let performance = try! Self(width: 896, height: 944)
    public static let balanced = try! Self(width: 1_152, height: 1_216)
    public static let quality = try! Self(width: 1_344, height: 1_408)

    public static func parse(_ value: String) throws -> Self {
        switch value.lowercased() {
        case "performance": return .performance
        case "balanced": return .balanced
        case "quality": return .quality
        default:
            let dimensions = value.lowercased().split(separator: "x", omittingEmptySubsequences: false)
            guard dimensions.count == 2,
                  let width = Int(dimensions[0]), let height = Int(dimensions[1]) else {
                throw BasaltError("--resolution expects performance, balanced, quality, or WIDTHxHEIGHT")
            }
            return try Self(width: width, height: height)
        }
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let width = try values.decode(Int.self, forKey: .width)
        let height = try values.decode(Int.self, forKey: .height)
        try self.init(width: width, height: height)
    }
}

/// Quest decoder buffering profiles. Balanced preserves the validated
/// baseline, low trims 0.2 frame, and ultra minimizes both the target and
/// history used by the headset's decoder queue. Ultra favors latency over
/// tolerance for uneven frame delivery.
public enum StreamLatencyPreset: String, Codable, CaseIterable, Sendable {
    case ultra
    case low
    case balanced

    public var maximumBufferingFrames: Float {
        switch self {
        case .ultra: return 1.0
        case .low: return 1.3
        case .balanced: return 1.5
        }
    }

    public var bufferingHistoryWeight: Float {
        switch self {
        case .ultra: return 0.5
        case .low, .balanced: return 0.8
        }
    }
}
