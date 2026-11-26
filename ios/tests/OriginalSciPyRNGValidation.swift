import Foundation

/// NumPy RandomState -> SciPy legacy distribution golden fixtures.
/// Float64 probabilities and rates must be used; producer must consume
/// the ENTIRE Poisson array before ANY binomial draw.
@main
struct OriginalSciPyRNGValidation {
    // Frozen pre-optimization modulo recurrence. Long-stream comparison
    // crosses both wrapped ranges and multiple twist/copy boundaries.
    private struct ModuloMT {
        var state=[UInt32](repeating:0,count:624)
        var index=624
        init(seed:UInt32) {
            state[0]=seed
            for i in 1..<624 {
                let previous=state[i-1]
                state[i]=1_812_433_253 &* (previous ^ (previous >> 30)) &+ UInt32(i)
            }
        }
        mutating func next()->UInt32 {
            if index==624 {
                for i in 0..<624 {
                    let y=(state[i] & 0x8000_0000) |
                        (state[(i+1)%624] & 0x7fff_ffff)
                    state[i]=state[(i+397)%624] ^ (y >> 1) ^
                        ((y & 1)==0 ? 0 : 0x9908_b0df)
                }
                index=0
            }
            var y=state[index]
            index+=1
            y ^= y >> 11
            y ^= (y << 7) & 0x9d2c_5680
            y ^= (y << 15) & 0xefc6_0000
            y ^= y >> 18
            return y
        }
    }
    static func main() throws {
        setbuf(stdout, nil)
        for seed:UInt32 in [0,1,8888,UInt32.max] {
            var original=ModuloMT(seed:seed)
            var optimized=OriginalSourceMT19937(seed:seed)
            for i in 0..<100_000 {
                if i%624==623 {
                    var copy=optimized
                    var expected=original
                    for _ in 0..<3 {
                        precondition(copy.nextUInt32()==expected.next(),"MT copy across twist differs")
                    }
                }
                precondition(optimized.nextUInt32()==original.next(),"MT long-stream mismatch")
            }
        }
        print("PASS Build148-C MT19937 400000 words and independent copy across twists")
        let cases = GeneratedOriginalSciPyRNGReference.cases
        precondition(cases.count >= 5)
        var count: Int = 0
        var reused=[Int64]()
        for sample in cases {
            let n = sample.rates.count
            precondition(n == sample.probabilities.count &&
                         n == sample.poisson.count &&
                         n == sample.binomial.count)
            var rng = OriginalSourceSciPySampler(seed: sample.seed)
            var seeds = [Int64]()
            seeds.reserveCapacity(n)
            for i in 0..<n {
                let value = try rng.poisson(sample.rates[i])
                precondition(
                    value == sample.poisson[i],
                    "SciPy Poisson mismatch \(sample.name) element \(i): " +
                    "Swift \(value) source \(sample.poisson[i])"
                )
                seeds.append(value)
            }
            var afterPoisson = rng
            precondition(
                afterPoisson.nextUInt32() == sample.nextAfterPoisson,
                "Source SciPy Poisson MT consumption differs: \(sample.name)"
            )
            for i in 0..<n {
                let value = try rng.binomial(
                    seeds[i], probability: sample.probabilities[i]
                )
                precondition(
                    value == sample.binomial[i],
                    "SciPy Binomial mismatch \(sample.name) element \(i): " +
                    "Swift \(value) source \(sample.binomial[i])"
                )
            }
            precondition(
                rng.nextUInt32() == sample.nextAfterBinomial,
                "Source SciPy Binomial MT consumption differs: \(sample.name)"
            )
            let composite = try OriginalSourceSciPySampler.drawLayer(
                rates: sample.rates, probabilities: sample.probabilities,
                seed: sample.seed
            )
            precondition(
                composite == sample.binomial,
                "Source 2-array Poisson→Binomial ordering differs"
            )
            // Poison the previously used count storage, including
            // equal-sized consecutive arrays and resized fixtures.
            for _ in 0..<2 {
                for i in reused.indices {reused[i] = Int64.min}
                try OriginalSourceSciPySampler.drawLayerInto(
                    rates:sample.rates,probabilities:sample.probabilities,
                    seed:sample.seed,counts:&reused
                )
                precondition(reused==sample.binomial,"Reused SciPy counts diverged")
            }
            print("PASS: original SciPy two-stage count/MT stream \(sample.name), pixels=\(n)")
            count += n
        }
        print("PASS: \(cases.count) SciPy/NumPy legacy fixtures, \(count) Poisson + \(count) Binomial counts, exact next MT words.")
        print("NOT CERTIFIED: Numba microstructure RNG, float64 shader parity and production full-frame image still pending.")
    }
}
