import Foundation

/// Pure Swift checks run without Metal, on the CI host and on iOS16.
/// Both user-visible export choices must preserve dimensions exactly
/// when original is selected; safe target must preserve aspect and RAM.
@main
struct SafeExportResolutionValidation {
    static func main() throws {
        let testCases: [(Int,Int,UInt64)] = [
            (4032,3024,4_000_000_000),  // iPhone A15 portrait photo
            (3024,4032,4_000_000_000),
            (6000,4000,6_000_000_000),
            (8000,6000,4_000_000_000),
            (7000,4667,3_000_000_000),
            (3000,2000,2_000_000_000),
            (640,480,4_000_000_000),
            (1,1,4_000_000_000),
        ]
        precondition(ExportResolutionMode.original != .safe)
        for (w,h,ram) in testCases {
            let result = try SafeExportResolution.target(
                width:w,height:h,physicalMemory:ram
            )
            let total = UInt64(w)*UInt64(h)
            let budget = min(UInt64(1_500_000_000), ram/3)
            let safeBudget = (budget / 10 * 3) /
                SafeExportResolution.estimatedBytesPerPixel
            precondition(result.width > 0 && result.height > 0)
            precondition(result.width <= w && result.height <= h)
            precondition(result.pixels <= SafeExportResolution.maximumPixels)
            precondition(result.pixels <= safeBudget)
            precondition(result.pixels <= total)
            precondition(result.reduced == (result.pixels < total))
            if !result.reduced {
                precondition(result.width == w && result.height == h)
            } else {
                let exact = Double(w)/Double(h)
                let output = Double(result.width)/Double(result.height)
                // A one-pixel floor in each dimension must not distort
                // the original aspect ratio meaningfully.
                let tolerance = max(0.005,
                    2.0 / Double(min(result.width,result.height)))
                precondition(abs(output-exact)/exact < tolerance)
            }
        }
        for (w,h,ram) in [(0,100,UInt64(4_000_000_000)),
                           (100,0,UInt64(4_000_000_000)),
                           (100,100,UInt64(0))] {
            do {
                _ = try SafeExportResolution.target(
                    width:w,height:h,physicalMemory:ram
                )
                fatalError("Must reject invalid safe-output inputs")
            } catch SafeExportResolution.Failure.invalid {
                // Expected no approximation and no 0x0 image.
            }
        }
        print("PASS: RAM-safe <=3MP image sizes, source aspect, small-photo no upscale, invalid-input rejection")
    }
}
