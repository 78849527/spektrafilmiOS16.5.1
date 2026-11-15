import Foundation

@main
enum Build88OriginalScanBWGlareValidation {
    enum Failure:Error {case invalid(String)}
    static func numbers(_ root:[String:Any],_ k:String) throws -> [Double] {
        guard let a=root[k] as? [NSNumber] else {
            throw Failure.invalid("Missing original source "+k)
        }
        return a.map{$0.doubleValue}
    }
    static func n(_ root:[String:Any],_ k:String) throws -> Double {
        guard let a=root[k] as? NSNumber else {
            throw Failure.invalid("Missing source scalar "+k)
        }
        return a.doubleValue
    }
    static func integer(_ root:[String:Any],_ k:String) throws -> Int {
        guard let a=root[k] as? NSNumber else {
            throw Failure.invalid("Missing original dimension "+k)
        }
        return a.intValue
    }
    static func match(
        _ values:[Double],_ source:[Double],_ label:String,
        limit:Double=3e-9
    ) throws -> Double {
        guard values.count==source.count else {
            throw Failure.invalid(label+" source frame dimensions mismatch")
        }
        var maximum=0.0
        for i in values.indices {
            let delta=abs(values[i]-source[i])
            guard delta.isFinite,delta<=limit else {
                throw Failure.invalid(
                    "\(label) #\(i) Python \(source[i]), " +
                    "native \(values[i]), Δ\(delta)"
                )
            }
            maximum=max(maximum,delta)
        }
        return maximum
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Missing original source XYZ stage fixtures")
        }
        let raw=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:raw)
                as? [String:Any],
              let cases=root["cases"] as? [[String:Any]],
              cases.count==64 else {
            throw Failure.invalid("Require 48 true-source reference→glare frames")
        }
        var worstRef=0.0,worstGlare=0.0,off=0,corrected=0,blurYVV=0
        for (index,item) in cases.enumerated() {
            guard let black=item["black"] as? Bool,
                  let white=item["white"] as? Bool else {
                throw Failure.invalid("Missing original source switches")
            }
            let w=try integer(item,"width")
            let h=try integer(item,"height")
            let sourceXYZ=try numbers(item,"xyz")
            let pyRef=try numbers(item,"afterBlackWhite")
            let pyGlare=try numbers(item,"afterGlare")
            let lamp=try numbers(item,"lamp")
            let seed=UInt32(try integer(item,"seed"))
            var refConfig=Build87OriginalColorReference.Settings()
            refConfig.blackCorrection=black
            refConfig.whiteCorrection=white
            refConfig.blackLevel=0.01
            refConfig.whiteLevel=0.98
            let prepared=try Build87OriginalColorReference.prepare(
                settings:refConfig,
                yBlack:try n(item,"yBlack"),
                yWhite:try n(item,"yWhite")
            )
            var actualRef=[Double]()
            actualRef.reserveCapacity(w*h*3)
            for p in 0..<(w*h) {
                let k=p*3
                actualRef += try prepared.correctXYZ(
                    Array(sourceXYZ[k..<k+3])
                )
            }
            worstRef=max(worstRef,try match(
                actualRef,pyRef,"source BW Y XYZ #\(index)"
            ))
            let glare=OriginalSourceScannerGlare.Settings(
                active:true,percent:try n(item,"percent"),
                roughness:try n(item,"roughness"),
                blur:try n(item,"blur")
            )
            if glare.percent==0 {off+=1}
            if glare.percent>100 && glare.roughness==0 {
                guard !glare.consumesNumbaRandomness else {
                    throw Failure.invalid(
                        "Original sigma zero glare incorrectly requests random normals"
                    )
                }
                let noSeed=try OriginalSourceScannerGlare.addToXYZ(
                    actualRef,illuminantXYZ:lamp,width:w,height:h,
                    settings:glare,controlledSeed:nil
                )
                _=try match(noSeed,pyGlare,
                    "source scanner deterministic high glare without RNG #(index)"
                )
            }
            if black || white {corrected+=1}
            if glare.blur>=3 {blurYVV+=1}
            let actualXYZ=try OriginalSourceScannerGlare.addToXYZ(
                actualRef,illuminantXYZ:lamp,
                width:w,height:h,settings:glare,controlledSeed:seed
            )
            worstGlare=max(worstGlare,try match(
                actualXYZ,pyGlare,
                "source ColorReferenceService→Numba glare XYZ #\(index)"
            ))
            if !black && !white {
                guard actualRef==sourceXYZ else {
                    throw Failure.invalid(
                        "Source BW-off changed original measured spectral XYZ"
                    )
                }
            }
            if glare.percent==0 {
                guard actualXYZ==actualRef else {
                    throw Failure.invalid(
                        "Source glare-off modified corrected spectral XYZ"
                    )
                }
            }
        }
        guard off==16,corrected==48,blurYVV==32 else {
            throw Failure.invalid("Original scanner BW/glare mode coverage drift")
        }
        print("PASS BUILD88 TRUE ORIGINAL 64 COMBINED SCANNER XYZ: " +
              "ColorReferenceService.black_white_xyz_correction then " +
              "original single-worker Numba glare.add_glare. " +
              "BW max=\(worstRef), glare XYZ max=\(worstGlare), " +
              "precision=3e-9. UNSEEDED prange is NOT certified.")
    }
}
