import Foundation

// These two stubs satisfy unrelated Build82 profile/UV symbols ONLY.
// The tested function IS the real production
// Build82OriginalSpectralRuntime.bakeOriginalXYGamut() implementation.
enum Build82GeneratedHanatosProfiles {
    static let sourceSHA256="unused-by-TC-bake"
}
enum OriginalSourceCameraBandpass {
    struct Settings {
        func validate() throws {}
    }
    static func transmission(wavelengthNM:Double,settings:Settings)->Double {
        return 1.0
    }
}

@main
enum FinalOriginalTCLUTValidation {
    enum Failure:Error {case invalid(String)}
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("missing source original TC remap oracle")
        }
        let raw=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard let data=try JSONSerialization.jsonObject(with:raw)
                 as? [String:Any],
              data["gamutBlob"] as? String=="9783e7fcfc2909c4acdf2da53595c5404645dde9",
              data["spectralBlob"] as? String=="bb75f8a00d00eb02ba571c6cfdbec88a8c0194cb",
              let cases=data["cases"] as? [[String:Any]],
              cases.count==4 else {
            throw Failure.invalid("original Python tc remap source SHA/scope changed")
        }
        let coordinate=Build82OriginalHanatosSurface.Point(
            x:0.3127,y:0.3290
        )
        var total=0,maximum=0.0
        var seen=Set<String>()
        for item in cases {
            guard let side=item["side"] as? Int,
                  let algorithm=item["algorithm"] as? String,
                  let original=item["original"] as? [NSNumber],
                  let expected=item["expected"] as? [NSNumber],
                  let name=item["name"] as? String,
                  (side==12 || side==23),
                  original.count==side*side*3,
                  expected.count==original.count else {
                throw Failure.invalid("source TC LUT test malformed")
            }
            let algo:Build81OriginalInputGamut.Algorithm
            switch algorithm {
            case "xy":algo = .xy
            case "oklch":algo = .oklch
            default:throw Failure.invalid("unsupported original TC branch")
            }
            let result=try Build82OriginalSpectralRuntime
                .bakeOriginalXYGamut(
                    original.map{$0.doubleValue},
                    side:side,referenceXY:coordinate,algorithm:algo
                )
            guard result.count==expected.count else {
                throw Failure.invalid("native TC table shape drift")
            }
            for i in result.indices {
                let delta=abs(result[i]-expected[i].doubleValue)
                guard delta.isFinite,delta<=0.00001 else {
                    throw Failure.invalid(
                        "\(name) cell \(i) native \(result[i]) "
                        + "Python \(expected[i]) error=\(delta)"
                    )
                }
                total+=1
                maximum=max(maximum,delta)
            }
            seen.insert(name)
        }
        guard total==(12*12+23*23)*3*2,seen.count==4 else {
            throw Failure.invalid("incomplete original TC fixtures")
        }
        print("PASS ORIGINAL Hanatos TC table SOURCE xy + Oklch: "
              + "\(total) Float64 channels across 12²/23² and 2 algorithms; "
              + "max abs \(maximum). 192² physical iPhone still NOT certified.")
    }
}
