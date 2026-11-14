import Foundation

/// The production OriginalSourceDiffusion.psf/apply must be exercised by
/// macOS swiftc against the exact pinned upstream Python filter for all
/// four original families. Test-only values are deterministic Double RGB.
@main
struct SourceDiffusionNumericValidation {
    static func main() throws {
        let settings: [OriginalSourceDiffusion.Settings] = [
            .init(active:true,family:.glimmerglass,strength:0.125,
                  spatialScale:1,haloWarmth:0,coreIntensity:1,
                  coreSize:1,haloIntensity:1,haloSize:1,
                  bloomIntensity:1,bloomSize:1),
            .init(active:true,family:.blackProMist,strength:0.5,
                  spatialScale:1.15,haloWarmth:0.3,coreIntensity:1.15,
                  coreSize:1.2,haloIntensity:0.8,haloSize:0.9,
                  bloomIntensity:1.3,bloomSize:1.05),
            .init(active:true,family:.proMist,strength:1.0,
                  spatialScale:0.85,haloWarmth:-0.4,coreIntensity:1,
                  coreSize:1,haloIntensity:1,haloSize:1,
                  bloomIntensity:1,bloomSize:1),
            .init(active:true,family:.cinebloom,strength:2,
                  spatialScale:1,haloWarmth:0,coreIntensity:1,
                  coreSize:1,haloIntensity:1,haloSize:1,
                  bloomIntensity:1,bloomSize:1),
        ]
        let dimensions=[(11,9),(16,13),(29,21),(24,19)]
        for caseIndex in settings.indices {
            let (w,h)=dimensions[caseIndex]
            let input=(0..<(w*h*3)).map { k -> Double in
                Double((k*37+11)%251)/251.0 +
                    0.001*Double((k/7)%3)
            }
            let cfg=settings[caseIndex]
            let kernel=try OriginalSourceDiffusion.psf(
                width:w,height:h,pixelUM:100,settings:cfg
            )
            for c in 0..<3 {
                let sum=(0..<(kernel.data.count/3)).reduce(0.0) {
                    $0+kernel.data[$1*3+c]
                }
                guard abs(sum-1)<1e-12 else {
                    fatalError("Source PSF channel norm \(sum)")
                }
            }
            let output=try OriginalSourceDiffusion.apply(
                input,width:w,height:h,pixelUM:100,settings:cfg
            )
            print("METADATA,\(caseIndex),\(w),\(h),\(kernel.radius)")
            for (k,v) in output.enumerated() {
                print("RESULT,\(caseIndex),\(k),\(String(format:"%.17g",v))")
                // The source PrintingStage applies the *same* 2D PSF
                // to pre-paper-H-D light irradiance and only then
                // takes log10(max(raw,0)+1e-10). These cases exercise
                // native production diffusion and original print order.
                let printLog = log10(max(v, 0.0) + 1e-10)
                print("PRINT,\(caseIndex),\(k),\(String(format:"%.17g",printLog))")
            }
        }
    }
}
