import Foundation

@main
enum Build90OriginalLUTSourceValidation {
    enum Failure:Error {case invalid(String)}
    static func array(_ row:[String:Any],_ key:String)throws->[Double] {
        guard let v=row[key] as? [NSNumber] else {
            throw Failure.invalid("Missing original Numba LUT Float64 "+key)
        }
        return v.map{$0.doubleValue}
    }
    static func shape(_ row:[String:Any],_ key:String)throws->[[Double]] {
        guard let v=row[key] as? [[NSNumber]] else {
            throw Failure.invalid("Missing source Numba pixel table "+key)
        }
        return v.map{$0.map{$0.doubleValue}}
    }
    static func main()throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need source Numba PCHIP/Mitchell oracle")
        }
        let d=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:d) as? [String:Any],
              let records=root["records"] as? [[String:Any]],
              records.count==8 else {
            throw Failure.invalid("Missing original 8-source LUT tables")
        }
        var worstPCHIP=0.0,worstMitchell=0.0
        var total=0,overshoot=0,oneNode=0,nonmono=0
        for (n,row) in records.enumerated() {
            guard let count=row["size"] as? Int,
                  let kind=row["kind"] as? String else {
                throw Failure.invalid("Missing original source LUT size")
            }
            let lut=try Build90OriginalLUT.Prepared(
                size:count,values:try array(row,"samples"),
                revision:"original:\(n)",
                minimum:try array(row,"minimum"),
                maximum:try array(row,"maximum")
            )
            let input=try shape(row,"input")
            for (method,label) in [
                (Build90OriginalLUT.Method.pchip,"pchip"),
                (.mitchell,"mitchell")
            ] {
                let expected=try shape(row,label)
                if count==1 && method == .pchip {
                    // True Python original raises a ValueError before
                    // its size=1 PCHIP constant special-case.
                    guard expected.isEmpty else {
                        throw Failure.invalid(
                            "Source 1-node PCHIP unexpectedly valid"
                        )
                    }
                    do {
                        _=try lut.sample(input[0],method:method)
                        throw Failure.invalid(
                            "Native 1node PCHIP ignored source ValueError"
                        )
                    } catch Build90OriginalLUT.Failure.invalid(_) {}
                    continue
                }
                guard expected.count==input.count else {
                    throw Failure.invalid("Source LUT image dimensions changed")
                }
                let all=try lut.applyImage(input.flatMap{$0},method:method)
                for pixel in input.indices {
                    let sample=try lut.sample(input[pixel],method:method)
                    for ch in 0..<3 {
                        let actual=sample[ch]
                        let delta=abs(actual-expected[pixel][ch])
                        let imageDelta=abs(actual-all[pixel*3+ch])
                        guard delta.isFinite,delta<=4e-12,
                              imageDelta<=1e-15 else {
                            throw Failure.invalid(
                                "True source \(label) table \(n) pixel \(pixel) " +
                                "ch \(ch): native \(actual) Python " +
                                "\(expected[pixel][ch]) delta \(delta)"
                            )
                        }
                        if method == .pchip {
                            worstPCHIP=max(worstPCHIP,delta)
                        } else {
                            worstMitchell=max(worstMitchell,delta)
                        }
                        total+=1
                    }
                }
            }
            if count==1 {oneNode+=1}
            if kind=="nonmonotone" {nonmono+=1}
            if input.contains(where:{pixel in
                let minimum=lut.minDomain,maximum=lut.maxDomain
                return (0..<3).contains(where:{
                    pixel[$0]<minimum[$0] || pixel[$0]>maximum[$0]
                })
            }) {overshoot+=1}
            // Cache identity is explicit; changing source domain/revision
            // must construct a NEW Prepared, never reuse old samples.
            if count==2 {
                let rebuilt=try Build90OriginalLUT.Prepared(
                    size:count,values:lut.values.map{$0+0.07},
                    revision:"changed:\(n)",
                    minimum:lut.minDomain,maximum:lut.maxDomain
                )
                let old=try lut.sample(input[4])
                let new=try rebuilt.sample(input[4])
                guard old != new else {
                    throw Failure.invalid("LUT revision invalidation reused stale table")
                }
            }
        }
        guard total==672,oneNode==2,nonmono==4,overshoot==8 else {
            throw Failure.invalid("Original 672 certified LUT channels missing")
        }
        print("PASS BUILD90 ACTUAL SOURCE NUMBA LUT: 8 original " +
              "PCHIP/Mitchell tables, sizes 1/2/5/7, custom " +
              "domains+overshoot+reflect bounds, 672 Float64 " +
              "channel checks; PCHIP max \(worstPCHIP), " +
              "Mitchell max \(worstMitchell), tol 4e-12; " +
              "explicit cache-revision rebuild verified.")
    }
}
