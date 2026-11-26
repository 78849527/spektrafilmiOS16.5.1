import Foundation
@main struct OPTDeterministicPixelsValidation {
    enum E:Error {case injected(Int)}
    static func main() throws {
        for pixels in [1,3,32767,32768,32769,131073] {
            let source=(0..<(pixels*3)).map { Double(($0*13)%137-68)/31.0 }
            for hasAux in [false,true] {
                func transform(_ p:Int,_ v:[Double]) -> (rgb:[Double],auxiliary:[Double]?) {
                    let out=v.map { ($0*1.75+Double(p%31))*0.25 }
                    return (out,hasAux ? v.map { $0*0.75-0.125 } : nil)
                }
                var reference=source
                var refAux=hasAux ? Array(repeating:0.0,count:source.count) : []
                for p in 0..<pixels {
                    let k=p*3
                    let v=transform(p,Array(source[k..<k+3]))
                    for c in 0..<3 {
                        reference[k+c]=v.rgb[c]
                        if let a=v.auxiliary {refAux[k+c]=a[c]}
                    }
                }
                for workers in [1,2,3,4] {
                    var actual=source
                    var aux=hasAux ? Array(repeating:0.0,count:source.count) : []
                    try OPTDeterministicPixels.apply(&actual,auxiliary:&aux,workers:workers,transform:transform)
                    precondition(actual.map{$0.bitPattern}==reference.map{$0.bitPattern})
                    precondition(aux.map{$0.bitPattern}==refAux.map{$0.bitPattern})
                }
            }
        }
        var rgb=[Double](repeating:0,count:3*131073)
        var aux=[Double]()
        do {
            try OPTDeterministicPixels.apply(&rgb,auxiliary:&aux,workers:4) {p,v in
                if p==3 || p==32768 {throw E.injected(p)}
                return (v,nil)
            }
            preconditionFailure("worker error swallowed")
        } catch E.injected(let p) {precondition(p==3)}
        print("PASS OPT disjoint spans, 1/2/3/4 workers, uneven wave boundaries, auxiliary and deterministic failure")
    }
}
