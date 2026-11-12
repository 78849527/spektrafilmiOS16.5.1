import Foundation

/// Source-compatible stochastic counts for upstream grain.py:
///     scipy.stats.poisson.rvs(n / saturation)
///     scipy.stats.binom.rvs(seeds, probability_of_development)
///
/// Reference: NumPy v1.26.4
/// numpy/random/src/distributions/distributions.c:
///   random_poisson, random_poisson_mult, random_poisson_ptrs,
///   random_binomial_inversion, random_binomial_btpe, random_loggam
/// and numpy/random/src/legacy/legacy-distributions.c:
///   legacy_random_poisson, legacy_random_binomial.
///
/// The underlying 53-bit NumPy RandomState MT19937 uniform generator is
/// validated separately against original NumPy bit patterns. Crucially,
/// poisson is generated for ALL pixels first, followed by binomial for ALL
/// pixels: substituting the Poisson-thinning distribution cannot reproduce
/// the source sample sequence. No kernel uses this until verification passes.
struct OriginalSourceSciPySampler {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    private var mt: OriginalSourceMT19937

    init(seed: UInt32) {
        mt = OriginalSourceMT19937(seed: seed)
    }

    mutating func nextUInt32() -> UInt32 {
        mt.nextUInt32()
    }

    private mutating func uniform() -> Double {
        mt.randomSample()
    }

    /// Original random_loggam from NumPy 1.26.4; not replaced by lgamma,
    /// because the acceptance branch needs the same numerical comparison.
    private static func randomLogGam(_ x: Double) -> Double {
        if x == 1 || x == 2 { return 0 }
        let a: [Double] = [
            8.333333333333333e-02, -2.777777777777778e-03,
            7.936507936507937e-04, -5.952380952380952e-04,
            8.417508417508418e-04, -1.917526917526918e-03,
            6.410256410256410e-03, -2.955065359477124e-02,
            1.796443723688307e-01, -1.39243221690590e+00
        ]
        let n = x < 7 ? Int(7 - x) : 0
        var x0 = x + Double(n)
        let x2 = (1 / x0) * (1 / x0)
        var gl0 = a[9]
        for k in stride(from: 8, through: 0, by: -1) {
            gl0 *= x2
            gl0 += a[k]
        }
        var gl = gl0 / x0 + 0.5 * 1.8378770664093453 +
            (x0 - 0.5) * log(x0) - x0
        if x < 7 {
            for _ in 1...n {
                gl -= log(x0 - 1)
                x0 -= 1
            }
        }
        return gl
    }

    mutating func poisson(_ lambda: Double) throws -> Int64 {
        guard lambda.isFinite, lambda >= 0,
              lambda < Double(Int64.max) / 100 else {
            throw Failure.invalid("原版 SciPy Poisson：λ 不可用或溢出")
        }
        if lambda == 0 { return 0 }
        if lambda < 10 {
            // NumPy random_poisson_mult consumes one final failing
            // uniform; do not use cumulative inverse-CDF.
            let threshold = exp(-lambda)
            var product = 1.0
            for k in 0..<1_000_000 {
                product *= uniform()
                if !(product > threshold) { return Int64(k) }
            }
            throw Failure.invalid("原版 SciPy Poisson：乘积抽样异常未终止")
        }
        // NumPy random_poisson_ptrs (Hoermann transformed rejection).
        let root = sqrt(lambda)
        let logLambda = log(lambda)
        let b = 0.931 + 2.53 * root
        let a = -0.059 + 0.02483 * b
        let inverseAlpha = 1.1239 + 1.1328 / (b - 3.4)
        let vr = 0.9277 - 3.6224 / (b - 2)
        for _ in 0..<1_000_000 {
            let u = uniform() - 0.5
            let v = uniform()
            let us = 0.5 - abs(u)
            if us == 0 { continue }
            let raw = floor((2 * a / us + b) * u + lambda + 0.43)
            guard raw.isFinite, raw >= Double(Int64.min),
                  raw < Double(Int64.max) else {
                throw Failure.invalid("原版 SciPy Poisson：PTRS 输出溢出")
            }
            let k = Int64(raw)
            if us >= 0.07 && v <= vr { return k }
            if k < 0 || (us < 0.013 && v > us) { continue }
            let lhs = log(v) + log(inverseAlpha) -
                log(a / (us * us) + b)
            let rhs = -lambda + Double(k) * logLambda -
                Self.randomLogGam(Double(k) + 1)
            if lhs <= rhs { return k }
        }
        throw Failure.invalid("原版 SciPy Poisson：PTRS 长时间未收敛")
    }

    // The binomial cache in NumPy stores the previous (n,p) constants.
    // Recomputing identical Float64 expressions does not change uniform
    // consumption or the distribution. These routines are intentionally
    // sequential, not independent per-pixel hashes.
    private mutating func binomialInversion(_ n: Int64, _ p: Double) throws -> Int64 {
        let q = 1 - p
        let qn = exp(Double(n) * log(q))
        let np = Double(n) * p
        let bound = min(n, Int64(np + 10 * sqrt(np * q + 1)))
        var x: Int64 = 0
        var px = qn
        var u = uniform()
        for _ in 0..<1_000_000 {
            if !(u > px) { return x }
            x += 1
            if x > bound {
                x = 0
                px = qn
                u = uniform()
            } else {
                u -= px
                px = ((Double(n - x + 1) * p * px) /
                      (Double(x) * q))
            }
        }
        throw Failure.invalid("原版 SciPy Binomial：逆 CDF 抽样未收敛")
    }

    private static func stirlingTerm(_ x: Double) -> Double {
        let x2 = x * x
        return (13680 - (462 - (132 - (99 - 140 / x2) / x2) / x2) / x2) /
            x / 166320
    }

    private mutating func binomialBTPE(_ n: Int64, _ p: Double) throws -> Int64 {
        let r = min(p, 1 - p)
        let q = 1 - r
        let fm = Double(n) * r + r
        let m = Int64(floor(fm))
        let p1 = floor(2.195 * sqrt(Double(n) * r * q) - 4.6 * q) + 0.5
        let xm = Double(m) + 0.5
        let xl = xm - p1
        let xr = xm + p1
        let c = 0.134 + 20.5 / (15.3 + Double(m))
        var a = (fm - xl) / (fm - xl * r)
        let laml = a * (1 + a / 2)
        a = (xr - fm) / (xr * q)
        let lamr = a * (1 + a / 2)
        let p2 = p1 * (1 + 2 * c)
        let p3 = p2 + c / laml
        let p4 = p3 + c / lamr
        let nrq = Double(n) * r * q
        for _ in 0..<1_000_000 {
            let u = uniform() * p4
            var v = uniform()
            var y: Int64
            if u <= p1 {
                y = Int64(floor(xm - p1 * v + u))
                return p > 0.5 ? n - y : y
            } else if u <= p2 {
                let x = xl + (u - p1) / c
                v = v * c + 1 - abs(Double(m) - x + 0.5) / p1
                if v > 1 { continue }
                y = Int64(floor(x))
            } else if u <= p3 {
                if v == 0 { continue }
                let value = floor(xl + log(v) / laml)
                if !value.isFinite || value < 0 { continue }
                y = Int64(value)
                v = v * (u - p2) * laml
            } else {
                if v == 0 { continue }
                let value = floor(xr - log(v) / lamr)
                if !value.isFinite || value > Double(n) { continue }
                y = Int64(value)
                v = v * (u - p3) * lamr
            }
            let k = abs(y - m)
            if k > 20 && Double(k) < nrq / 2 - 1 {
                let dk = Double(k)
                let rho = (dk / nrq) *
                    ((dk * (dk / 3 + 0.625) + 0.16666666666666666) / nrq + 0.5)
                let t = -dk * dk / (2 * nrq)
                let score = log(v)
                if score < t - rho {
                    return p > 0.5 ? n - y : y
                }
                if score > t + rho { continue }
                let x1 = Double(y) + 1
                let f1 = Double(m) + 1
                let z = Double(n - m) + 1
                let w = Double(n - y) + 1
                let limit = xm * log(f1 / x1) +
                    (Double(n - m) + 0.5) * log(z / w) +
                    Double(y - m) * log(w * r / (x1 * q)) +
                    Self.stirlingTerm(f1) + Self.stirlingTerm(z) +
                    Self.stirlingTerm(x1) + Self.stirlingTerm(w)
                if score > limit { continue }
                return p > 0.5 ? n - y : y
            }
            let ratio = r / q
            let aa = ratio * Double(n + 1)
            var factor = 1.0
            if m < y {
                for i in (m+1)...y {
                    factor *= aa / Double(i) - ratio
                }
            } else if m > y {
                for i in (y+1)...m {
                    factor /= aa / Double(i) - ratio
                }
            }
            if v > factor { continue }
            return p > 0.5 ? n - y : y
        }
        throw Failure.invalid("原版 SciPy Binomial：BTPE 长时间未收敛")
    }

    mutating func binomial(_ n: Int64, probability p: Double) throws -> Int64 {
        guard n >= 0, n < Int64.max / 100,
              p.isFinite, p >= 0, p <= 1 else {
            throw Failure.invalid("原版 SciPy Binomial：n 或 p 无效")
        }
        // NumPy RandomState LEGACY wrapper intentionally delegates to
        // inversion even for n==0 and p==0/1. Do not short-circuit and
        // thereby alter the random stream.
        if p <= 0.5 {
            return p * Double(n) <= 30 ?
                try binomialInversion(n, p) : binomialBTPE(n, p)
        }
        let q = 1 - p
        let complement = try (q * Double(n) <= 30 ?
            binomialInversion(n, q) : binomialBTPE(n, q))
        return n - complement
    }

    /// Preserve the two-source-array order of grain.py:
    /// (1) all Poisson seeds; (2) all Binomial development counts.
    /// Stream is re-seeded PER channel/sublayer, not per image or tile.
    static func drawLayer(
        rates: [Double], probabilities: [Double], seed: UInt32
    ) throws -> [Int64] {
        guard rates.count == probabilities.count, !rates.isEmpty else {
            throw Failure.invalid("原版 SciPy 随机场：输入数组尺寸不一致")
        }
        var engine = Self(seed: seed)
        var seeds = [Int64]()
        seeds.reserveCapacity(rates.count)
        for lambda in rates { seeds.append(try engine.poisson(lambda)) }
        var developed = [Int64]()
        developed.reserveCapacity(rates.count)
        for index in rates.indices {
            developed.append(
                try engine.binomial(seeds[index], probability: probabilities[index])
            )
        }
        return developed
    }
}
