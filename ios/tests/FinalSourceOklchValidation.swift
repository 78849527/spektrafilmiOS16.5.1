import Foundation

/// Original Python's independent spectral-locus Oklch source fixture.
@main
enum FinalSourceOklchValidation {
    enum Failure:Error {case invalid(String)}
    static func point(_ raw:[NSNumber])->Build81OriginalInputGamut.Point {
        .init(x:raw[0].doubleValue,y:raw[1].doubleValue)
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("missing pinned Python source Oklch oracle")
        }
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard let doc=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              doc["sourceBlob"] as? String=="9783e7fcfc2909c4acdf2da53595c5404645dde9",
              doc["colourVersion"] as? String=="0.4.6",
              let shape=doc["grid"] as? [NSNumber],
              shape.map({$0.intValue}) == [64,720,18],
              let items=doc["cases"] as? [[String:Any]],
              items.count==3 else {
            throw Failure.invalid("source Oklch manifest scope or SHA mismatch")
        }
        let white=Build81OriginalInputGamut.Point(x:0.3127,y:0.3290)
        var channels=0
        var maximum=0.0
        var maxByCase=[String:Double]()
        for item in items {
            guard let name=item["name"] as? String,
                  let k=item["knee"] as? [NSNumber],k.count==3,
                  let raw=item["input"] as? [[NSNumber]],
                  let expected=item["expected"] as? [[NSNumber]],
                  let inactive=item["inactive"] as? [[NSNumber]],
                  let polygon=item["locus"] as? [[NSNumber]],
                  expected.count==raw.count, raw.count==16 else {
                throw Failure.invalid("Oklch original source fixture malformed")
            }
            let xy=raw.map(point),boundary=polygon.map(point)
            let knee=Build81OriginalInputGamut.Knee(
                threshold:k[0].doubleValue,
                limit:k[1].doubleValue,power:k[2].doubleValue
            )
            let output=try Build81OriginalInputGamut.compress(
                xy,white:white,knee:knee,
                active:true,algorithm:.oklch,locus:boundary
            )
            let disabled=try Build81OriginalInputGamut.compress(
                xy,white:white,knee:knee,
                active:false,algorithm:.oklch,locus:boundary
            )
            var caseMaximum=0.0
            for i in xy.indices {
                let src=point(expected[i])
                let off=point(inactive[i])
                for pair in [
                    (output[i].x,src.x),(output[i].y,src.y)
                ] {
                    let delta=abs(pair.0-pair.1)
                    guard delta.isFinite,delta<=0.00002 else {
                        throw Failure.invalid(
                            "\(name) sample=\(i) observed=\(pair.0) "
                            + "source=\(pair.1) delta=\(delta); limit=0.00002"
                        )
                    }
                    caseMaximum=max(caseMaximum,delta)
                    maximum=max(maximum,delta)
                    channels+=1
                }
                guard disabled[i].x.bitPattern==off.x.bitPattern,
                      disabled[i].y.bitPattern==off.y.bitPattern else {
                    throw Failure.invalid("original inactive branch mutated bits")
                }
            }
            maxByCase[name]=max(caseMaximum,maxByCase[name] ?? 0)
        }
        guard channels==96, maxByCase.keys.count==2 else {
            throw Failure.invalid("incomplete Oklch CIE/custom coverage")
        }
        print(
            "PASS source input Oklch native Float64 96 channels "
            + "versus original Python; max abs=\(maximum); "
            + "64Lx720Hx18 bisect + CIE1931 and custom locus; "
            + "source production TC remap/image still NOT certified."
        )
    }
}
