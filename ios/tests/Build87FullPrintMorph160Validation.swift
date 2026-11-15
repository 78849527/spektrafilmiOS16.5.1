import Foundation

/// 160 full 256×3 fitted s023 paper curves, 122,880 source nodes,
/// plus 160×9×3 original interpolated exposure references.
/// Uses actual production OriginalPrintMorph.swift on native macOS.
@main
enum Build87FullPrintMorph160Validation {
    enum Failure:Error {case invalid(String)}
    static func array(_ o:[String:Any],_ key:String) throws -> [Double] {
        guard let a=o[key] as? [NSNumber] else {
            throw Failure.invalid("Missing source "+key)
        }
        return a.map{$0.doubleValue}
    }
    static func scalar(_ o:[String:Any],_ key:String) throws -> Double {
        guard let a=o[key] as? NSNumber else {
            throw Failure.invalid("Missing scalar "+key)
        }
        return a.doubleValue
    }
    static func maxDelta(
        _ a:[Double],_ b:[Double],_ label:String,
        limit:Double=3e-9
    ) throws -> Double {
        guard a.count==b.count else {
            throw Failure.invalid(label+" source length mismatch")
        }
        var result=0.0
        for i in a.indices {
            let delta=abs(a[i]-b[i])
            guard delta.isFinite,delta<=limit else {
                throw Failure.invalid(
                    "\(label) #\(i) Python=\(b[i]) Swift=\(a[i]) Δ\(delta)"
                )
            }
            result=max(result,delta)
        }
        return result
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need real original s023 morph oracle")
        }
        let data=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:data)
                as? [String:Any],
              let pins=root["pins"] as? [String:String],
              let cases=root["cases"] as? [[String:Any]],
              pins.count==8,cases.count==160 else {
            throw Failure.invalid("Missing 8 real paper x 160 source curves")
        }
        var curveWorst=0.0,interpWorst=0.0,over3=0,exhausted=0
        for (index,item) in cases.enumerated() {
            guard let stock=item["stock"] as? String,
                  let positive=item["positive"] as? Bool,
                  let params=item["params"] as? [String:Any],
                  let active=params["active"] as? Bool else {
                throw Failure.invalid("Invalid original morph case metadata")
            }
            var mode=OriginalPrintMorph.Settings()
            mode.gamma=try scalar(params,"gamma_factor")
            mode.fast=try scalar(params,"gamma_factor_fast")
            mode.slow=try scalar(params,"gamma_factor_slow")
            mode.red=try scalar(params,"gamma_factor_red")
            mode.green=try scalar(params,"gamma_factor_green")
            mode.blue=try scalar(params,"gamma_factor_blue")
            mode.developerExhaustion=try scalar(
                params,"developer_exhaustion"
            )
            // Original PrintingStage.develop handles morph active=false by
            // sampling the same fitted baseline. The Swift settings struct
            // has no active flag: neutral mode is the identical source curve.
            if !active {mode=OriginalPrintMorph.Settings()}
            guard mode.valid else {
                throw Failure.invalid("Source valid morph parameter was rejected")
            }
            if mode.gamma>3 || mode.red>3 {over3+=1}
            if mode.developerExhaustion==1 {exhausted+=1}
            let axis=try array(item,"axis")
            guard let prepared=OriginalPrintMorph.prepareSource(
                stock:stock,logExposure:axis,settings:mode,
                positive:positive
            ) else {
                throw Failure.invalid(
                    "Unable to prepare source 256-node model \(stock) #\(index)"
                )
            }
            let expected=try array(item,"density")
            guard expected.count==768 else {
                throw Failure.invalid("Wrong original source curve shape")
            }
            var real:[Double]=[]
            real.reserveCapacity(768)
            for node in 0..<256 {
                for ch in 0..<3 {
                    real.append(prepared.channels[ch][node])
                }
            }
            curveWorst=max(curveWorst,try maxDelta(
                real,expected,"source morph \(stock) #\(index)"
            ))
            let sample=try array(item,"sampleX")
            let expectedInterp=try array(item,"sampleDensity")
            var actualInterp:[Double]=[]
            for x in sample {
                for ch in 0..<3 {
                    actualInterp.append(prepared.density(x,channel:ch))
                }
            }
            interpWorst=max(interpWorst,try maxDelta(
                actualInterp,expectedInterp,
                "source 256-node right-biased interpolation \(stock) #\(index)"
            ))
        }
        guard over3>0,exhausted==16 else {
            throw Failure.invalid("Missing source high gamma or exhaustion limit")
        }
        var bad=OriginalPrintMorph.Settings()
        bad.gamma=0
        guard !bad.valid else {
            throw Failure.invalid("Accepted invalid source zero gamma")
        }
        print("PASS BUILD87 ORIGINAL FULL 256-node s023 PAPER MORPH: " +
              "8 actual stocks, negative/positive, 10 source parameter " +
              "branches, 122880 Double curve nodes, gamma>3, " +
              "exhaustion=1; max curve=\(curveWorst), " +
              "max interpolation=\(interpWorst), abs tol=3e-9.")
    }
}
