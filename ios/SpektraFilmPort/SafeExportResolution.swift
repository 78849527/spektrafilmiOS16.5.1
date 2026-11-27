import Foundation
#if os(iOS)
import os
#endif

/// User chooses resolution explicitly; original must never silently shrink.
enum ExportResolutionMode: Equatable {
    case original
    case safe      // adaptive up to 12MP, live headroom enforced
    case economy   // adaptive 30% of live memory, up to 7.2MP
    case megapixels(Int) // explicit cap in units of 10,000 pixels

    static let presetWanPixels = [720, 800, 900, 1000, 1200]

    var permitsRAWFullOpticalExport: Bool {
        switch self {
        case .original, .megapixels: return true
        case .safe, .economy: return false
        }
    }

    var title: String {
        switch self {
        case .original: return "原始分辨率"
        case .safe: return "智能安全分辨率"
        case .economy: return "省内存分辨率"
        case .megapixels(let count): return "\(count) 万像素"
        }
    }
}

/// Whole-frame output estimate BEFORE running SciPy, FIR/IIR or paper.
/// For a given source, chosen mode and captured budget, the planned output
/// is stable. Never retry at a lower resolution after an allocation failure.
///
/// No arbitrary MB ceiling: live OS process headroom governs all modes.
/// This is an advisory snapshot, not a memory reservation or a guarantee
/// against iOS Jetsam. Without the OS API, physicalRAM/3 is the fallback.
enum SafeExportResolution {
    // User-selected size ceilings, NOT guaranteed output dimensions.
    // Live memory and exact original per-pixel staging still take priority.
    static let safeMaximumPixels: UInt64 = 12_000_000
    static let economyMaximumPixels: UInt64 = 7_200_000
    static let estimatedBytesPerPixel: UInt64 = 104
    static let originalBudgetPercent: UInt64 = 70
    static let intelligentBudgetPercent: UInt64 = 90
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
        /// Live process headroom, with physicalRAM/3 fallback.
        let effectiveBudgetBytes: UInt64
        let processHeadroomBytes: UInt64?
        /// Maximum projected peak for this export, NOT pre-allocated memory.
        let allocationAllowanceBytes: UInt64
        let estimatedPeakBytes: UInt64
        let fullSourceProcessing: Bool

        var summary: String {
            let estimatedMB = estimatedPeakBytes / 1_000_000
            let budgetMB = effectiveBudgetBytes / 1_000_000
            let allowanceMB = allocationAllowanceBytes / 1_000_000
            let headroom = processHeadroomBytes.map {
                "\($0 / 1_000_000) MB"
            } ?? "未获取（按物理预算估算）"
            return """
            原始照片：\(sourceWidth) × \(sourceHeight)（约 \(Double(sourceWidth)*Double(sourceHeight)/1_000_000) 百万像素）
            已选档位：\(mode == .safe ? "智能安全（上限1200万）" : mode == .economy ? "省内存（上限720万）" : mode.title)
            预计输出：\(dimensions.width) × \(dimensions.height)（约 \(Double(dimensions.pixels)/1_000_000) 百万像素）
            预计显影峰值：约 \(estimatedMB) MB
            设备安全预算：约 \(budgetMB) MB；本档计划上限 \(allowanceMB) MB（估算上限，非预占内存）
            当前 App 可分配余量：\(headroom)
            \(fullSourceProcessing ? "RAW 光学冲印仍在原尺寸完成，导出缩图不节省冲印内存。" : "")
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
            SafeExportResolution.estimatedBytesPerPixel,
        fullSourceProcessing: Bool = false
    ) throws -> Plan {
        guard width > 0, height > 0, width <= 50_000,
              height <= 50_000, physicalMemory > 0,
              estimatedBytesPerPixel >= 1 && estimatedBytesPerPixel <= 1024
        else {
            throw Failure.invalid("输出分辨率：原图尺寸或设备内存数据无效")
        }
        let sourcePixels = UInt64(width) * UInt64(height)
        if case .megapixels(let count) = mode {
            guard ExportResolutionMode.presetWanPixels.contains(count) else {
                throw Failure.invalid("像素档位必须是 720/800/900/1000/1200 万")
            }
        }
        // No fixed MB budget. Headroom is updated for each export request.
        let budget = processAvailableMemory ?? physicalMemory / 3
        let percentage: UInt64
        switch mode {
        case .original: percentage = originalBudgetPercent
        case .safe: percentage = intelligentBudgetPercent
        case .economy: percentage = economyBudgetPercent
        case .megapixels: percentage = originalBudgetPercent
        }
        let allowance: UInt64
        switch mode {
        case .original:
            allowance = (budget / 100) * percentage
        case .safe:
            // Explicit 12MP geometry and 90% live headroom; no fixed MB cap.
            allowance = (budget / 100) * percentage
        case .economy, .megapixels:
            allowance = (budget / 100) * percentage
        }
        let targetPixels: UInt64
        switch mode {
        case .original:
            targetPixels = sourcePixels
        case .megapixels(let count):
            // Fixed cap: never auto-reduce further when memory is low.
            targetPixels = min(sourcePixels, UInt64(count) * 10_000)
        case .safe, .economy:
            guard budget > 0 && allowance >= estimatedBytesPerPixel else {
                throw Failure.invalid(
                    "安全输出：当前 App 可分配内存不足，已停止；不会自动降分辨率或切换算法"
                )
            }
            let byMemory = allowance / estimatedBytesPerPixel
            targetPixels = min(
                sourcePixels, byMemory,
                mode == .economy ? economyMaximumPixels : safeMaximumPixels
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
            // The full-source optical scratch peak and FINAL file packing
            // occur at DIFFERENT times. Before Build140 they were added,
            // double-charging buffers that the engine has already released.
            // Keep the larger stage's conservative bound, never the sum.
            // Original RAW is ALWAYS developed at sourcePixels; choosing a
            // smaller output only changes packaging memory, not source optics.
            estimatedPeakBytes: fullSourceProcessing
                ? max(
                    sourcePixels * estimatedBytesPerPixel,
                    sourcePixels * 24 + dimensions.pixels * 48
                  )
                : dimensions.pixels * estimatedBytesPerPixel,
            fullSourceProcessing: fullSourceProcessing
        )
    }

    /// Capture system headroom before the export UI confirms a concrete size.
    static func capture(
        width: Int, height: Int, mode: ExportResolutionMode,
        estimatedBytesPerPixel: UInt64 =
            SafeExportResolution.estimatedBytesPerPixel,
        fullSourceProcessing: Bool = false
    ) throws -> Plan {
        try plan(
            width:width, height:height,
            physicalMemory:ProcessInfo.processInfo.physicalMemory,
            processAvailableMemory:currentProcessHeadroom(),
            mode:mode,estimatedBytesPerPixel:estimatedBytesPerPixel,
            fullSourceProcessing:fullSourceProcessing
        )
    }

    /// Build97: ORIGINAL has the same physical/real-headroom admission
    /// as explicit reduced-resolution requests. This is not a RAM
    /// reservation and never changes selected dimensions or image algorithms.
    /// Pure helper permits deterministic small-memory tests.
    static func validateForHeadroom(
        _ plan: Plan, processAvailableMemory current: UInt64?
    ) throws {
        guard plan.estimatedPeakBytes <= plan.allocationAllowanceBytes else {
            throw Failure.invalid(
                "导出预检：已选 \(plan.dimensions.width)×\(plan.dimensions.height) " +
                "预计使用 \(plan.estimatedPeakBytes / 1_000_000) MB，" +
                "超过本档安全预算 \(plan.allocationAllowanceBytes / 1_000_000) MB。" +
                (plan.fullSourceProcessing ? "RAW 光学始终按原尺寸；可先裁切或释放内存，不会自动缩图。" :
                    "请明确选择较低分辨率，原图不会自动缩小。")
            )
        }
        if let current {
            let fraction: UInt64
            switch plan.mode {
            case .original: fraction = originalBudgetPercent
            case .safe: fraction = intelligentBudgetPercent
            case .economy: fraction = economyBudgetPercent
            case .megapixels: fraction = originalBudgetPercent
            }
            guard current > 0,
                  plan.estimatedPeakBytes <= (current / 100) * fraction else {
                throw Failure.invalid(
                    "导出预检：当前可分配内存仅 " +
                    "\(current / 1_000_000) MB，" +
                    "\(plan.dimensions.width)×\(plan.dimensions.height) " +
                    "预估峰值 \(plan.estimatedPeakBytes / 1_000_000) MB。" +
                    (plan.fullSourceProcessing ? "RAW 光学仍按原尺寸；请先裁切或释放内存，不会静默缩图。" :
                        "请明确选择安全或省内存分辨率，不会静默缩图。")
                )
            }
        }
    }

    /// Retry an admission check ONCE after actual optional cache eviction.
    /// No arithmetic credit, changed threshold, or changed confirmed size.
    static func retryAfterCacheEviction<T>(
        attempt:() throws -> T,isMemoryRefusal:(Error)->Bool,evict:()->Void
    ) throws -> T {
        do {return try attempt()}
        catch {
            guard isMemoryRefusal(error) else {throw error}
            evict()
            return try attempt()
        }
    }

    /// Repeat the live check when the confirmed render actually starts.
    static func validateBeforeRender(_ plan: Plan) throws {
        try validateForHeadroom(
            plan, processAvailableMemory: currentProcessHeadroom()
        )
    }

    /// Backwards-compatibility for old tests; .safe is adaptive and capped.
    static func target(
        width: Int, height: Int, physicalMemory: UInt64
    ) throws -> Dimensions {
        try plan(
            width:width,height:height,physicalMemory:physicalMemory,
            processAvailableMemory:nil,mode:.safe
        ).dimensions
    }
}
