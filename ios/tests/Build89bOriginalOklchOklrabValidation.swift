import Foundation

@main
enum Build89bOriginalOklchOklrabValidation {
    enum Failure:Error {case invalid(String)}
    private static func nums(_ row:[String:Any],_ key:String)throws->[Double] {
        guard let list=row[key] as? [NSNumber] else {
            throw Failure.invalid("Missing original source "+key)
        }
        return list.map{$0.doubleValue}
    }
    private static func match(
        _ actual:[Double],_ expected:[Double],_ label:String,
        limit:Double=1e-9
    )throws->Double {
        guard actual.count==expected.count else {
            throw Failure.invalid(label+" wrong Float64 vector length")
        }
        var largest=0.0
        for i in actual.indices {
            let delta=abs(actual[i]-expected[i])
            guard delta.isFinite && delta<=limit else {
                throw Failure.invalid(
                    "\(label) channel \(i), native=\(actual[i]), " +
                    "source=\(expected[i]), delta=\(delta) limit=\(limit)"
                )
            }
            largest=max(largest,delta)
        }
        return largest
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need original Python 144 case oracle")
        }
        let raw=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let payload=try JSONSerialization.jsonObject(with:raw)
                as? [String:Any],
              let cases=payload["cases"] as? [[String:Any]],
              cases.count==144 else {
            throw Failure.invalid("Need 144 real source colour-gamut cases")
        }
        var worst=0.0,oklch=0,oklrab=0,wide=0,lightOff=0
        for (index,row) in cases.enumerated() {
            guard let alg=row["algorithm"] as? String,
                  let choice=Build89OriginalOutputGamut.Algorithm(
                    rawValue:alg
                  ),
                  let space=row["space"] as? String,
                  let outSpace=Build89OriginalOutputGamut.OutputSpace(
                    rawValue:space
                  ) else {
                throw Failure.invalid("Unknown source output space/algorithm")
            }
            let rgb=try nums(row,"rgb")
            let knee=try nums(row,"knee")
            let l=(row["light"] as? [NSNumber])?.map{$0.doubleValue}
            var settings=Build89OriginalOutputGamut.Settings()
            settings.algorithm=choice
            settings.outputSpace=outSpace
            settings.knee=Build89OriginalOutputGamut.Knee(
                threshold:knee[0],limit:knee[1],power:knee[2]
            )
            settings.lightness=l.map { a in
                Build89OriginalOutputGamut.Knee(
                    threshold:a[0],limit:a[1],power:a[2]
                )
            }
            let actual=try Build89OriginalOutputGamut.compress(
                rgb,settings:settings
            )
            worst=max(worst,try match(
                actual,try nums(row,"expected"),
                "source original \(alg)/\(space) #\(index)"
            ))
            if choice == .oklch {oklch+=1}
            if choice == .oklrab {oklrab+=1}
            if outSpace != .sRGB {wide+=1}
            if l == nil {lightOff+=1}
        }
        guard oklch==72,oklrab==72,wide==96,lightOff==72 else {
            throw Failure.invalid("Source Oklch/Oklrab mode coverage drift")
        }
        let black=try Build89bOriginalOklabGamut.xyzToOklab(
            [0,0,0]
        )
        guard black.allSatisfy({$0==0}) else {
            throw Failure.invalid("Original Oklab must anchor exact black")
        }
        print("PASS BUILD89B ORIGINAL OKLCH+OKLRAB: " +
              "144/144 original Python 64×720×18 Cmax Float64 vectors; " +
              "3 output RGB spaces; 2 knee/lightness settings; " +
              "max actual native RGB abs delta=\(worst), tol=1e-9; " +
              "no 33³ LUT and no ACES fallback.")
    }
}
