import Foundation

/// Exact-source one-worker diagnostics, NOT production Numba prange parity.
@main
struct SourceNumbaFastCountsValidation {
    static func main() throws {
        let fixtures = GeneratedSourceNumbaFastCountsReference.cases
        guard fixtures.count == 3,
              GeneratedSourceNumbaFastCountsReference.fastStatsBlob.count == 40,
              GeneratedSourceNumbaFastCountsReference.grainBlob.count == 40
        else {
            fatalError("Source Numba fast_stats.py fixture missing")
        }
        var totalPoisson = 0
        var totalChainBinomial = 0
        var totalFixedBinomial = 0
        for fixture in fixtures {
            guard fixture.rates.count == fixture.probabilities.count,
                  fixture.poisson.count == fixture.rates.count,
                  fixture.binomial.count == fixture.rates.count,
                  fixture.fixedNs.count == fixture.fixedPs.count,
                  fixture.fixedNs.count == fixture.fixedBinomial.count
            else { fatalError("Source Numba fixture dimension mismatch") }

            var chain = OriginalSourceNumbaFastCounts(seed: fixture.seed)
            let actual = try chain.runOriginalTwoPhase(
                rates: fixture.rates, probabilities: fixture.probabilities
            )
            for (i, expected) in fixture.poisson.enumerated() {
                guard actual.poisson[i] == expected else {
                    fatalError(
                        "Numba source Poisson mismatch seed=\(fixture.seed) " +
                        "index=\(i) source=\(expected) Swift=\(actual.poisson[i])"
                    )
                }
            }
            for (i, expected) in fixture.binomial.enumerated() {
                guard actual.binomial[i] == expected else {
                    fatalError(
                        "Numba source Binomial mismatch seed=\(fixture.seed) " +
                        "index=\(i) source=\(expected) Swift=\(actual.binomial[i])"
                    )
                }
            }
            guard actual.afterPoisson.bitPattern ==
                    fixture.afterPoisson.bitPattern,
                  actual.afterBinomial.bitPattern ==
                    fixture.afterBinomial.bitPattern
            else {
                fatalError("Numba source two-phase MT19937 draw-count mismatch")
            }

            var fixed = OriginalSourceNumbaFastCounts(seed: fixture.seed &+ 1)
            for i in fixture.fixedNs.indices {
                let got = try fixed.fastBinomial(
                    fixture.fixedNs[i], probability: fixture.fixedPs[i]
                )
                guard got == fixture.fixedBinomial[i] else {
                    fatalError(
                        "Numba fixed branch mismatch seed=\(fixture.seed) " +
                        "index=\(i) n=\(fixture.fixedNs[i]) " +
                        "p=\(fixture.fixedPs[i]) " +
                        "source=\(fixture.fixedBinomial[i]) Swift=\(got)"
                    )
                }
            }
            guard fixed.peekNextUniform().bitPattern ==
                fixture.afterFixedBinomial.bitPattern
            else {
                fatalError("Numba fixed-branch MT19937 draw-count mismatch")
            }

            totalPoisson += fixture.poisson.count
            totalChainBinomial += fixture.binomial.count
            totalFixedBinomial += fixture.fixedBinomial.count
            print(
                "PASS: upstream Numba fast_stats.py one-worker seed=\(fixture.seed), " +
                "\(fixture.poisson.count) Poisson + \(fixture.binomial.count) " +
                "two-phase Binomial + \(fixture.fixedBinomial.count) " +
                "threshold Binomial, post-draw MT stream bit-identical"
            )
        }

        // Explicit negative-path guards; fail closed, never silently
        // substitute SciPy or a distribution-equivalent GPU PRNG.
        var invalid = OriginalSourceNumbaFastCounts(seed: 8888)
        do {
            _ = try invalid.fastPoisson(.nan)
            fatalError("Nonfinite source lambda accepted")
        } catch OriginalSourceNumbaFastCounts.Failure.invalid {}
        do {
            _ = try invalid.fastBinomial(-1, probability: 0.5)
            fatalError("Negative source n accepted")
        } catch OriginalSourceNumbaFastCounts.Failure.invalid {}
        do {
            _ = try invalid.runOriginalTwoPhase(rates: [1], probabilities: [])
            fatalError("Mismatched source arrays accepted")
        } catch OriginalSourceNumbaFastCounts.Failure.invalid {}

        print(
            "PASS: \(totalPoisson) original Poisson + " +
            "\(totalChainBinomial + totalFixedBinomial) original Binomial, " +
            "exact seeded one-worker draw consumption / threshold branches"
        )
        print(
            "NOT CERTIFIED: Numba unseeded prange workers, scheduling, " +
            "production grain GPU, Float64 whole RGB, real iPhone."
        )
    }
}
