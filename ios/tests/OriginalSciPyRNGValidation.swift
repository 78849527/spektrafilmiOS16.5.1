import Foundation

/// NumPy RandomState -> SciPy legacy distribution golden fixtures.
/// Float64 probabilities and rates must be used; producer must consume
/// the ENTIRE Poisson array before ANY binomial draw.
@main
struct OriginalSciPyRNGValidation {
    static func main() throws {
        setbuf(stdout, nil)
        let cases = GeneratedOriginalSciPyRNGReference.cases
        precondition(cases.count >= 5)
        var count: Int = 0
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
            print("PASS: original SciPy two-stage count/MT stream \(sample.name), pixels=\(n)")
            count += n
        }
        print("PASS: \(cases.count) SciPy/NumPy legacy fixtures, \(count) Poisson + \(count) Binomial counts, exact next MT words.")
        print("NOT CERTIFIED: Numba microstructure RNG, float64 shader parity and production full-frame image still pending.")
    }
}
