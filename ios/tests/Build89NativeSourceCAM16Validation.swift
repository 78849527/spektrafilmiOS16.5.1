import Foundation

@main
enum Build89NativeSourceCAM16Validation {
    enum Failure:Error {case invalid(String)}
    static func doubles(_ item:[String:Any],_ field:String) throws->[Double] {
        guard let array=item[field] as? [NSNumber] else {
            throw Failure.invalid("Missing original Float64 "+field)
        }
        return array.map{$0.doubleValue}
    }
    static func compare(
        _ values:[Double],_ source:[Double],_ label:String,
        limit:Double
    ) throws->Double {
        guard values.count==source.count else {
            throw Failure.invalid(label+" source length mismatch")
        }
        var largest=0.0
        for i in values.indices {
            let delta=abs(values[i]-source[i])
            guard delta.isFinite,delta<=limit else {
                throw Failure.invalid(
                    "\(label) channel \(i): Swift \(values[i]) " +
                    "source Python \(source[i]); max \(delta) limit \(limit)"
                )
            }
            largest=max(largest,delta)
        }
        return largest
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Missing source CAM16-UCS Float64 oracle")
        }
        let data=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:data)
                as? [String:Any],
              let records=root["cases"] as? [[String:Any]],
              records.count==216,
              let valid=root["valid"] as? Int,
              valid>=180 else {
            throw Failure.invalid("Need 216 original CAM16 source cases")
        }
        var maxJab=0.0,maxRoundtrip=0.0,maxCompress=0.0
        var counted=0,nonFinite=0,wide=0,noLightness=0
        for (i,item) in records.enumerated() {
            guard let space=item["space"] as? String,
                  let unsupported=item["unsupported"] as? Bool else {
                throw Failure.invalid("Missing original CAM16 colourspace")
            }
            if unsupported {
                nonFinite+=1
                continue
            }
            let rgb=try doubles(item,"rgb")
            let input=try Build89OriginalCAM16.forward(rgb,space:space)
            maxJab=max(maxJab,try compare(
                [input.jp,input.ap,input.bp],
                try doubles(item,"sourceJab"),
                "CAM16UCS forward Float64 \(space) #\(i)",
                limit:3e-10
            ))
            let outXYZ=try Build89OriginalCAM16.inverse(
                input,space:space
            )
            // Compare the actual source CAM16 inverse XYZ→output RGB,
            // not an extra nonidentity colourspace roundtrip.
            maxRoundtrip=max(maxRoundtrip,try compare(
                outXYZ,try doubles(item,"sourceInverseRGB"),
                "original CAM16 inverse output RGB \(space) #\(i)",
                limit:3e-10
            ))
            let knee=try doubles(item,"knee")
            let optionalLight=(item["light"] as? [NSNumber])?.map{
                $0.doubleValue
            }
            let light: (Double,Double,Double)? = optionalLight.map {
                ($0[0],$0[1],$0[2])
            }
            if light==nil{noLightness+=1}
            if space != "sRGB" {wide+=1}
            let compressed=try Build89OriginalCAM16.compress(
                rgb,space:space,
                knee:(knee[0],knee[1],knee[2]),
                lightness:light
            )
            maxCompress=max(maxCompress,try compare(
                compressed,try doubles(item,"result"),
                "full ORIGINAL 64×720 18-bisect CAM16-UCS \(space) #\(i)",
                limit:3e-10
            ))
            counted+=1
        }
        guard counted==valid,wide>0,noLightness>0 else {
            throw Failure.invalid("Missing source CAM16 source variants")
        }
        print(
            "PASS BUILD89 TRUE NATIVE PER-PIXEL CAM16: " +
            "\(counted)/216 original source cases, 3 RGB output spaces, " +
            "64×720 Cmax and original 18 Float64 bisections, " +
            "4 knee/lightness modes; source J'a'b' max \(maxJab), " +
            "inverse RGB max \(maxRoundtrip), output RGB max \(maxCompress). " +
            "Unsupported source nonfinite cases \(nonFinite), never fallback."
        )
    }
}
