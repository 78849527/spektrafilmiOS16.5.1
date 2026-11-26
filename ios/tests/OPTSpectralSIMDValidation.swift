import Foundation

@main
struct OPTSpectralSIMDValidation {
    static func main() {
        var cases=0
        for n in [1,3,17,81] {
            for salt in 0..<48 {
                for scan in [false,true] {
                    var ref=[0.0,0.0,0.0]
                    var simd=SIMD3<Double>(repeating:0.0)
                    for i in 0..<n {
                        if (i+salt)%11==0 && n>1 {continue}
                        let weights=(0..<3).map { c -> Double in
                            if (i+c+salt)%13==0 {return -0.0}
                            return Double((i*17+c*11+salt*7)%127-63)/37.0
                        }
                        let transmission=(i+salt)%17==0 ? 0.0 :
                            pow(10.0, -Double((i*5+salt)%91-20)/19.0)
                        for c in 0..<3 {
                            ref[c] += scan ? transmission*weights[c] : weights[c]*transmission
                        }
                        if scan {
                            SourceSpectralTriplet.scanAccumulate(&simd,weights:weights,
                                                                 transmission:transmission)
                        } else {
                            SourceSpectralTriplet.printAccumulate(&simd,weights:weights,
                                                                  transmission:transmission)
                        }
                        precondition(SourceSpectralTriplet.channels(simd).map{$0.bitPattern}
                                     == ref.map{$0.bitPattern},"spectral SIMD lane/order mismatch")
                    }
                    cases += 1
                }
            }
        }
        var preparedCases=0
        for n in [1,3,17,81] {
            for salt in 0..<48 {
                let valid=(0..<n).filter { ($0+salt)%11 != 0 || n==1 }
                let rows=valid.map { i -> SourcePreparedSpectralSum.Row in
                    let base=Double((i*7+salt)%23-11)/37.0
                    let a=Double((i*3+salt)%37-18)/17.0
                    let b=Double((i*5+salt)%41-20)/19.0
                    let c=Double((i*9+salt)%43-21)/23.0
                    let weights=SIMD3<Double>(Double(i+1)/81.0,-Double(i)/83.0,
                                             (i+salt)%7==0 ? -0.0 : 0.125)
                    return .init(base:base,dye0:a,dye1:b,dye2:c,weights:weights)
                }
                let plan=SourcePreparedSpectralSum(rows:rows)
                let density=[Double(salt%11)/9.0,-0.05,Double(salt%17)/13.0]
                for scan in [false,true] {
                    for clamp in [false,true] {
                        var ref=[0.0,0.0,0.0]
                        for row in rows {
                            var d=row.base
                            let dyes=[row.dye0,row.dye1,row.dye2]
                            for c in 0..<3 {d += dyes[c]*density[c]}
                            let transmitted=pow(10.0,-(clamp ? max(0,d) : d))
                            for c in 0..<3 {
                                ref[c] += scan ? transmitted*row.weights[c] : row.weights[c]*transmitted
                            }
                        }
                        let result=plan.evaluate(density,clampDensity:clamp,scan:scan)
                        precondition(result.map{$0.bitPattern}==ref.map{$0.bitPattern},
                                     "OPT prepared spectral sum changed source bits")
                        preparedCases+=1
                    }
                }
            }
        }
        var intervals=0
        let axes:[[Double]] = [
            [-2,-1,0,1,2],
            [-2,-1,-1,0,1],
            [3,2,1,0,-1],
            [-0.0,0.0,0.25,0.75],
            [0,0.03,0.1,0.2,0.9]
        ]
        for axis in axes {
            let plan=SourcePreparedHDIntervals.prepare(axis)
            for lower in 0..<(axis.count-1) {
                let dx=axis[lower+1]-axis[lower]
                for ratio in [-0.0,0.0,0.125,0.37,0.5,0.999,1.0] {
                    let x=axis[lower]+ratio*dx
                    let expected=(x-axis[lower])*(dx == 0 ? 0.0 : 1.0/dx)
                    let actual=SourcePreparedHDIntervals.fraction(x,axis:axis,lower:lower,prepared:plan)
                    precondition(expected.bitPattern==actual.bitPattern,"OPT H-D reciprocal mismatch")
                    intervals+=1
                }
            }
        }
        print("PASS OPT prepared H-D intervals \(intervals) bitwise")
        print("PASS OPT prepared spectral sum \(preparedCases) cases, scalar bitwise")
        print("PASS OPT spectral SIMD \(cases) ordered accumulation cases, bitwise every wavelength")
    }
}
