import Foundation

/// Keep the historical scalar FIR/YVV test independent of generated RNG
/// fixtures. This executable runs AFTER the pinned NumPy/Numba generators.
@main
struct OPTScannerGlareValidation {
    static func main() throws {
        let geometries=[(1,1),(1,13),(17,1),(3,5),(19,23),(101,37)]
        let sigmas:[Double]=[0,0.08,0.4,0.65,1.0,2.99,3.0,3.5,5.5,12.0]
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


        // Also independently compare the new production implementation
        // with the original Python source, not merely its old Swift route.
        let fixtures=GeneratedSourceScannerGlareReference.cases
        precondition(fixtures.count==6)
        precondition(GeneratedSourceScannerGlareReference.glareBlob=="e8610f13430d45be749ae31a5284eef2c2b7a362")
        precondition(GeneratedSourceScannerGlareReference.statsBlob=="9e80d29ce6b9f7820ae70f5c09da15edfaa70a0d")
        precondition(GeneratedSourceScannerGlareReference.filterBlob=="8918c673ea0fb3f5d9ae820ca85bf6db4aba457a")
        var maxAmount=0.0,maxXYZ=0.0
        for f in fixtures {
            let settings=OriginalSourceScannerGlare.Settings(
                active:f.enabled,percent:f.percent,roughness:f.roughness,blur:f.blur
            )
            let amount=try OriginalSourceScannerGlare.computeAmount(
                width:f.width,height:f.height,settings:settings,controlledSeed:f.seed
            )
            let xyz=try OriginalSourceScannerGlare.addToXYZ(
                f.inputXYZ,illuminantXYZ:f.illuminantXYZ,width:f.width,height:f.height,
                settings:settings,controlledSeed:f.seed
            )
            precondition(amount.count==f.amounts.count && xyz.count==f.outputXYZ.count)
            for i in amount.indices {
                let error=abs(amount[i]-f.amounts[i])
                precondition(error<=1e-11*(1+abs(f.amounts[i])))
                maxAmount=max(maxAmount,error)
            }
            for i in xyz.indices {
                let error=abs(xyz[i]-f.outputXYZ[i])
                precondition(error<=1e-11*(1+abs(f.outputXYZ[i])))
                maxXYZ=max(maxXYZ,error)
            }
        }
        print("PASS OPT scalar glare independent Python \(fixtures.count) cases, maxAmount=\(maxAmount), maxXYZ=\(maxXYZ)")
    }
}
