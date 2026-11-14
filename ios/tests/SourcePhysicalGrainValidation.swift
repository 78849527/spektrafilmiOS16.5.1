import Foundation
import CryptoKit

/// Actually executes the full Swift 3×3 source grain stages against
/// independently EXECUTED upstream Python grain.py whole-image Float64
/// fixtures, including real SciPy legacy counts and reflect FIR/YVV.
@main
enum SourcePhysicalGrainValidation {
    private struct Manifest: Decodable {
        let scope:String
        let numba_seed:UInt32
        let cases:[Fixture]
    }
    private struct Fixture:Decodable {
        let name:String
        let width:Int
        let height:Int
        let pixelUM:Double
        let dyeBlur:Double
        let finalBlur:Double
        let microUM:Double
        let microNM:Double
        let maxima:[Double]
        let microEnabled:Bool
        let sha256:[String:String]
    }
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(v)=self { return v }
            return nil
        }
    }
    private static func read(
        _ directory:URL,caseName:String,stage:String,
        expectedSha:String,width:Int,height:Int
    ) throws -> [Double] {
        let path=directory.appendingPathComponent(
            caseName+"."+stage+".f64le"
        )
        let data=try Data(contentsOf:path)
        let sha=SHA256.hash(data:data).map{
            String(format:"%02x",$0)
        }.joined()
        guard sha==expectedSha,
              data.count == width * height * (stage=="sublayers" ? 9 : 3) * 8 else {
            throw Failure.invalid("Python grain.py fixture hash/count mismatch "+path.lastPathComponent)
        }
        return data.withUnsafeBytes{raw in
            (0..<(data.count/8)).map{k in
                let u=raw.loadUnaligned(fromByteOffset:k*8,as:UInt64.self)
                return Double(bitPattern:UInt64(littleEndian:u))
            }
        }
    }
    static func main() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let directory=root.appendingPathComponent(
            "ios/verification/generated-source-grain-v1.8.48"
        )
        let manifest=try JSONDecoder().decode(
            Manifest.self,from:Data(contentsOf:directory.appendingPathComponent("manifest.json"))
        )
        guard manifest.cases.count==3,manifest.numba_seed==8888,
              manifest.scope.contains("unmodified original grain.py") else {
            throw Failure.invalid("No original Python grain.py full-frame reference")
        }
        var checked=0
        var worst=0.0
        for sample in manifest.cases {
            let w=sample.width,h=sample.height
            let maxima=sample.maxima
            guard maxima.count==9 else {
                throw Failure.invalid("3x3 source maxima absent")
            }
            var density=[Double](repeating:0,count:w*h*3)
            for p in 0..<(w*h) {
                for ch in 0..<3 {
                    density[p*3+ch] = 0.12 + 0.015 * Double((p+ch*4)%9)
                }
            }
            let measured=OriginalSourcePhysicalGrain.MeasuredLayers(
                maxima:maxima,
                sublayers:{ rgb in
                    guard rgb.count==3 else {
                        throw Failure.invalid("Synthetic 3x3 test density missing")
                    }
                    return (0..<3).flatMap { sl in
                        (0..<3).map {ch in
                            let total=maxima[ch]+maxima[3+ch]+maxima[6+ch]
                            return rgb[ch]*maxima[sl*3+ch]/total
                        }
                    }
                }
            )
            var settings=OriginalSourcePhysicalGrain.Settings()
            settings.active=true
            settings.grainBlur=sample.finalBlur
            settings.dyeCloudBlurUM=sample.dyeBlur
            settings.microstructureUM=sample.microUM
            settings.microstructureNM=sample.microNM
            settings.numbaSeed=manifest.numba_seed
            var trace=[String:[Double]]()
            let actual=try OriginalSourcePhysicalGrain.apply(
                density,width:w,height:h,pixelUM:sample.pixelUM,
                measured:measured,settings:settings,
                stageObserver:{name,array in trace[name]=array}
            )
            let stageNames=[
                ("sublayers","sourceGrainSublayers"),
                ("dyeClouds","sourceGrainDyeClouds"),
                ("microstructure","sourceGrainMicrostructure"),
                ("final","sourceGrainFinalDensity")
            ]
            for (python,swift) in stageNames {
                guard let bytes=sample.sha256[python],
                      let observed=trace[swift] else {
                    throw Failure.invalid("Missing stage "+python+" or "+swift)
                }
                let expected=try read(directory,caseName:sample.name,
                                      stage:python,expectedSha:bytes,
                                      width:w,height:h)
                guard observed.count==expected.count else {
                    throw Failure.invalid("Source grain stage pixel count mismatch")
                }
                var peak=0.0
                for k in observed.indices {
                    let diff=abs(expected[k]-observed[k])
                    peak=max(peak,diff)
                    guard diff.isFinite && diff<=1e-10 else {
                        throw Failure.invalid(
                            "upstream grain.py divergence case=\(sample.name) stage=\(python) pixel=\(k) error=\(diff) Python=\(expected[k]) Swift=\(observed[k])"
                        )
                    }
                }
                worst=max(worst,peak)
                print("PASS original source grain \(sample.name) stage=\(python) channels=\(observed.count) max=\(peak)")
                checked+=observed.count
            }
            // Actual engine repeatability and NO silent approximation.
            let repeated=try OriginalSourcePhysicalGrain.apply(
                density,width:w,height:h,pixelUM:sample.pixelUM,
                measured:measured,settings:settings
            )
            guard repeated==actual,actual != density else {
                throw Failure.invalid("Controlled seeded source grain not deterministic")
            }
            settings.numbaSeed=nil
            do {
                _=try OriginalSourcePhysicalGrain.apply(
                    density,width:w,height:h,pixelUM:sample.pixelUM,
                    measured:measured,settings:settings
                )
                throw Failure.invalid("Missing Numba seed silently accepted")
            } catch OriginalSourcePhysicalGrain.Failure.invalid {}
        }
        print("PASS original Python grain.py source 3x3 production DENSITY: \(manifest.cases.count) real whole-frame fixtures, \(checked) stage channels, max Float64 discrepancy=\(worst), controlled seed 8888 reproducibility and missing-seed rejection.")
        print("NOT CERTIFIED: unseeded prange multiworker RNG, RAW, real iPhone full-display RGB original matching.")
    }
}
