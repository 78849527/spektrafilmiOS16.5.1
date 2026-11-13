import Foundation
#if os(iOS)
import os
#endif

/// User chooses resolution explicitly; original must never silently shrink.
enum ExportResolutionMode: Equatable {
    case original
    case safe      // adaptive 50% of measured budget, no fixed pixel ceiling
    case economy   // conservative <=3MP fallback at 30% of budget

    var title: String {
        switch self {
        case .original: return "原始分辨率"
        case .safe: return "智能安全分辨率"
        case .economy: return "省内存分辨率"
        }
    }
}

/// Whole-frame output estimate BEFORE running SciPy, FIR/IIR or paper.
/// For a given source, chosen mode and captured budget, the planned output
/// is stable. Never retry at a lower resolution after an allocation failure.
///
/// The physical 1.5GB budget is NOT free RAM. On iPhone, Apple's
/// os_proc_available_memory() also caps the estimate with CURRENT PROCESS
/// memory headroom. The app may still be killed by jetsam: this is a
/// conservative heuristic, not a memory reservation or a guarantee.
enum SafeExportResolution {
    static let economyMaximumPixels: UInt64 = 3_000_000
    static let estimatedBytesPerPixel: UInt64 = 104
    static let physicalMaximumBudget: UInt64 = 1_500_000_000
    static let intelligentBudgetPercent: UInt64 = 50
    static let economyBudgetPercent: UInt64 = 30

    struct Dimensions: Equatable {
        let width: Int
        let height: Int
        let reduced: Bool
        var pixels: UInt64 { UInt64(width) * UInt64(height) }
    }

    struct Plan {
        let mode: ExportResolutionMode
        let sourceWidth: Int
        let sourceHeight: Int
        let dimensions: Dimensions
        /// min(1.5GB, physicalRAM/3, measured process headroom if available).
        let effectiveBudgetBytes: UInt64
        let processHeadroomBytes: UInt64?
        /// Portion of effective budget earmarked by the selected mode.
        let allocationAllowanceBytes: UInt64
        let estimatedPeakBytes: UInt64

        var summary: String {
            let estimatedMB = estimatedPeakBytes / 1_000_000
            let budgetMB = effectiveBudgetBytes / 1_000_000
            let allowanceMB = allocationAllowanceBytes / 1_000_000
            let headroom = processHeadroomBytes.map {
                "\($0 / 1_000_000) MB"
            } ?? "未获取（按物理预算估算）"
            return """
            原始照片：\(sourceWidth) × \(sourceHeight)（约 \(Double(sourceWidth)*Double(sourceHeight)/1_000_000) 百万像素）
            预计输出：\(dimensions.width) × \(dimensions.height)（约 \(Double(dimensions.pixels)/1_000_000) 百万像素）
            预计显影峰值：约 \(estimatedMB) MB
            设备安全预算：约 \(budgetMB) MB；本档计划上限 \(allowanceMB) MB
            当前 App 可分配余量：\(headroom)
            JPEG 质量 98%。估算不是内存保证；失败不自动降档。
            """
        }
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    /// iOS 13+ API. Apple documents this as advisory, not a reservation.
    /// A zero on an iPhone indicates no usable allocation headroom.
    static func currentProcessHeadroom() -> UInt64? {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    static func plan(
        width: Int, height: Int,
        physicalMemory: UInt64,
        processAvailableMemory: UInt64?,
        mode: ExportResolutionMode,
        estimatedBytesPerPixel: UInt64 =
            SafeExportResolution.estimatedBytesPerPixel
    ) throws -> Plan {
        guard width > 0, height > 0, width <= 50_000,
              height <= 50_000, physicalMemory > 0,
              estimatedBytesPerPixel >= 1 && estimatedBytesPerPixel <= 1024
        else {
            throw Failure.invalid("输出分辨率：原图尺寸或设备内存数据无效")
        }
        let sourcePixels = UInt64(width) * UInt64(height)
        let physicalBudget = min(
            physicalMaximumBudget, physicalMemory / 3
        )
        let budget = min(physicalBudget,
                         processAvailableMemory ?? physicalBudget)
        let percentage: UInt64
        switch mode {
        case .original: percentage = 100
        case .safe: percentage = intelligentBudgetPercent
        case .economy: percentage = economyBudgetPercent
        }
        let allowance = mode == .original ?
            physicalBudget : budget / 100 * percentage
        let targetPixels: UInt64
        if mode == .original {
            targetPixels = sourcePixels
        } else {
            guard budget > 0 && allowance >= estimatedBytesPerPixel else {
                throw Failure.invalid(
                    "安全输出：当前 App 可分配内存不足，已停止；不会自动降分辨率或切换算法"
                )
            }
            let byMemory = allowance / estimatedBytesPerPixel
            targetPixels = min(
                sourcePixels, byMemory,
                mode == .economy ? economyMaximumPixels : sourcePixels
            )
        }
        guard targetPixels > 0 else {
            throw Failure.invalid("安全输出：预算不足以容纳有效输出图像")
        }
        let dimensions: Dimensions
        if targetPixels == sourcePixels {
            dimensions = Dimensions(
                width: width, height: height, reduced: false
            )
        } else {
            let factor = sqrt(
                Double(targetPixels) / Double(sourcePixels)
            )
            var w = max(1, Int((Double(width)*factor).rounded(.down)))
            var h = max(1, Int((Double(height)*factor).rounded(.down)))
            while UInt64(w) * UInt64(h) > targetPixels {
                if w >= h && w > 1 { w -= 1 }
                else if h > 1 { h -= 1 }
                else { throw Failure.invalid("安全输出尺寸计算失败") }
            }
            dimensions = Dimensions(width:w, height:h, reduced:true)
        }
        return Plan(
            mode: mode, sourceWidth: width, sourceHeight: height,
            dimensions: dimensions, effectiveBudgetBytes: budget,
            processHeadroomBytes: processAvailableMemory,
            allocationAllowanceBytes: allowance,
            estimatedPeakBytes: dimensions.pixels * estimatedBytesPerPixel
        )
    }

    /// Capture system headroom before the export UI confirms a concrete size.
    static func capture(
        width: Int, height: Int, mode: ExportResolutionMode,
        estimatedBytesPerPixel: UInt64 =
            SafeExportResolution.estimatedBytesPerPixel
    ) throws -> Plan {
        try plan(
            width:width, height:height,
            physicalMemory:ProcessInfo.processInfo.physicalMemory,
            processAvailableMemory:currentProcessHeadroom(),
            mode:mode,estimatedBytesPerPixel:estimatedBytesPerPixel
        )
    }

    /// Do NOT reduce the previously confirmed size if memory headroom fell;
    /// report the change and let the user explicitly pick another mode.
    static func validateBeforeRender(_ plan: Plan) throws {
        guard plan.mode != .original else { return }
        if let current = currentProcessHeadroom() {
            guard current > 0,
                  plan.estimatedPeakBytes <= current / 100 * (
                    plan.mode == .safe ?
                    intelligentBudgetPercent : economyBudgetPercent
                  ) else {
                throw Failure.invalid(
                    "安全输出：当前可分配内存已减少，无法按确认的 " +
                    "\(plan.dimensions.width)×\(plan.dimensions.height) 导出。" +
                    "请重新选择安全分辨率；不会静默缩图。"
                )
            }
        }
    }

    /// Backwards-compatibility for old tests; .safe now means adaptive.
    static func target(
        width: Int, height: Int, physicalMemory: UInt64
    ) throws -> Dimensions {
        try plan(
            width:width,height:height,physicalMemory:physicalMemory,
            processAvailableMemory:nil,mode:.safe
        ).dimensions
    }
}
