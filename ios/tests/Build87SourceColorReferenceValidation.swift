import Foundation

@main
enum Build87SourceColorReferenceValidation {
    enum Failure:Error { case invalid(String) }

    static func vector(_ root:[String:Any],_ name:String) throws -> [Double] {
        guard let array=root[name] as? [NSNumber] else {
            throw Failure.invalid("Missing source reference "+name)
        }
        return array.map{$0.doubleValue}
    }
    static func scalar(_ root:[String:Any],_ name:String) throws -> Double {
        guard let val=root[name] as? NSNumber else {
            throw Failure.invalid("Missing source scalar "+name)
        }
        return val.doubleValue
    }
    static func compare(
        _ a:[Double],_ b:[Double],_ label:String,
        tol:Double=5e-10
    ) throws -> Double {
        guard a.count==b.count else {
            throw Failure.invalid(label+" source length mismatch")
        }
        var worst=0.0
        for i in a.indices {
            let error=abs(a[i]-b[i])
            guard error.isFinite,error<=tol else {
                throw Failure.invalid(
                    "\(label) #\(i) Swift \(a[i]) Python \(b[i]) Δ\(error)"
                )
            }
            worst=max(worst,error)
        }
        return worst
    }

    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need exact-source Python JSON oracle")
        }
        let data=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:data)
              as? [String:Any],
              let cases=root["cases"] as? [[String:Any]],
              let pins=root["pins"] as? [String:String],
              pins.count>=6,cases.count==pins.count*8 else {
            throw Failure.invalid("Incomplete original source paper stock set")
        }
        var worst=0.0,positives=0,prints=0,off=0
        for (index,test) in cases.enumerated() {
            guard let args=test["settings"] as? [String:Any],
                  let b=args["blackCorrection"] as? Bool,
                  let w=args["whiteCorrection"] as? Bool,
                  let stock=test["stock"] as? String,
                  let filmType=test["type"] as? String else {
                throw Failure.invalid("Missing ColorReferenceService args")
            }
            var setting=Build87OriginalColorReference.Settings()
            setting.blackCorrection=b
            setting.whiteCorrection=w
            setting.blackLevel=try scalar(args,"blackLevel")
            setting.whiteLevel=try scalar(args,"whiteLevel")
            let prepared=try Build87OriginalColorReference.prepare(
                settings:setting,
                yBlack:try scalar(test,"yBlack"),
                yWhite:try scalar(test,"yWhite")
            )
            worst=max(worst,try compare(
                [prepared.midgrayBeforeCorrection],
                [try scalar(test,"mid")],
                "source midgray \(stock) #\(index)"
            ))
            let sourceXYZ=try vector(test,"sourceXYZ")
            let correctedXYZ=try vector(test,"correctedXYZ")
            guard sourceXYZ.count==12 else {
                throw Failure.invalid("Bad source XYZ sample count")
            }
            var actualXYZ:[Double]=[]
            for k in stride(from:0,to:sourceXYZ.count,by:3) {
                let result=try prepared.correctXYZ(Array(sourceXYZ[k..<k+3]))
                actualXYZ+=result
            }
            worst=max(worst,try compare(
                actualXYZ,correctedXYZ,"source scanner XYZ \(stock) #\(index)"
            ))
            let axis=try vector(test,"axis")
            let curves=try vector(test,"curves")
            let base=try vector(test,"base")
            let actualFactor:Double
            if filmType=="positive" {
                positives+=1
                actualFactor=try prepared.filmingExposureFactor(
                    logExposure:axis,densityCurves:curves,
                    spectralBase:base
                )
            } else {
                prints+=1
                actualFactor=try prepared.printExposureFactor(
                    logExposure:axis,densityCurves:curves,
                    spectralBase:base
                )
            }
            if !b && !w {
                off+=1
                guard actualFactor==1,actualXYZ==sourceXYZ else {
                    throw Failure.invalid("Source disabled black/white altered output")
                }
            }
            worst=max(worst,try compare(
                [actualFactor],[try scalar(test,"exposureFactor")],
                "source print/positive exposure \(stock) #\(index)"
            ))
        }
        guard positives>0,prints>0,off==pins.count else {
            throw Failure.invalid("No positive/printing source topology")
        }
        do {
            var invalid=Build87OriginalColorReference.Settings()
            invalid.blackCorrection=true
            _=try Build87OriginalColorReference.prepare(
                settings:invalid,yBlack:0.4,yWhite:0.4
            )
            throw Failure.invalid("Degenerate source calibration accepted")
        } catch Build87OriginalColorReference.Failure.invalid(_) {}
        print("BUILD87 ORIGINAL COLOR REFERENCE PYTHON AST PASS: " +
              "\(pins.count) real stocks × 8 modes = \(cases.count); " +
              "printing=\(prints) positive=\(positives) disabled=\(off); " +
              "maxAbsolute=\(worst) tol=5e-10.")
    }
}
