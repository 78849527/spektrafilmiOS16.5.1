import Foundation

/// The production OriginalSourceDiffusion.psf/apply must be exercised by
/// macOS swiftc against the exact pinned upstream Python filter for all
/// four original families. Test-only values are deterministic Double RGB.
@main
struct SourceDiffusionNumericValidation {
    static func main() throws {
        OriginalSourceDiffusion.verifyExactButterfly()
        OriginalSourceDiffusion.verifyPreparedButterfly()
        FileHandle.standardError.write(Data(
            "PASS Build155 prepared Double FFT butterfly 20 bitwise cases\n".utf8))
        // stdout is a strict METADATA/RESULT/PRINT CSV transport.
        // Send the independent bitwise test evidence to stderr instead.
        FileHandle.standardError.write(Data(
            "PASS Build151 exact borrowed Double FFT butterfly, 20 forward/inverse geometry cases\n".utf8
        ))
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
        var compactCases=0
        for cfg in settings {
            for (w,h) in [(1,1),(1,9),(9,1),(2,3),(11,9),(16,13),(29,21),(64,33)] {
                for pixelUM in [100.0,17.0] {
                    let input=(0..<(w*h*3)).map { k -> Double in
                        if k%11==0 {return -0.0}
                        if k%13==0 {return 0.0}
                        return Double((k*37+11)%251)/127.0-0.4
                    }
                    let legacy=try OriginalSourceDiffusion.apply(
                        input,width:w,height:h,pixelUM:pixelUM,settings:cfg,
                        usePreparedPSFCache:false)
                    var compact=input
                    try OriginalSourceDiffusion.applyCompactInPlace(
                        &compact,width:w,height:h,pixelUM:pixelUM,settings:cfg,
                        usePreparedPSFCache:false,usePreparedFFT:false)
                    precondition(compact.map{$0.bitPattern}==legacy.map{$0.bitPattern},
                                 "Build154 compact full-grid FFT differs")
                    var prepared=input
                    try OriginalSourceDiffusion.applyCompactInPlace(
                        &prepared,width:w,height:h,pixelUM:pixelUM,settings:cfg,
                        usePreparedPSFCache:false)
                    precondition(prepared.map{$0.bitPattern}==legacy.map{$0.bitPattern},
                                 "Build155 prepared blocked full-grid FFT differs")
                    precondition(input.count==compact.count)
                    compactCases+=1
                }
            }
        }
        precondition(compactCases==64)
        FileHandle.standardError.write(Data(
            "PASS Build154 compact full-grid FFT 64 bitwise cases\n".utf8))
        FileHandle.standardError.write(Data(
            "PASS Build155 prepared blocked full-grid FFT 64 bitwise cases\n".utf8))
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
            var output=input
            try OriginalSourceDiffusion.applyCompactInPlace(
                &output,width:w,height:h,pixelUM:100,settings:cfg,
                usePreparedPSFCache:false)
            OriginalSourceDiffusion.clearPreparedPSFCache()
            let first=try OriginalSourceDiffusion.preparedPSF(
                width:w,height:h,pixelUM:100,settings:cfg
            )
            let reused=try OriginalSourceDiffusion.preparedPSF(
                width:w,height:h,pixelUM:100,settings:cfg
            )
            precondition(first.radius==kernel.radius && reused.radius==kernel.radius)
            precondition(first.data.map { $0.bitPattern }==kernel.data.map { $0.bitPattern })
            precondition(reused.data.map { $0.bitPattern }==kernel.data.map { $0.bitPattern })
            let warm=try OriginalSourceDiffusion.apply(
                input,width:w,height:h,pixelUM:100,settings:cfg
            )
            precondition(warm.map { $0.bitPattern }==output.map { $0.bitPattern },
                         "OPT-07 cached PSF changes optical output")
            var changed=cfg
            changed.haloWarmth += 0.125
            let changedExpected=try OriginalSourceDiffusion.psf(
                width:w,height:h,pixelUM:100,settings:changed
            )
            let changedActual=try OriginalSourceDiffusion.preparedPSF(
                width:w,height:h,pixelUM:100,settings:changed
            )
            precondition(changedActual.data.map { $0.bitPattern }==changedExpected.data.map { $0.bitPattern })
            let geometryExpected=try OriginalSourceDiffusion.psf(
                width:w+2,height:h,pixelUM:83,settings:changed
            )
            let geometryActual=try OriginalSourceDiffusion.preparedPSF(
                width:w+2,height:h,pixelUM:83,settings:changed
            )
            precondition(geometryActual.radius==geometryExpected.radius)
            precondition(geometryActual.data.map { $0.bitPattern }==geometryExpected.data.map { $0.bitPattern })
            #if canImport(Accelerate)
            let candidate=try OriginalSourceDiffusion.apply(
                input,width:w,height:h,pixelUM:100,settings:cfg,
                fftBackend:.accelerateCandidate
            )
            precondition(candidate.count==output.count)
            for k in output.indices {
                precondition(abs(candidate[k]-output[k]) <= 1e-10*max(1,abs(output[k])),
                    "OPT-06 candidate differs from reference at pixel \(k)")
            }
            #endif
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
