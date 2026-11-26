import Foundation

@main
enum Build84DynamicDIR80StockValidation {
    enum Failure:Error { case invalid(String) }
    static func vector(_ o:[String:Any],_ key:String) throws -> [Double] {
        guard let v=o[key] as? [NSNumber] else {
            throw Failure.invalid("Missing source "+key)
        }
        return v.map{$0.doubleValue}
    }
    static func scalar(_ o:[String:Any],_ key:String) throws -> Double {
        guard let n=o[key] as? NSNumber else {
            throw Failure.invalid("Missing scalar "+key)
        }
        return n.doubleValue
    }
    static func check(
        _ a:[Double],_ b:[Double],_ label:String,
        tolerance:Double=5e-11
    ) throws -> Double {
        guard a.count==b.count else {
            throw Failure.invalid(label+" shape mismatch")
        }
        var worst=0.0
        for i in a.indices {
            let d=abs(a[i]-b[i])
            guard d.isFinite && d<=tolerance else {
                throw Failure.invalid(
                    "\(label) #\(i) source=\(b[i]) native=\(a[i]) Δ=\(d)"
                )
            }
            worst=max(worst,d)
        }
        return worst
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Missing pinned Python source oracle")
        }
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard let cases=try JSONSerialization.jsonObject(with:data)
                as? [[String:Any]],cases.count==80 else {
            throw Failure.invalid("Expected 80 real-film source cases")
        }
        var maxM=0.0,maxCurve=0.0,maxChem=0.0
        for (index,item) in cases.enumerated() {
            guard let stock=item["stock"] as? String,
                  let positive=item["positive"] as? Bool,
                  let args=item["settings"] as? [String:Any],
                  let active=args["active"] as? Bool else {
                throw Failure.invalid("Invalid source stock or settings")
            }
            var settings=Build84OriginalFilmDIR.RuntimeSettings()
            settings.active=active
            settings.amount=try scalar(args,"amount")
            settings.inhibitionSameLayer=try scalar(args,"same")
            settings.inhibitionInterlayer=try scalar(args,"inter")
            settings.gammaRGB=try vector(args,"gamma")
            settings.highExposureShift=try scalar(args,"shift")
            let prepared=try Build84OriginalFilmDIR.prepare(
                stock:stock,positive:positive,
                logExposure:try vector(item,"logAxis"),
                normalizedDensityCurves:try vector(item,"curves"),
                settings:settings
            )
            maxM=max(maxM,try check(
                prepared.matrix,try vector(item,"matrix"),
                "DIR matrix \(stock) #\(index)"
            ))
            if active {
                maxCurve=max(maxCurve,try check(
                    prepared.beforeDIR,try vector(item,"beforeDIR"),
                    "pre-DIR 256-node \(stock) #\(index)"
                ))
            }
            let raw=try vector(item,"raw")
            let expectedInitial=try vector(item,"initial")
            let expectedCorrectedRaw=try vector(item,"correctedRaw")
            let expectedFinal=try vector(item,"final")
            guard raw.count==9 else {
                throw Failure.invalid("Expected 3×3 real-film exposures")
            }
            var initial=[Double](),corrected=[Double](),result=[Double]()
            for pixel in 0..<3 {
                let offset=pixel*3
                let input=Array(raw[offset..<offset+3])
                let developed=try prepared.develop(input,corrected:false)
                for corrected in [false,true] {
                    let reference=try prepared.develop(input,corrected:corrected,
                                                       usePreparedReciprocals:false)
                    let optimized=try prepared.develop(input,corrected:corrected)
                    precondition(reference.map(\.bitPattern)==optimized.map(\.bitPattern),
                                 "OPT prepared H-D reciprocal changed original bits")
                }
                initial+=developed
                let correctedLog:[Double]
                if active {
                    let inhibitors=try prepared.inhibitor(developed)
                    let scalar=try Build84OriginalFilmDIR.inhibitors(
                        density:developed,maximum:prepared.maximum,matrix:prepared.matrix,
                        positive:prepared.positive,highExposureShift:settings.highExposureShift,
                        scalarReference:true)
                    precondition(inhibitors.map(\.bitPattern)==scalar.map(\.bitPattern),
                                 "OPT DIR donor SIMD changed ordered bits")
                    correctedLog=(0..<3).map {
                        input[$0]-inhibitors[$0]
                    }
                } else {
                    correctedLog=input
                }
                corrected+=correctedLog
                result+=try prepared.develop(
                    correctedLog,corrected:active
                )
            }
            maxChem=max(maxChem,try check(
                initial,expectedInitial,"initial H-D \(stock) #\(index)"
            ))
            maxChem=max(maxChem,try check(
                corrected,expectedCorrectedRaw,
                "DIR chemistry \(stock) #\(index)"
            ))
            maxChem=max(maxChem,try check(
                result,expectedFinal,"final H-D \(stock) #\(index)"
            ))
        }
        // Explicit fail, not silent drop, for a missing original knot table.
        do {
            _=try Build84OriginalFilmDIR.prepare(
                stock:"kodak_portra_400",positive:false,
                logExposure:[0,1],normalizedDensityCurves:[0,0,0,1,1,1],
                settings:.init()
            )
            throw Failure.invalid("Accepted truncated source 256-point curves")
        } catch Build84OriginalFilmDIR.Failure.invalid(_) {
            // Expected source-only input validation.
        }
        print("PASS Build84 BULK 80 measured film/settings cases, " +
              "20 stocks × 4 modes: matrix max=\(maxM), " +
              "256-point corrected curves max=\(maxCurve), " +
              "initial/chemical/final max=\(maxChem). " +
              "CPU Float64 absolute tolerance 5e-11.")
    }
}
