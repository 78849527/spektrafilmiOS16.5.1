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
        print("PASS OPT spectral SIMD \(cases) ordered accumulation cases, bitwise every wavelength")
    }
}
