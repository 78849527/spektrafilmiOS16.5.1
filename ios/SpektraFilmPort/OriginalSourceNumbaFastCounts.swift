import Foundation

/// Source-algorithm implementation of Numba fast_stats.py fast_poisson()
/// and fast_binomial(), for diagnostic replay with ONE explicitly seeded
/// CPU worker. The source uses @njit(parallel=True) prange and does not seed
/// its independent Numba worker states in the default production pipeline.
///
/// This module is deliberately not wired to production Metal grain. Neither
/// Numba parallel worker scheduling nor iPhone Float32 GPU is certified.
///
/// Source branches, rounding, consumption and order:
///   Poisson: lambda<=0 =>0; lambda<30 Knuth product, else round(Normal)
///   Binomial: n<25 direct trials; else variance>10 => round(Normal);
///             otherwise source inversion loop (including k-1 return).
///   Array call: complete Poisson array before binomial array.
/// The source intentionally uses Normal APPROXIMATIONS at high parameters;
/// substituting SciPy's PTRS or BTPE would change the algorithm.
struct OriginalSourceNumbaFastCounts {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    private var rng: OriginalSourceNumbaSingleThreadNormal

    init(seed: UInt32) {
        rng = OriginalSourceNumbaSingleThreadNormal(seed: seed)
    }

    /// Read-only stream probe performed on a copy so inspecting the state
    /// cannot perturb the original two-array Poisson->Binomial sequence.
    func peekNextUniform() -> Double {
        var copy = rng
        return copy.nextUniform()
    }

    mutating func fastPoisson(_ lambda: Double) throws -> Int64 {
        guard lambda.isFinite else {
            throw Failure.invalid("Numba fast_poisson: non-finite lambda")
        }
        if lambda <= 0 { return 0 }
        if lambda < 30.0 {
            let limit = exp(-lambda)
            var probability = 1.0
            var count: Int64 = 0
            // The source has no cap; this guard reports pathological RNG
            // failure rather than silently changing its distribution.
            repeat {
                guard count < 1_000_000 else {
                    throw Failure.invalid("Numba fast_poisson: excessive Knuth draws")
                }
                count += 1
                probability *= rng.nextUniform()
            } while probability > limit
            return count - 1
        }

        let normal = try rng.nextNormal()
        let sample = lambda + sqrt(lambda) * normal
        guard sample.isFinite, sample > -Double(Int64.max),
              sample < Double(Int64.max) else {
            throw Failure.invalid("Numba fast_poisson: Float64->Int64 overflow")
        }
        let sourceRounded = sample.rounded(.toNearestOrEven)
        return sourceRounded < 0 ? 0 : Int64(sourceRounded)
    }

    mutating func fastBinomial(_ n: Int64, probability p: Double) throws -> Int64 {
        guard n >= 0, p.isFinite else {
            throw Failure.invalid("Numba fast_binomial: invalid n/p")
        }
        if p <= 0 { return 0 }
        if p >= 1 { return n }

        if n < 25 {
            var successes: Int64 = 0
            for _ in 0..<Int(n) {
                if rng.nextUniform() < p { successes += 1 }
            }
            return successes
        }

        let mean = Double(n) * p
        let variance = Double(n) * p * (1.0 - p)
        guard mean.isFinite, variance.isFinite else {
            throw Failure.invalid("Numba fast_binomial: Float64 variance overflow")
        }
        if variance > 10.0 {
            let normal = try rng.nextNormal()
            let estimate = mean + sqrt(variance) * normal
            guard estimate.isFinite,
                  estimate > -Double(Int64.max),
                  estimate < Double(Int64.max) else {
                throw Failure.invalid("Numba fast_binomial: Normal integer overflow")
            }
            let sourceRounded = estimate.rounded(.toNearestOrEven)
            let bounded = max(0.0, min(Double(n), sourceRounded))
            return Int64(bounded)
        }

        // Exact upstream inversion loop:
        // prob=(1-p)**n; loop while cdf<u and k<=n;
        // prob=prob*((n-k)/(k+1))*(p/(1-p)); return k-1.
        // Do not "fix" the source k-1 convention or reorder operations.
        let uniform = rng.nextUniform()
        var cdf = 0.0
        var probability = pow(1.0 - p, Double(n))
        var k: Int64 = 0
        while cdf < uniform && k <= n {
            guard k < 2_000_000 else {
                throw Failure.invalid("Numba fast_binomial: inversion exceeded safety cap")
            }
            cdf += probability
            if k < n {
                probability = probability *
                    (Double(n-k) / Double(k+1)) *
                    (p / (1.0-p))
            }
            k += 1
        }
        return k - 1
    }

    mutating func runOriginalTwoPhase(
        rates: [Double], probabilities: [Double]
    ) throws -> (poisson: [Int64], binomial: [Int64], afterPoisson: Double,
                 afterBinomial: Double) {
        guard rates.count == probabilities.count else {
            throw Failure.invalid("Numba fast_stats: array shape mismatch")
        }
        var poisson = [Int64]()
        poisson.reserveCapacity(rates.count)
        for rate in rates { poisson.append(try fastPoisson(rate)) }
        let afterPoisson = peekNextUniform()
        var binomial = [Int64]()
        binomial.reserveCapacity(rates.count)
        for i in rates.indices {
            binomial.append(
                try fastBinomial(poisson[i], probability: probabilities[i])
            )
        }
        return (poisson, binomial, afterPoisson, peekNextUniform())
    }
}
