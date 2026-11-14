import Foundation
import CryptoKit

/// v1.8.48 original Python grain.py real 2D full-field intermediate stages.
/// This test reads source files produced by executing UNMODIFIED source
/// grain.py, rather than a Swift-generated surrogate or matched distribution.
/// It validates controlled single-worker Numba only; parallel prange is not
/// deterministically emulated.
@main
struct SourcePhysicalGrainParity {
    struct Manifest: Decodable {
        let scope: String
        let numba_seed: UInt32
        let cases: [Case]
    }
    struct Case: Decodable {
        let name: String
        let width: Int
        let height: Int
        let pixelUM: Double
        let dyeBlur: Double
        let finalBlur: Double
        let microUM: Double
        let microNM: Double
        let maxima: [Double]
        let microEnabled: Bool
        let sha256: [String:String]
    }

    static func load(_ directory: URL,_ fixture: Case,_ label: String) throws -> [Double] {
        guard let checksum=fixture.sha256[label] else {
            fatalError("missing upstream source checksum for \(label)")
        }
        let data=try Data(contentsOf:directory.appendingPathComponent(
            fixture.name+"."+label+".f64le"
        ))
        let digest=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        guard digest==checksum, data.count%8==0 else {
            fatalError("original Python grain reference data SHA256/Float64 invalid")
        }
        return data.withUnsafeBytes { bytes in
            (0..<(data.count/8)).map { k in
                let word=bytes.loadUnaligned(fromByteOffset:k*8,as:UInt64.self)
                return Double(bitPattern:UInt64(littleEndian:word))
            }
        }
    }

    static func check(_ actual:[Double],_ expected:[Double],
                      _ label:String, atol:Double) {
        guard actual.count==expected.count else {
            fatalError("source grain \(label): original/reference length mismatch \(actual.count),\(expected.count)")
        }
        var maximum=0.0
        var worst=0
        var mae=0.0
        for i in actual.indices {
            guard actual[i].isFinite,expected[i].isFinite else {
                fatalError("source grain \(label) non-finite at \(i)")
            }
            let difference=abs(actual[i]-expected[i])
            mae+=difference
            if difference>maximum { maximum=difference;worst=i }
        }
        mae/=Double(actual.count)
        guard maximum<=atol else {
            fatalError("source grain \(label) first numeric failure max=\(maximum) at \(worst), source=\(expected[worst]) Swift=\(actual[worst]) tolerance=\(atol)")
        }
        print("PASS upstream grain.py stage \(label) count=\(actual.count) MAE=\(mae) max=\(maximum) tol=\(atol)")
    }

    static func main() throws {
        let directory=URL(fileURLWithPath:"ios/verification/generated-source-grain-v1.8.48")
        let json=try Data(contentsOf:directory.appendingPathComponent("manifest.json"))
        let manifest=try JSONDecoder().decode(Manifest.self,from:json)
        guard manifest.cases.count==3,manifest.numba_seed==8888,
              manifest.scope.contains("original grain.py") else {
            fatalError("Expected three independent source grain.py Python images")
        }
        for fixture in manifest.cases {
            let n=fixture.width*fixture.height
            guard fixture.maxima.count==9,
                  fixture.sha256.count==4,
                  (fixture.microNM*0.001/fixture.pixelUM>0.05)==fixture.microEnabled
            else {fatalError("Upstream source grain geometry/metadata mismatch")}
            let expectedLayers=try load(directory,fixture,"sublayers")
            let expectedClouds=try load(directory,fixture,"dyeClouds")
            let expectedMicro=try load(directory,fixture,"microstructure")
            let expectedFinal=try load(directory,fixture,"final")
            guard expectedLayers.count==n*9,
                  expectedClouds.count==n*3,
                  expectedMicro.count==n*3,
                  expectedFinal.count==n*3
            else {fatalError("Original grain.py source frame shape mismatch")}
            let fraction=(0..<9).map { i -> Double in
                let ch=i%3
                let total=fixture.maxima[ch]+fixture.maxima[ch+3]+fixture.maxima[ch+6]
                return fixture.maxima[i]/total
            }
            let density=(0..<n*3).map { k -> Double in
                let p=k/3,ch=k%3
                return 0.12+0.015*Double((p+ch*4)%9)
            }
            var snapshots=[String:[Double]]()
            let settings=OriginalSourcePhysicalGrain.Settings(
                active:true,grainBlur:fixture.finalBlur,
                dyeCloudBlurUM:fixture.dyeBlur,
                microstructureUM:fixture.microUM,
                microstructureNM:fixture.microNM,
                numbaSeed:manifest.numba_seed
            )
            let got=try OriginalSourcePhysicalGrain.apply(
                density,width:fixture.width,height:fixture.height,
                pixelUM:fixture.pixelUM,
                measured:.init(
                    maxima:fixture.maxima,
                    sublayers:{ input in
                        (0..<9).map { i in
                            input[i%3]*fraction[i]
                        }
                    }
                ),
                settings:settings,
                stageObserver:{ name,values in snapshots[name]=values }
            )
            // Source unmodified Python order: measured 3x3 -> SciPy draws
            // all Poisson then all Binomial per sublayer -> cloud blur ->
            // Numba lognormal per channel -> final grain blur.
            check(snapshots["sourceGrainSublayers"] ?? [],expectedLayers,
                  fixture.name+"/3x3 input",atol:1e-13)
            check(snapshots["sourceGrainDyeClouds"] ?? [],expectedClouds,
                  fixture.name+"/dye clouds",atol:1e-8)
            check(snapshots["sourceGrainMicrostructure"] ?? [],expectedMicro,
                  fixture.name+"/Numba microstructure",atol:1e-8)
            check(got,expectedFinal,fixture.name+"/final density",atol:1e-8)
            let repeated=try OriginalSourcePhysicalGrain.apply(
                density,width:fixture.width,height:fixture.height,
                pixelUM:fixture.pixelUM,
                measured:.init(maxima:fixture.maxima,
                               sublayers:{ input in
                    (0..<9).map { i in input[i%3]*fraction[i] }
                }),
                settings:settings
            )
            guard repeated.map(\.bitPattern)==got.map(\.bitPattern) else {
                fatalError("Controlled original 3x3 grain output is not deterministic")
            }
        }
        // The original image must stay unchanged with the module disabled.
        var inactive=OriginalSourcePhysicalGrain.Settings()
        inactive.active=false
        let unchanged=try OriginalSourcePhysicalGrain.apply(
            [0.2,0.3,0.4],width:1,height:1,pixelUM:1,
            measured:.init(maxima:[Double](repeating:0.5,count:9),
                           sublayers:{_ in [Double](repeating:0.1,count:9)}),
            settings:inactive
        )
        guard unchanged==[0.2,0.3,0.4] else {
            fatalError("Disabled source grain modified baseline image")
        }
        var noSeed=OriginalSourcePhysicalGrain.Settings()
        noSeed.active=true
        do {
            try noSeed.validate()
            fatalError("Missing Numba seed silently accepted")
        } catch OriginalSourcePhysicalGrain.Failure.invalid {
            print("PASS original grain fail-closed: missing Numba seed rejected")
        }
        print("PASS: 3 original-source full-field 9-sublayer numeric fixtures, controlled seeded Numba and SciPy, independent stage checks")
        print("NOT CERTIFIED: unseeded multi-thread Numba prange, arbitrary RAW/JPEG, original source full RGB photo parity")
    }
}
