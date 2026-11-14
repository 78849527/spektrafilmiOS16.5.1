import Foundation

/// Pure Swift geometry and live-memory plan regression (CI and iOS 16).
/// This test does not claim process memory headroom is a reservation.
@main
struct SafeExportResolutionValidation {
    static func main() throws {
        let photoCases: [(Int,Int,UInt64)] = [
            (4032,3024,4_000_000_000), (3024,4032,4_000_000_000),
            (6000,4000,6_000_000_000), (8000,6000,4_000_000_000),
            (7000,4667,3_000_000_000), (3000,2000,2_000_000_000),
            (640,480,4_000_000_000), (1,1,4_000_000_000),
        ]
        for (w,h,ram) in photoCases {
            for mode in [ExportResolutionMode.original,.safe,.economy] {
                let plan = try SafeExportResolution.plan(
                    width:w,height:h,physicalMemory:ram,
                    processAvailableMemory:1_500_000_000,mode:mode
                )
                let d = plan.dimensions
                precondition(d.width > 0 && d.height > 0)
                precondition(d.width <= w && d.height <= h)
                precondition(d.reduced == (d.pixels < UInt64(w)*UInt64(h)))
                precondition(plan.sourceWidth == w && plan.sourceHeight == h)
                precondition(!plan.summary.isEmpty)
                if mode == .original {
                    precondition(d.width == w && d.height == h)
                    precondition(!d.reduced)
                } else {
                    let percentage:UInt64 = mode == .safe ? 50 : 30
                    let physicalBudget = min(UInt64(1_500_000_000),ram/3)
                    let effective = min(physicalBudget,1_500_000_000)
                    let limit = (effective/100*percentage) /
                        SafeExportResolution.estimatedBytesPerPixel
                    precondition(d.pixels <= limit)
                    precondition(plan.estimatedPeakBytes <= plan.allocationAllowanceBytes)
                    if mode == .safe {
                        precondition(d.pixels <=
                            SafeExportResolution.safeMaximumPixels)
                    }
                    if mode == .economy {
                        precondition(d.pixels <=
                            SafeExportResolution.economyMaximumPixels)
                    }
                }
                if d.reduced && min(d.width,d.height)>2 {
                    let ratio=Double(w)/Double(h)
                    let outputRatio=Double(d.width)/Double(d.height)
                    let tolerance=max(0.005,2.0/Double(min(d.width,d.height)))
                    precondition(abs(outputRatio-ratio)/ratio < tolerance)
                }
            }
        }
        // Even with an actual 1.5GB upper budget, output can be BELOW
        // the user-selected 12MP/7.2MP ceilings because the safety
        // percentages and source-pipeline memory estimates take priority.
        let adaptive = try SafeExportResolution.plan(
            width:6000,height:4000,physicalMemory:6_000_000_000,
            processAvailableMemory:1_500_000_000,mode:.safe
        )
        let economy = try SafeExportResolution.plan(
            width:6000,height:4000,physicalMemory:6_000_000_000,
            processAvailableMemory:1_500_000_000,mode:.economy
        )
        precondition(adaptive.dimensions.pixels >= 7_000_000)
        precondition(adaptive.dimensions.pixels <= 7_211_539)
        precondition(economy.dimensions.pixels <= 7_200_000)
        precondition(economy.dimensions.pixels > 3_000_000)
        precondition(adaptive.dimensions.pixels > economy.dimensions.pixels)

        // A high-efficiency pipeline with identical safe/economy
        // percentages MUST obey the new 12MP and 7.2MP ceilings.
        // This is a controlled budget test, not a declaration that
        // 12MP source Float64+grain fits in an A15 memory budget.
        let largeSource=(width:6000,height:4000)
        for (mode,limit) in [
            (ExportResolutionMode.safe,UInt64(12_000_000)),
            (.economy,UInt64(7_200_000))
        ] {
            let plan=try SafeExportResolution.plan(
                width:largeSource.width,height:largeSource.height,
                physicalMemory:6_000_000_000,
                processAvailableMemory:1_500_000_000,
                mode:mode,estimatedBytesPerPixel:32
            )
            precondition(plan.dimensions.pixels<=limit)
            precondition(plan.dimensions.pixels>=limit-10_000)
            precondition(plan.summary.contains(
                mode == .safe ? "上限1200万" : "上限720万"
            ))
        }
        // Source geometry remains unchanged when the image is SMALLER
        // than the selected output cap and available budget.
        for mode in [ExportResolutionMode.safe,.economy] {
            let small=try SafeExportResolution.plan(
                width:1200,height:900,physicalMemory:6_000_000_000,
                processAvailableMemory:1_500_000_000,
                mode:mode,estimatedBytesPerPixel:32
            )
            precondition(small.dimensions.width==1200 &&
                         small.dimensions.height==900)
        }

        // New true source physics no longer uses general CoreImage's 104
        // bytes/pixel budget; the 120B/px Double full-image pipeline is
        // stated in the pre-export user confirmation as an ESTIMATE.
        let originalPlan=try SafeExportResolution.plan(
            width:3888,height:2592,physicalMemory:4_500_000_000,
            processAvailableMemory:3_140_000_000,mode:.original
        )
        let physicsPlan=try SafeExportResolution.plan(
            width:3888,height:2592,physicalMemory:4_500_000_000,
            processAvailableMemory:3_140_000_000,mode:.original,
            estimatedBytesPerPixel:120
        )
        precondition(originalPlan.estimatedPeakBytes ==
                     UInt64(3888*2592)*104)
        precondition(physicsPlan.estimatedPeakBytes ==
                     UInt64(3888*2592)*120)
        precondition(physicsPlan.dimensions.width==3888 &&
                     physicsPlan.dimensions.height==2592)
        precondition(!physicsPlan.dimensions.reduced &&
                     physicsPlan.summary.contains("1209 MB"))

        // Process headroom can reduce the cap BELOW the physical budget.
        let pressured = try SafeExportResolution.plan(
            width:6000,height:4000,physicalMemory:6_000_000_000,
            processAvailableMemory:420_000_000,mode:.safe
        )
        precondition(pressured.effectiveBudgetBytes == 420_000_000)
        precondition(pressured.dimensions.pixels < adaptive.dimensions.pixels)
        let tiny = try SafeExportResolution.plan(
            width:640,height:480,physicalMemory:4_000_000_000,
            processAvailableMemory:1_000_000_000,mode:.economy
        )
        precondition(tiny.dimensions.width==640 && tiny.dimensions.height==480)
        // When current process allocation headroom reaches zero, neither
        // safe mode may silently fall back to another algorithm/resolution.
        for mode in [ExportResolutionMode.safe,.economy] {
            do {
                _ = try SafeExportResolution.plan(
                    width:4000,height:3000,physicalMemory:4_000_000_000,
                    processAvailableMemory:0,mode:mode
                )
                fatalError("Must reject zero process-memory allowance")
            } catch SafeExportResolution.Failure.invalid {}
        }
        for (w,h,ram) in [(0,100,UInt64(4_000_000_000)),
                           (100,0,UInt64(4_000_000_000)),
                           (100,100,UInt64(0))] {
            do {
                _ = try SafeExportResolution.plan(
                    width:w,height:h,physicalMemory:ram,
                    processAvailableMemory:nil,mode:.safe
                )
                fatalError("Must reject invalid export inputs")
            } catch SafeExportResolution.Failure.invalid {}
        }
        print("PASS Build76: source original unchanged, adaptive safe<=12MP, economy<=7.2MP, memory headroom and original aspect ratio protected")
    }
}
