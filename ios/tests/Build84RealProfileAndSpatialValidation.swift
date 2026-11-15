import Foundation

/// Real measured 256-node original film data and Python source FIR/YVV
/// boundary oracle. This test compiles the unchanged production numerical
/// core extracted before its Core Image bridge, never a mock filter.
@main
enum Build84RealProfileAndSpatialValidation {
    enum Failure: Error { case mismatch(String) }
    static func vector(_ data:[String:Any], _ name:String) throws -> [Double] {
        guard let array=data[name] as? [NSNumber] else {
            throw Failure.mismatch("source fixture missing " + name)
        }
        return array.map { $0.doubleValue }
    }

    static func number(_ data:[String:Any], _ name:String) throws -> Int {
        guard let n=data[name] as? NSNumber else {
            throw Failure.mismatch("source fixture missing integer " + name)
        }
        return n.intValue
    }

    static func compare(
        _ label:String, _ swift:[Double],_ source:[Double],
        limit:Double=2e-11
    ) throws -> Double {
        guard swift.count==source.count else {
            throw Failure.mismatch("\(label): output length mismatch")
        }
        var maxError=0.0, meanError=0.0
        for k in swift.indices {
            let delta=abs(swift[k]-source[k])
            guard delta.isFinite,delta<=limit else {
                throw Failure.mismatch(
                    "\(label) mismatch at #\(k): \(swift[k]) vs \(source[k]) " +
                    "(delta=\(delta), limit=\(limit))"
                )
            }
            maxError=max(maxError,delta)
            meanError+=delta
        }
        print("PASS \(label) n=\(swift.count) " +
              "mae=\(meanError/Double(max(1,swift.count))) max=\(maxError)")
        return maxError
    }

    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.mismatch("Need original real-stock + filter oracle JSON")
        }
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let profiles=root["stocks"] as? [[String:Any]],
              let spatial=root["spatial"] as? [[String:Any]],
              profiles.count==20,spatial.count==40 else {
            throw Failure.mismatch("Expected all 20 real stocks and 40 spatial fixtures")
        }
        var profileWorst=0.0
        for (index,stock) in profiles.enumerated() {
            guard let name=stock["stock"] as? String,
                  let positive=stock["positive"] as? Bool else {
                throw Failure.mismatch("Invalid stock identity #\(index)")
            }
            let x=try vector(stock,"logAxis")
            let curves=try vector(stock,"curves")
            let matrix=try vector(stock,"matrix")
            let before=try vector(stock,"beforeDIR")
            let raw=try vector(stock,"raw")
            let gamma=try vector(stock,"gamma")
            guard x.count==256,curves.count==768,before.count==768,
                  matrix.count==9,raw.count%3==0 else {
                throw Failure.mismatch("Invalid 256×3 source stock " + name)
            }
            let actualMatrix=try Build84OriginalFilmDIR.stockMatrix(
                stock:name,positive:positive
            )
            profileWorst=max(profileWorst,try compare(
                name+" original stock matrix",actualMatrix,matrix,limit:2e-12
            ))
            profileWorst=max(profileWorst,try compare(
                name+" corrected 256×3 H-D",
                Build84OriginalFilmDIR.curvesBeforeDIR(
                    logExposure:x,densityCurves:curves,
                    matrix:actualMatrix,positive:positive
                ), before,limit:2e-11
            ))
            profileWorst=max(profileWorst,try compare(
                name+" measured H-D gamma & endpoints",
                Build84OriginalFilmDIR.developDensity(
                    logRaw:raw,logExposure:x,
                    densityCurves:curves,gammaRGB:gamma
                ),
                try vector(stock,"hd"),limit:2e-11
            ))
        }
        var spatialWorst=0.0
        for (index,sample) in spatial.enumerated() {
            let width=try number(sample,"width")
            let height=try number(sample,"height")
            guard let kind=sample["kind"] as? String else {
                throw Failure.mismatch("Missing spatial source kind")
            }
            let input=try vector(sample,"input")
            let scale=try vector(sample,"scale")
            let expected=try vector(sample,"output")
            guard input.count==width*height*3,scale.count==3 else {
                throw Failure.mismatch("Bad spatial source sample \(index)")
            }
            let actual:[Double]
            switch kind {
            case "gaussian":
                actual=try SourceSpatialDIRConvolution.gaussianPerChannelMemoryBounded(
                    input,width:width,height:height,sigmas:scale
                )
            case "exponential":
                actual=try SourceSpatialDIRConvolution.exponentialFitted(
                    input,width:width,height:height,decay:scale,
                    nGaussians:try number(sample,"fit")
                )
            default:
                throw Failure.mismatch("Unexpected Python spatial kind " + kind)
            }
            spatialWorst=max(spatialWorst,try compare(
                "source \(kind) \(width)x\(height) \(scale) #\(index)",
                actual,expected,
                limit:3e-9
            ))
        }
        print("BUILD84 BATCH2 ORIGINAL SOURCE PASS: " +
              "\(profiles.count) real stock profiles, " +
              "\(profiles.count*256*3) corrected H-D nodes, " +
              "\(spatial.count) FIR/YVV/2-3 Gaussian fixture frames. " +
              "maxHD=\(profileWorst) maxSpatial=\(spatialWorst)")
    }
}
