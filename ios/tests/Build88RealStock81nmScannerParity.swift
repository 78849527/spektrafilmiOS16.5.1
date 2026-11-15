import Foundation

@main
enum Build88RealStock81nmScannerParity {
    enum Failure:Error {case invalid(String)}
    static func vector(_ o:[String:Any],_ key:String) throws -> [Double] {
        guard let a=o[key] as? [NSNumber] else {
            throw Failure.invalid("Missing original 81nm source "+key)
        }
        return a.map{$0.doubleValue}
    }
    static func scalar(_ o:[String:Any],_ key:String) throws -> Double {
        guard let a=o[key] as? NSNumber else {
            throw Failure.invalid("Missing source scalar "+key)
        }
        return a.doubleValue
    }
    static func compare(
        _ actual:[Double],_ original:[Double],_ label:String,
        limit:Double
    ) throws -> Double {
        guard actual.count==original.count else {
            throw Failure.invalid(label+" shape mismatch")
        }
        var worst=0.0
        for i in actual.indices {
            let delta=abs(actual[i]-original[i])
            guard delta.isFinite && delta<=limit else {
                throw Failure.invalid(
                    "\(label) #\(i) Swift \(actual[i]) " +
                    "source \(original[i]) error \(delta)"
                )
            }
            worst=max(worst,delta)
        }
        return worst
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need source 81nm scanner JSON fixture")
        }
        let data=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let obj=try JSONSerialization.jsonObject(with:data)
                as? [String:Any],
              let cases=obj["cases"] as? [[String:Any]],
              let papers=obj["profiles"] as? [String:String],
              papers.count==12,cases.count==48 else {
            throw Failure.invalid("Expected 12 measured original source materials")
        }
        var maxXYZ=0.0,maxLinear=0.0,maxACES=0.0,maxCCTF=0.0
        var totalPositive=0,totalPaper=0,k75=0,masked=0
        for (ix,test) in cases.enumerated() {
            guard let valid=test["valid"] as? [Bool],
                  let viewing=test["viewing"] as? String,
                  let medium=test["medium"] as? String else {
                throw Failure.invalid("Source wavelength mask/viewing missing")
            }
            if viewing=="K75P" {k75+=1}
            if medium=="filming" {totalPositive+=1}
            if medium=="printing" {totalPaper+=1}
            if valid.contains(false) {masked+=1}
            let xyz=try Build88OriginalScannerSpectrum.sourceXYZ(
                density:try vector(test,"density"),
                base:try vector(test,"base"),
                dye:try vector(test,"dye"),
                weightedXYZ:try vector(test,"weighted"),
                valid:valid,
                normalization:try scalar(test,"normalization")
            )
            maxXYZ=max(maxXYZ,try compare(
                xyz,try vector(test,"sourceXYZ"),
                "source 81nm film/paper XYZ #\(ix)",limit:2e-8
            ))
            // Both conversion steps use the actual production helpers:
            // Colour XYZ→linear sRGB with original viewing white,
            // then the original source optional ACES-RGC compression.
            let nativeLinear=OriginalScannerMath.linearSRGB(
                xyz:xyz,viewing:viewing
            )
            maxLinear=max(maxLinear,try compare(
                nativeLinear,try vector(test,"sourceLinear"),
                "source Colour XYZ_to_RGB #\(ix)",limit:2e-7
            ))
            let compressed=OriginalScannerMath.compressACESRGC(
                nativeLinear
            )
            maxACES=max(maxACES,try compare(
                compressed,try vector(test,"sourceCompressed"),
                "source ACES-RGC #\(ix)",limit:2e-7
            ))
            let output=OriginalScannerMath.sourceCCTFEncoding(
                compressed
            )
            maxCCTF=max(maxCCTF,try compare(
                output,try vector(test,"sourceCCTF"),
                "source scanner output CCTF #\(ix)",limit:2e-7
            ))
        }
        guard totalPaper==32,totalPositive==16,k75>0,masked>0 else {
            throw Failure.invalid(
                "Original eight papers/four positives, K75P or masked wavelengths absent"
            )
        }
        // The source scanner output uses +1e-10 after log10/10^.
        let black=Build88OriginalScannerSpectrum.finishXYZ(
            [0,0,0],normalization:1,sourceLogEpsilon:true
        )
        guard black.allSatisfy({abs($0-1e-10)<1e-22}) else {
            throw Failure.invalid("Source log10 1e-10 black XYZ epsilon missing")
        }
        print("PASS BUILD88 ORIGINAL 81nm SOURCE SCANNER: " +
              "12 measured stock profiles / 48 measured densities, " +
              "8 papers + 4 positive film direct scans, D50/K75P, " +
              "real NaN wavelength masks, source log10 and CCTF. " +
              "XYZ worst=\(maxXYZ), XYZ→linear worst=\(maxLinear), " +
              "ACES worst=\(maxACES), encoded worst=\(maxCCTF).")
    }
}
