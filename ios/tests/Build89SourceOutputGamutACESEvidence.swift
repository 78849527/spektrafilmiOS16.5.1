import Foundation

@main
enum Build89SourceOutputGamutACESEvidence {
    enum Failure:Error {case invalid(String)}
    static func nums(_ data:[String:Any],_ key:String) throws->[Double] {
        guard let a=data[key] as? [NSNumber] else {
            throw Failure.invalid("Source array \(key) missing")
        }
        return a.map{$0.doubleValue}
    }
    static func match(
        _ native:[Double],_ source:[Double],_ name:String
    ) throws->Double {
        guard native.count==source.count else {
            throw Failure.invalid(name+" array size mismatch")
        }
        var worst=0.0
        for i in native.indices {
            let error=abs(native[i]-source[i])
            guard error.isFinite,error<=3e-13 else {
                throw Failure.invalid(
                    "\(name) #\(i) Swift \(native[i]), " +
                    "original \(source[i]), delta=\(error)"
                )
            }
            worst=max(worst,error)
        }
        return worst
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Source ACES 126 cases file needed")
        }
        let raw=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:raw)
                as? [String:Any],
              let cases=root["cases"] as? [[String:Any]],
              cases.count==126 else {
            throw Failure.invalid("Original ACES/OFF 126 cases missing")
        }
        var worst=0.0,off=0,aces=0,negative=0,superwhite=0
        for (i,record) in cases.enumerated() {
            guard let algorithm=record["algorithm"] as? String,
                  let choice=Build89OriginalOutputGamut.Algorithm(
                    rawValue:algorithm
                  ) else {
                throw Failure.invalid("Unknown source algorithm")
            }
            let input=try nums(record,"rgb")
            let parameters=try nums(record,"knee")
            let optional=(record["light"] as? [NSNumber])?.map {
                $0.doubleValue
            }
            let light:Build89OriginalOutputGamut.Knee?
            if let optional {
                light=Build89OriginalOutputGamut.Knee(
                    threshold:optional[0],
                    limit:optional[1],power:optional[2]
                )
            } else {
                light=nil
            }
            var settings=Build89OriginalOutputGamut.Settings()
            settings.algorithm=choice
            settings.knee=Build89OriginalOutputGamut.Knee(
                threshold:parameters[0],
                limit:parameters[1],power:parameters[2]
            )
            settings.lightness=light
            try settings.validate()
            let actual=try Build89OriginalOutputGamut.compress(
                input,settings:settings
            )
            worst=max(worst,try match(
                actual,try nums(record,"answer"),
                "source \(algorithm) custom knee #\(i)"
            ))
            if choice == .off {
                guard input==actual else {
                    throw Failure.invalid("Original OFF did not preserve raw")
                }
                off+=1
            } else {aces+=1}
            if input.contains(where:{$0<0}){negative+=1}
            if input.contains(where:{$0>1}){superwhite+=1}
        }
        guard off==28,aces==98,negative>0,superwhite>0 else {
            throw Failure.invalid("Off/ACES/OOG scenarios missing")
        }
        for algorithm in [
            Build89OriginalOutputGamut.Algorithm.oklch,
            .oklrab,.jzazbz
        ] {
            var setting=Build89OriginalOutputGamut.Settings()
            setting.algorithm=algorithm
            do {
                _=try Build89OriginalOutputGamut.compress(
                    [0.9,-0.2,0.2],settings:setting
                )
                throw Failure.invalid(
                    "Unsupported exact perceptual algorithm silently succeeded"
                )
            } catch Build89OriginalOutputGamut.Failure.invalid(_) {}
        }
        var invalid=Build89OriginalOutputGamut.Settings()
        invalid.knee.threshold=1
        do {
            try invalid.validate()
            throw Failure.invalid("Invalid original knee accepted")
        } catch Build89OriginalOutputGamut.Failure.invalid(_) {}
        invalid.knee.threshold=0
        invalid.knee.power=0
        do {
            try invalid.validate()
            throw Failure.invalid("Original zero power accepted")
        } catch Build89OriginalOutputGamut.Failure.invalid(_) {}
        print("PASS BUILD89 ORIGINAL source ACES/OFF: 126 original " +
              "Python Float64 cases, no clipping or early gamut clamp, " +
              "7 ACES knee modes, OFF identity, " +
              "negative/superwhite and fail-closed unsupported; " +
              "max source abs delta \(worst).")
    }
}
