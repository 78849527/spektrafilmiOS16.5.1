import Foundation

/// Diagnostic-only port of Numba's *single-thread, explicitly seeded*
/// np.random.randn() stream used by fast_stats.fast_lognormal().
///
/// NumPy RandomState/Numba CPU legacy MT19937 standard normal uses the
/// Marsaglia polar rejection scheme, returning the second sample first
/// and caching the first sample for the following call.
///
/// This does NOT reproduce unseeded `prange` worker-thread states, the
/// source's arbitrary scheduling, or production iPhone GPU random fields.
/// Never substitute this into production without whole-stream verification.
struct OriginalSourceNumbaSingleThreadNormal {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(value) = self { return value }
            return nil
        }
    }

    private var mt: OriginalSourceMT19937
    private var cachedNormal: Double? = nil

    init(seed: UInt32) {
        self.mt = OriginalSourceMT19937(seed: seed)
    }

    mutating func nextNormal() throws -> Double {
        if let cached = cachedNormal {
            cachedNormal = nil
            return cached
        }
        // Source calls Numba's np.random.randn(), whose legacy normal
        // transform uses the polar method and a one-value normal cache.
        // The two random_sample() values each consume two MT words.
        for _ in 0..<1_000_000 {
            let x1 = 2.0 * mt.randomSample() - 1.0
            let x2 = 2.0 * mt.randomSample() - 1.0
            let r2 = x1*x1 + x2*x2
            if r2 >= 1.0 || r2 == 0.0 { continue }
            let factor = sqrt(-2.0 * log(r2) / r2)
            let first = x2 * factor
            let second = x1 * factor
            guard first.isFinite, second.isFinite else {
                throw Failure.invalid("Numba 单线程源 RNG：非有限正态样本")
            }
            cachedNormal = second
            return first
        }
        throw Failure.invalid("Numba 单线程源 RNG：极坐标拒绝抽样超出安全次数")
    }
}
