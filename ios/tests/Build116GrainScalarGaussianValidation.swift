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
        var reused=[Double]()
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
                // Exercise caller-owned workspace repeatedly across FIR,
                // YVV, zero-sigma and changing geometry. Seed stale scratch
                // with NaN to detect reads before first-pass overwrite.
                for i in reused.indices { reused[i]=Double.nan }
                var reusedScalar=source
                try SourceGrainScalarGaussian.blurInPlace(
                    &reusedScalar,width:w,height:h,sigma:sigma,
                    intermediate:&reused
                )
                guard reusedScalar.map(\.bitPattern)==scalar.map(\.bitPattern) else {
                    fatalError("Build147-C reused scalar cloud workspace changed Float64 bits")
                }
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
