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
        let useFastStats:Bool?
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
        guard manifest.cases.count==5,manifest.numba_seed==8888,
              manifest.scope.contains("unmodified original grain.py") else {
            throw Failure.invalid("No original Python grain.py full-frame reference")
        }
        // Actual production coefficient preparation vs old scalar formula.
        // Cover inactive boundary, next representable active value, signed
        // zero normals, realistic micro sizes, underflow and invalid inputs.
        var preparedChecks=0
        for std:Double in [0,0.05,Double(0.05).nextUp,0.06,0.5,1,10,1e150] {
            let prepared=try OriginalSourceMicrostructure.PreparedLognormal(microStd:std)
            for z:Double in [-100,-8,-1,-0.0,0.0,0.125,1,8] {
                let reference=try OriginalSourceMicrostructure.lognormal(microStd:std,z:z)
                let actual=try prepared.sample(z:z)
                guard actual.bitPattern==reference.bitPattern else {
                    throw Failure.invalid("Prepared lognormal changed Float64 bits std=\(std) z=\(z)")
                }
                preparedChecks+=1
            }
        }
        let prepared=try OriginalSourceMicrostructure.PreparedLognormal(microStd:1)
        for z in [Double.nan,Double.infinity,1000] {
            do {
                _=try prepared.sample(z:z)
                throw Failure.invalid("Prepared lognormal accepted invalid/overflow sample")
            } catch OriginalSourceMicrostructure.Failure.invalid {}
        }
        print("PASS Build147-C prepared lognormal: \(preparedChecks) exact Float64 comparisons plus invalid/overflow samples")
        // Exercise exact production SIMD helpers separately from the
        // Python full-stage regression below. All remainder sizes, signed
        // zero, subnormal, normal and negative values; no approximate compare.
        let values:[Double]=[-0.0,0,Double.leastNonzeroMagnitude,
            -Double.leastNonzeroMagnitude,Double.leastNormalMagnitude,
            -1,0.03125,0.5,2.0,1e100,-1e100]
        let factors:[Double]=[0,-0.0,0.5,1,1.25,2,Double.leastNormalMagnitude]
        let minimum:[Double]=[-0.0,0.03125,0.125]
        var simdChecks=0
        for pixels in 0...17 {
            let input=(0..<(pixels*3)).map{values[$0%values.count]}
            let clump=input.indices.map{factors[$0%factors.count]}
            var scalar=input
            for i in scalar.indices {scalar[i]*=clump[i]}
            var vector=input
            try OriginalSourcePhysicalGrain.multiplyMicrostructureSIMD(&vector,clump)
            guard vector.map(\.bitPattern)==scalar.map(\.bitPattern) else {
                throw Failure.invalid("Build148-D microstructure SIMD bit mismatch")
            }
            simdChecks+=scalar.count
            for i in scalar.indices {scalar[i]-=minimum[i%3]}
            try OriginalSourcePhysicalGrain.subtractDensityMinSIMD(&vector,minimum)
            guard vector.map(\.bitPattern)==scalar.map(\.bitPattern) else {
                throw Failure.invalid("Build148-D minimum density SIMD bit mismatch")
            }
            simdChecks+=scalar.count
        }
        print("PASS Build148-D exact independent Float64 SIMD \(simdChecks) components")
        var checked=0
        var worst=0.0
        for sample in manifest.cases {
            let w=sample.width,h=sample.height
            let maxima=sample.maxima
            guard maxima.count==9,
                  (sample.microNM*0.001/sample.pixelUM>0.05)==sample.microEnabled else {
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
            settings.useFastStats=sample.useFastStats ?? false
            settings.fastStatsSeed=settings.useFastStats ? manifest.numba_seed : nil
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
            // Observed path retains the allocating Gaussian reference;
            // unobserved production uses the exact in-place implementation.
            guard repeated.map(\.bitPattern)==actual.map(\.bitPattern),
                  actual != density else {
                throw Failure.invalid("Build147-C observed reference vs unobserved production grain bit mismatch")
            }
            print("PASS Build147-C observed/production grain \(sample.name): exact Float64 bits")
            // Exercise the actual no-observer production channel branch
            // independently of the existing all-nine Python stage oracle.
            var channelMeasured=measured
            var calls=[0,0,0]
            channelMeasured.channelSublayersInto={ rgb,ch,output in
                calls[ch]+=1
                let total=maxima[ch]+maxima[3+ch]+maxima[6+ch]
                for sl in 0..<3 {
                    output[sl*3+ch]=rgb[ch]*maxima[sl*3+ch]/total
                }
            }
            let channelOnly=try OriginalSourcePhysicalGrain.apply(
                density,width:w,height:h,pixelUM:sample.pixelUM,
                measured:channelMeasured,settings:settings
            )
            guard calls==[w*h,w*h,w*h],
                  channelOnly.map(\.bitPattern)==repeated.map(\.bitPattern) else {
                throw Failure.invalid("OPT channel-only measured inversion changed seeded grain bits or invocation count")
            }
            print("PASS OPT channel-only grain \(sample.name): \(calls), bitwise identical final density")
            settings.numbaSeed=nil
            if settings.useFastStats {
                var missingCountsSeed=settings
                missingCountsSeed.fastStatsSeed=nil
                do {
                    _=try OriginalSourcePhysicalGrain.apply(
                        density,width:w,height:h,pixelUM:sample.pixelUM,
                        measured:measured,settings:missingCountsSeed
                    )
                    throw Failure.invalid("Missing Numba fast_counts seed silently accepted")
                } catch OriginalSourcePhysicalGrain.Failure.invalid {}
            }
            if sample.microEnabled {
                // Source active lognormal needs an explicit controlled
                // worker seed; never invent a production random stream.
                do {
                    _=try OriginalSourcePhysicalGrain.apply(
                        density,width:w,height:h,pixelUM:sample.pixelUM,
                        measured:measured,settings:settings
                    )
                    throw Failure.invalid("Missing active Numba seed silently accepted")
                } catch OriginalSourcePhysicalGrain.Failure.invalid {}
            } else {
                // Upstream add_micro_structure() short-circuits when
                // 0.001 * microNM / pixelUM <= 0.05; no Numba draw occurs.
                let seedFree=try OriginalSourcePhysicalGrain.apply(
                    density,width:w,height:h,pixelUM:sample.pixelUM,
                    measured:measured,settings:settings
                )
                guard seedFree==actual else {
                    throw Failure.invalid("Inactive microstructure changed the SciPy source field without Numba seed")
                }
            }
        }
        print("PASS original Python grain.py source 3x3 production DENSITY: \(manifest.cases.count) whole-frame fixtures (including original fast_stats both micro branches), \(checked) stage channels, max Float64 discrepancy=\(worst), controlled seed 8888 reproducibility, seed-free inactive-micro and missing-seed fail-closed.")
        print("NOT CERTIFIED: unseeded prange multiworker RNG, RAW, real iPhone full-display RGB original matching.")
    }
}
