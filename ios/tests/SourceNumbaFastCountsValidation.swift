import Foundation

/// Exact-source one-worker diagnostics, NOT production Numba prange parity.
@main
struct SourceNumbaFastCountsValidation {
    // Frozen Build148 inversion, including its cap and source k-1.
    // Intentionally executes every iteration; no absorbing-state shortcut.
    private static func legacyInversion(_ n:Int64,_ p:Double,_ u:Double)throws->Int64 {
        var cdf=0.0
        var prob=pow(1.0-p,Double(n))
        var k:Int64=0
        while cdf<u && k<=n {
            guard k<2_000_000 else {
                throw OriginalSourceNumbaFastCounts.Failure.invalid(
                    "Numba fast_binomial: inversion exceeded safety cap")
            }
            cdf+=prob
            if k<n {prob=prob*(Double(n-k)/Double(k+1))*(p/(1.0-p))}
            k+=1
        }
        return k-1
    }

    private static func inversionParity()throws {
        let pairs:[(Int64,Double)]=[
            (25,0.01),(25,0.5),(25,0.999999),
            (100,0.1),(100,0.9),(100,0.999999),
            (1000,0.001),(1000,0.99),(1000,0.999),
            (10000,0.0001),(10000,0.999999),
            (1_999_999,0.999999),(2_000_000,0.999999),
            (2_000_001,0.999999),(Int64.max,Double(1).nextDown)
        ]
        var checked=0
        for (n,p) in pairs where Double(n)*p*(1.0-p)<=10 {
            for u:Double in [0,Double.leastNonzeroMagnitude,0.001,0.5,0.999999,Double(1).nextDown] {
                // Compare success or exact error text, not just an error flag.
                let expected=Result {try legacyInversion(n,p,u)}
                let actual=Result {try OriginalSourceNumbaFastCounts.invertSmallVariance(n,probability:p,uniform:u)}
                switch (expected,actual) {
                case (.success(let a),.success(let b)): precondition(a==b)
                case (.failure(let a),.failure(let b)):
                    precondition(a.localizedDescription==b.localizedDescription)
                default: fatalError("Absorbing probability changed inversion result")
                }
                checked+=1
            }
        }
        // Real RNG consumption: compare against a separate seeded Numba
        // generator that draws exactly once then executes the frozen loop.
        for seed:UInt32 in [0,1,8888,UInt32.max] {
            var actual=OriginalSourceNumbaFastCounts(seed:seed)
            var legacy=OriginalSourceNumbaSingleThreadNormal(seed:seed)
            let streamPairs:[(Int64,Double)]=[(1000,0.999),(100,0.1),(10000,0.999999),(1000,0.001)]
            for (n,p) in streamPairs {
                let expected=try legacyInversion(n,p,legacy.nextUniform())
                let got=try actual.fastBinomial(n,probability:p)
                precondition(got==expected)
                var probe=legacy
                precondition(actual.peekNextUniform().bitPattern==probe.nextUniform().bitPattern)
                let x=try actual.nextMicrostructureNormal()
                let y=try legacy.nextNormal()
                precondition(x.bitPattern==y.bitPattern)
            }
        }
        // The old cap must still fail after the same one uniform draw.
        var actual=OriginalSourceNumbaFastCounts(seed:8888)
        var legacy=OriginalSourceNumbaSingleThreadNormal(seed:8888)
        _=legacy.nextUniform()
        do {
            _=try actual.fastBinomial(2_000_000,probability:0.999999)
            fatalError("Inversion cap bypassed")
        } catch OriginalSourceNumbaFastCounts.Failure.invalid {}
        precondition(actual.peekNextUniform().bitPattern==legacy.nextUniform().bitPattern)
        print("PASS Build149-A absorbing zero inversion \(checked) frozen-loop cases, exact uniform/normal stream and cap")
    }

    static func main() throws {
        try inversionParity()
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
        var reused=[Int64]()
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

            var countsOnly=OriginalSourceNumbaFastCounts(seed:fixture.seed)
            let optimized=try countsOnly.runOriginalTwoPhaseCounts(
                rates:fixture.rates,probabilities:fixture.probabilities
            )
            guard optimized==actual.binomial,
                  countsOnly.peekNextUniform().bitPattern==actual.afterBinomial.bitPattern else {
                fatalError("OPT in-place source Numba count/next RNG mismatch")
            }
            // Continuous worker state across two full layers; check
            // exact counts, next uniform and cached normal against the
            // original allocating implementation, with poisoned scratch.
            var reusableEngine=OriginalSourceNumbaFastCounts(seed:fixture.seed)
            var allocatingEngine=OriginalSourceNumbaFastCounts(seed:fixture.seed)
            for _ in 0..<2 {
                for i in reused.indices {reused[i] = Int64.min}
                let reference=try allocatingEngine.runOriginalTwoPhaseCounts(
                    rates:fixture.rates,probabilities:fixture.probabilities
                )
                try reusableEngine.runOriginalTwoPhaseCountsInto(
                    rates:fixture.rates,probabilities:fixture.probabilities,counts:&reused
                )
                guard reused==reference,
                      reusableEngine.peekNextUniform().bitPattern==allocatingEngine.peekNextUniform().bitPattern else {
                    fatalError("Reused Numba counts or next uniform diverged")
                }
                let a=try reusableEngine.nextMicrostructureNormal()
                let b=try allocatingEngine.nextMicrostructureNormal()
                precondition(a.bitPattern==b.bitPattern)
            }
            // Independent offset interval compared with copied slice,
            // including subsequent normal-cache state.
            let lo=fixture.rates.count/4,hi=fixture.rates.count*3/4
            var rangeEngine=OriginalSourceNumbaFastCounts(seed:fixture.seed)
            var sliceEngine=OriginalSourceNumbaFastCounts(seed:fixture.seed)
            let rangeCounts=try rangeEngine.runOriginalTwoPhaseCounts(
                rates:fixture.rates,probabilities:fixture.probabilities,range:lo..<hi
            )
            let sliceCounts=try sliceEngine.runOriginalTwoPhase(
                rates:Array(fixture.rates[lo..<hi]),
                probabilities:Array(fixture.probabilities[lo..<hi])
            )
            guard rangeCounts==sliceCounts.binomial,
                  rangeEngine.peekNextUniform().bitPattern==sliceCounts.afterBinomial.bitPattern else {
                fatalError("OPT Numba worker range changed source sequence")
            }
            let rangeNormal=try rangeEngine.nextMicrostructureNormal()
            let sliceNormal=try sliceEngine.nextMicrostructureNormal()
            precondition(rangeNormal.bitPattern==sliceNormal.bitPattern)
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
