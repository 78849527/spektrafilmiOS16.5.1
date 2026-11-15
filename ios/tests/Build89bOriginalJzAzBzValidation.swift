import Foundation

@main
enum Build89bOriginalJzAzBzValidation {
    enum Failure:Error {case invalid(String)}
    private static func vector(_ row:[String:Any],_ key:String)throws->[Double]{
        guard let nums=row[key] as? [NSNumber] else {
            throw Failure.invalid("Missing source JzAzBz "+key)
        }
        return nums.map{$0.doubleValue}
    }
    private static func compare(
        _ native:[Double],_ source:[Double],_ label:String,
        tolerance:Double=1e-9
    )throws->Double {
        guard native.count==source.count else {
            throw Failure.invalid(label+" shape mismatch")
        }
        var worst=0.0
        for i in native.indices {
            let delta=abs(native[i]-source[i])
            guard delta.isFinite,delta<=tolerance else {
                throw Failure.invalid(
                    "\(label) c\(i) native \(native[i]) vs source " +
                    "\(source[i]), delta \(delta), threshold \(tolerance)"
                )
            }
            worst=max(worst,delta)
        }
        return worst
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need original source 72 JzAzBz frame")
        }
        let raw=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:raw)
                as? [String:Any],
              let items=root["cases"] as? [[String:Any]],
              items.count==72 else {
            throw Failure.invalid("Missing source 72 original Jz cases")
        }
        var forwardMax=0.0,inverseMax=0.0,outputMax=0.0
        var wide=0,withoutLight=0
        for (i,row) in items.enumerated() {
            guard let space=row["space"] as? String else {
                throw Failure.invalid("Missing original output space")
            }
            let sourceXYZ=try vector(row,"sourceXYZ")
            let sourceJz=try vector(row,"sourceJz")
            let real=try Build89bOriginalJzAzBz.forward(sourceXYZ)
            forwardMax=max(forwardMax,try compare(
                real,sourceJz,"original PQ/Jz forward \(space) #\(i)"
            ))
            let back=try Build89bOriginalJzAzBz.inverse(real)
            inverseMax=max(inverseMax,try compare(
                back,try vector(row,"sourceInverseXYZ"),
                "original Jz inverse absolute XYZ \(space) #\(i)"
            ))
            let rgb=try vector(row,"rgb")
            let knee=try vector(row,"knee")
            let optional=(row["light"] as? [NSNumber])?.map{
                $0.doubleValue
            }
            let light:Build89OriginalOutputGamut.Knee?
            if let optional {
                light=Build89OriginalOutputGamut.Knee(
                    threshold:optional[0],limit:optional[1],
                    power:optional[2]
                )
            } else {
                light=nil;withoutLight+=1
            }
            let expected=try vector(row,"expected")
            let result=try Build89bOriginalJzAzBz.compress(
                rgb,space:space,
                knee:Build89OriginalOutputGamut.Knee(
                    threshold:knee[0],limit:knee[1],power:knee[2]
                ),lightness:light
            )
            outputMax=max(outputMax,try compare(
                result,expected,"original 64×720×18 Jz gamut \(space) #\(i)"
            ))
            if space != "sRGB" {wide+=1}
        }
        guard wide==48,withoutLight==36 else {
            throw Failure.invalid("Original wide Jz/lightness mode missing")
        }
        print(
            "PASS BUILD89B ORIGINAL JZAZBZ: 72 original Python source " +
            "full Float64 PQ/Safdar2017 64×720×18 Cmax vectors; " +
            "source forward Jz max=\(forwardMax), " +
            "inverse absolute XYZ max=\(inverseMax), " +
            "final RGB max=\(outputMax); threshold=1e-9; " +
            "3 output primaries, SDR 100 cd/m² white."
        )
    }
}
