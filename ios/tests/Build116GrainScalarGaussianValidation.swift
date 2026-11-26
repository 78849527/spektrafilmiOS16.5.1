import Foundation

/// Build116: numerical gate for one-plane dye-cloud filtering.
/// The baseline is the existing THREE-channel source-exact Float64
/// SourceSpatialDIRConvolution.diffuseMemoryBounded, with channels 1/2 zero.
@main
struct Build116GrainScalarGaussianValidation {
    static func main() throws {
        let geometries=[(1,1),(1,13),(17,1),(3,5),(19,23),(101,37)]
        let sigmas:[Double]=[0,0.08,0.4,0.65,1.0,2.99,3.0,3.5,5.5,12.0]
        var cases=0
        for (w,h) in geometries {
            let n=w*h
            let source=(0..<n).map { p in
                let signed=Double((p*71+13)%127)-62.0
                return signed/49.0 + Double((p*5+1)%11)/1000.0
            }
            for sigma in sigmas {
                var scalar=source
                try SourceGrainScalarGaussian.blurInPlace(
                    &scalar,width:w,height:h,sigma:sigma
                )
                var oldRGB=[Double](repeating:0,count:n*3)
                for p in 0..<n { oldRGB[p*3]=source[p] }
                let reference=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                    oldRGB,width:w,height:h,
                    coreSigma:sigma,tailSigma:0,tailWeight:0
                )
                for p in 0..<n {
                    guard scalar[p].bitPattern==reference[p*3].bitPattern else {
                        fatalError(
                            "Build116 numerical parity FAIL w=\(w) h=\(h) sigma=\(sigma) p=\(p) new=\(scalar[p]) old=\(reference[p*3])"
                        )
                    }
                }
                cases+=1
            }
        }

        // Exercise actual optimized glare with injected normals and a
        // separately repeated seeded stream, including deterministic branch.
        var glareCases=0
        for (w,h) in geometries {
            let n=w*h
            for blur in sigmas {
                for roughness in [0.0,0.7] {
                    let settings=OriginalSourceScannerGlare.Settings(
                        active:true,percent:0.11,roughness:roughness,blur:blur
                    )
                    var rng=OriginalSourceNumbaSingleThreadNormal(seed:8888)
                    let normals=try (0..<n).map { _ in try rng.nextNormal() }
                    let mean=settings.percent,std=roughness*mean
                    let sigma2=log(1.0+(std*std)/(mean*mean))
                    let sigma=sqrt(sigma2),mu=log(mean)-sigma2/2.0
                    var rgb=[Double](repeating:0,count:n*3)
                    for i in 0..<n {
                        let value=sigma<1e-6 ? exp(mu) : exp(mu+sigma*normals[i])
                        for c in 0..<3 {rgb[i*3+c]=value}
                    }
                    let reference=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                        rgb,width:w,height:h,coreSigma:blur,tailSigma:0,tailWeight:0
                    )
                    let injected=try OriginalSourceScannerGlare.computeAmount(
                        width:w,height:h,settings:settings,sourceNormals:normals
                    )
                    let seeded=try OriginalSourceScannerGlare.computeAmount(
                        width:w,height:h,settings:settings,controlledSeed:8888
                    )
                    for i in 0..<n {
                        let expected=reference[i*3]/100.0
                        precondition(injected[i].bitPattern==expected.bitPattern &&
                                     seeded[i].bitPattern==expected.bitPattern,
                                     "Scalar glare differs from old RGB path")
                    }
                    glareCases+=1
                }
            }
        }
        print("PASS OPT-08 scanner glare scalar old-RGB bitwise parity \(glareCases)/\(glareCases); seeded and deterministic")

        // Filter alone: original cloud RGB + RGB result + 2 scratch planes
        // (24+24+8+8=64 B/px) vs scalar cloud + 1 scratch (8+8=16 B/px).
        // Difference is allocation plan, NOT total process RSS/Jetsam.
        let pixels:UInt64=13_000_000
        let originalScratchBytesPerPixel:UInt64=64
        let scalarScratchBytesPerPixel:UInt64=16
        let savedPerPixel=originalScratchBytesPerPixel-scalarScratchBytesPerPixel
        guard savedPerPixel == 48,
              savedPerPixel * pixels == 624_000_000 else {
            fatalError("Build116 scratch accounting changed")
        }

        var invalid=[Double](repeating:0,count:3)
        do {
            try SourceGrainScalarGaussian.blurInPlace(
                &invalid,width:2,height:2,sigma:1
            )
            fatalError("Build116 rejected-size guard missing")
        } catch SourceGrainScalarGaussian.Failure.invalid {
            // Required fail closed: no automatic downscale.
        }
        print("PASS Build116 original scalar full-frame FIR/YVV bit-exact \(cases)/\(cases) against prior RGB source; 48 B/px local peak scratch reduction; no 13MP certification")
    }
}
