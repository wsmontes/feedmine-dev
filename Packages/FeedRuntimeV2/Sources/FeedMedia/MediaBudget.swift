import Foundation

/// Media admission limits, carried over from `MediaAssetStore` (plan §10).
///
/// The legacy store already rejects before decoding, caps dimensions and downsamples; relaxing
/// any of these by accident is the risk this type exists to prevent. Values are the current
/// implementation's limits and remain subject to measurement, not to silent edit.
public struct MediaBudget: Equatable, Sendable {
    /// Compressed bytes accepted for one asset.
    public let maxCompressedBytes: Int
    /// Maximum width or height in pixels.
    public let maxDimension: Int
    /// Maximum width × height.
    public let maxPixels: Int

    /// Current `MediaAssetStore` limits: 12 MiB, 12 000 px, 50 M pixels.
    public static let current = MediaBudget(
        maxCompressedBytes: 12 * 1024 * 1024,
        maxDimension: 12_000,
        maxPixels: 50_000_000
    )
}

public enum MediaRejection: Equatable, Sendable {
    case empty
    case tooManyBytes(Int)
    case zeroDimension
    case dimensionTooLarge(Int)
    case tooManyPixels(Int)

    public var description: String {
        switch self {
        case .empty: return "empty payload"
        case .tooManyBytes(let bytes): return "compressed payload \(bytes) bytes over budget"
        case .zeroDimension: return "zero width or height"
        case .dimensionTooLarge(let dimension): return "dimension \(dimension) over budget"
        case .tooManyPixels(let pixels): return "\(pixels) pixels over budget"
        }
    }
}

public enum MediaAcceptance: Equatable, Sendable {
    case accepted(downsampleTo: Int?)
    case rejected(MediaRejection)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

extension MediaBudget {
    /// Inspects metadata before any decode happens. `pixelWidth`/`pixelHeight` are the
    /// container-reported dimensions, not the decoded bitmap.
    public func inspect(
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        targetWidth: Int? = nil
    ) -> MediaAcceptance {
        guard byteCount > 0 else { return .rejected(.empty) }
        guard byteCount <= maxCompressedBytes else {
            return .rejected(.tooManyBytes(byteCount))
        }
        guard pixelWidth > 0, pixelHeight > 0 else { return .rejected(.zeroDimension) }
        guard pixelWidth <= maxDimension, pixelHeight <= maxDimension else {
            return .rejected(.dimensionTooLarge(max(pixelWidth, pixelHeight)))
        }
        let pixels = pixelWidth * pixelHeight
        guard pixels <= maxPixels else { return .rejected(.tooManyPixels(pixels)) }

        guard let targetWidth, targetWidth > 0, targetWidth < pixelWidth else {
            return .accepted(downsampleTo: nil)
        }
        return .accepted(downsampleTo: targetWidth)
    }
}
