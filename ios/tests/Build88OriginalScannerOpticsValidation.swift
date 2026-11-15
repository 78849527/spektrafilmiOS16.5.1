import Foundation

@main
enum Build88OriginalScannerOpticsValidation {
    enum Failure:Error { case invalid(String) }
    static func array(_ obj:[String:Any],_ name:String) throws -> [Double] {
        guard let nums=obj[name] as? [NSNumber] else {
            throw Failure.invalid("Missing original NumPy source "+name)
        }
        return nums.map{$0.doubleValue}
    }
    static func optional(_ obj:[String:Any],_ name:String) -> [Double]? {
        (obj[name] as? [NSNumber])?.map{$0.doubleValue}
    }
    static func scalar(_ obj:[String:Any],_ name:String) throws -> Double {
        guard let val=obj[name] as? NSNumber else {
            throw Failure.invalid("Missing Python scalar "+name)
        }
        return val.doubleValue
    }
    static func integer(_ obj:[String:Any],_ name:String) throws -> Int {
        guard let val=obj[name] as? NSNumber else {
            throw Failure.invalid("Missing Python image dimension "+name)
        }
        return val.intValue
    }
    static func compare(
        _ actual:[Double],_ python:[Double],_ label:String,
        limit:Double=2e-8
    ) throws -> Double {
        guard actual.count==python.count else {
            throw Failure.invalid(label+" shape mismatch")
        }
        var maximum=0.0
        for ix in actual.indices {
            let delta=abs(actual[ix]-python[ix])
            guard delta.isFinite && delta<=limit else {
                throw Failure.invalid(
                    "\(label) pixel \(ix): native \(actual[ix]), " +
                    "Python \(python[ix]), diff \(delta)"
                )
            }
            maximum=max(maximum,delta)
        }
        return maximum
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Missing 60 original scanner Python fixtures")
        }
        let raw=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:raw)
                as? [String:Any],
              let cases=root["cases"] as? [[String:Any]],
              cases.count==60 else {
            throw Failure.invalid("Need all original 60 lens/unsharp cases")
        }
        var worst=0.0,blur=0,unsharp=0,wide=0,skipped=0
        for (index,caseData) in cases.enumerated() {
            var settings=OriginalSourceScannerOptics.Settings()
            settings.lensBlurSigma=try scalar(caseData,"lens")
            settings.unsharpSigma=try scalar(caseData,"sigma")
            settings.unsharpAmount=try scalar(caseData,"amount")
            let w=try integer(caseData,"width")
            let h=try integer(caseData,"height")
            if w<3 || h<3 {wide+=1}
            if settings.lensBlurSigma>50 ||
               settings.unsharpAmount>2 {blur+=1}
            if !settings.active {skipped+=1}
            var frame=try array(caseData,"input")
            var stages=[String:[Double]]()
            try OriginalSourceScannerOptics.applyInPlace(
                &frame,width:w,height:h,settings:settings,
                stageDoubleObserver:{name,data in stages[name]=data}
            )
            let final=try array(caseData,"final")
            worst=max(worst,try compare(
                frame,final,"original scanner output #\(index)"
            ))
            if let sourceLens=optional(caseData,"lensStage") {
                guard let observed=stages["scannerLensBlur"] else {
                    throw Failure.invalid(
                        "Native omitted source lens FIR/YVV tap #\(index)"
                    )
                }
                worst=max(worst,try compare(
                    observed,sourceLens,"original scanner lens tap #\(index)"
                ))
            }
            if let sourceUnsharp=optional(caseData,"unsharpBlur") {
                guard let observed=stages["scannerUnsharpBlur"] else {
                    throw Failure.invalid(
                        "Native omitted original unsharp tap #\(index)"
                    )
                }
                unsharp+=1
                worst=max(worst,try compare(
                    observed,sourceUnsharp,
                    "original scanner unsharp Gaussian tap #\(index)"
                ))
            }
            if !settings.active && !stages.isEmpty {
                throw Failure.invalid(
                    "Source disabled scanner optics generated new tap"
                )
            }
        }
        guard wide>0,blur>0,unsharp>0,skipped>0 else {
            throw Failure.invalid("Source scanner edge branch coverage missing")
        }
        print("BUILD88 ORIGINAL SCANNER OPTICS PASS: 60 full RGB " +
              "original Python FIR/YVV lens/unsharp images, " +
              "maximum Float64 Δ=\(worst), tolerance 2e-8; " +
              "narrow cases=\(wide), high-parameter=\(blur), " +
              "unsharp stages=\(unsharp), bypasses=\(skipped).")
    }
}
