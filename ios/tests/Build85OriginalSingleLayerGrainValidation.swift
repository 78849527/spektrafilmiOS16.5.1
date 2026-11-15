import Foundation

@main
enum Build85OriginalSingleLayerGrainValidation {
    enum Failure:Error { case invalid(String) }

    static func numbers(_ root:[String:Any],_ key:String) throws -> [Double] {
        guard let n=root[key] as? [NSNumber] else {
            throw Failure.invalid("Missing pinned Python source "+key)
        }
        return n.map{$0.doubleValue}
    }
    static func integer(_ root:[String:Any],_ key:String) throws -> Int {
        guard let n=root[key] as? NSNumber else {
            throw Failure.invalid("Missing original count "+key)
        }
        return n.intValue
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need original grain.py AST SciPy fixtures")
        }
        let data=try Data(
            contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])
        )
        guard let items=try JSONSerialization.jsonObject(with:data)
                as? [[String:Any]],items.count==36 else {
            throw Failure.invalid("Need all 36 real-film source SciPy cases")
        }
        var worst=0.0
        for (ix,item) in items.enumerated() {
            let input=try numbers(item,"input")
            let original=try numbers(item,"output")
            let maxCurve=try numbers(item,"maximum")
            let width=try integer(item,"width")
            let height=try integer(item,"height")
            let n=try integer(item,"n")
            guard let blur=(item["blur"] as? NSNumber)?.doubleValue else {
                throw Failure.invalid("No source grain blur value")
            }
            var settings=OriginalSourcePhysicalGrain.Settings()
            settings.active=true
            settings.sublayersActive=false
            settings.nSubLayers=n
            settings.grainBlur=blur
            // One- and N-sublayer source branch does not use Numba
            // microstructure. No fake fixed seed is supplied here.
            let actual=try OriginalSourcePhysicalGrain.applySingleLayer(
                input,width:width,height:height,
                pixelUM:1.8,maximum:maxCurve,settings:settings
            )
            guard original.count==actual.count else {
                throw Failure.invalid("Source shape mismatch #\(ix)")
            }
            for k in actual.indices {
                let delta=abs(actual[k]-original[k])
                guard delta.isFinite,delta<=2e-8 else {
                    throw Failure.invalid(
                        "SOURCE GRAIN #\(ix) sample \(k), " +
                        "source \(original[k]), Swift \(actual[k]), " +
                        "delta \(delta)"
                    )
                }
                worst=max(worst,delta)
            }
            // grain.py::apply_grain() ignores use_fast_stats for
            // sublayers_active=false. It MUST remain SciPy with identical
            // sample values rather than reject a valid source combination.
            settings.useFastStats=true
            try settings.validate()
            let stillSciPy=try OriginalSourcePhysicalGrain.applySingleLayer(
                input,width:width,height:height,
                pixelUM:1.8,maximum:maxCurve,settings:settings
            )
            guard stillSciPy.count==original.count else {
                throw Failure.invalid("Source fast_stats-ignored shape mismatch")
            }
            for k in stillSciPy.indices {
                let delta=abs(stillSciPy[k]-original[k])
                guard delta.isFinite,delta<=2e-8 else {
                    throw Failure.invalid(
                        "Single-layer fast_stats source-ignored flag diverged at \(k), delta \(delta)"
                    )
                }
            }
        }
        print("PASS Build104 ORIGINAL GRAIN.PY/SciPy 36 real-stock " +
              "single-/multi-layer seeded Poisson+Binomial RGB frames; " +
              "use_fast_stats false/true same source output, " +
              "maxAbsolute=\(worst), tolerance=2e-8, original FIR threshold.")
    }
}
