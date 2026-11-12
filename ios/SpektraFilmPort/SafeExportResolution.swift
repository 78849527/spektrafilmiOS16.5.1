import Foundation

/// User-selected output resolution. Never change .original on failure.
enum ExportResolutionMode: Equatable {
    case original
    case safe
}

/// Bounded entire-frame export size. This affects the CI INPUT before film
/// physics and before source sequential SciPy RNG generation; it must not
/// restart the original random stream at tile boundaries.
///
/// Conservative mobile envelope:
/// - <= 3.0 million output pixels
/// - <= 30% of min(1.5 GB, RAM / 3) at 104 bytes/pixel, matching the
///   existing OriginalSourceSciPyParticles conservative memory estimate.
/// This is a heuristic, not a guarantee against iOS jetsam or GPU failures.
/// Never silently use a lower resolution than the user explicitly selected.
enum SafeExportResolution {
    static let maximumPixels: UInt64 = 3_000_000
    static let estimatedBytesPerPixel: UInt64 = 104

    struct Dimensions: Equatable {
        let width: Int
        let height: Int
        let reduced: Bool

        var pixels: UInt64 { UInt64(width) * UInt64(height) }
    }

    static func target(
        width: Int, height: Int,
        physicalMemory: UInt64
    ) throws -> Dimensions {
        guard width > 0, height > 0,
              width <= 50_000, height <= 50_000,
              physicalMemory > 0 else {
            throw Failure.invalid("安全输出：原图尺寸或可用设备内存数据无效")
        }
        let sourcePixels = UInt64(width) * UInt64(height)
        let memoryBudget = min(UInt64(1_500_000_000), physicalMemory / 3)
        let allowedByMemory = (memoryBudget / 10 * 3) / estimatedBytesPerPixel
        let allowed = min(sourcePixels, maximumPixels, allowedByMemory)
        guard allowed > 0 else {
            throw Failure.invalid("安全输出：设备内存预算不足，无法计算安全分辨率")
        }
        if allowed == sourcePixels {
            return Dimensions(width: width, height: height, reduced: false)
        }
        let factor = sqrt(Double(allowed) / Double(sourcePixels))
        var scaledW = max(1, Int((Double(width) * factor).rounded(.down)))
        var scaledH = max(1, Int((Double(height) * factor).rounded(.down)))
        while UInt64(scaledW) * UInt64(scaledH) > allowed {
            if scaledW >= scaledH, scaledW > 1 {
                scaledW -= 1
            } else if scaledH > 1 {
                scaledH -= 1
            } else {
                throw Failure.invalid("安全输出：无法满足设备内存预算")
            }
        }
        return Dimensions(width: scaledW, height: scaledH, reduced: true)
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }
}
