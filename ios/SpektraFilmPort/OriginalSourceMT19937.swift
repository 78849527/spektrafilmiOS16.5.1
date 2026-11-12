import Foundation

/// Exact NumPy RandomState (legacy MT19937) uniform bit generator.
/// Source reference: numpy.random.mtrand.RandomState(seed), 32-bit MT and
/// 53-bit random_sample() using two successive uint32 outputs.
///
/// This is only the RNG *core*. SciPy poisson.rvs/binom.rvs algorithms,
/// their nonuniform draw counts, sequential array order and Numba's
/// separate microstructure RNG still MUST be implemented and verified.
/// Not connected to production grain until those source paths are exact.
struct OriginalSourceMT19937 {
    private var state = [UInt32](repeating: 0, count: 624)
    private var index = 624

    init(seed: UInt32) {
        state[0] = seed
        if state.count > 1 {
            for i in 1..<state.count {
                let previous = state[i-1]
                state[i] = 1_812_433_253 &*
                    (previous ^ (previous >> 30)) &+ UInt32(i)
            }
        }
    }

    mutating func nextUInt32() -> UInt32 {
        if index == 624 {
            // Original in-place MT twist; the modulo-wrapped references
            // deliberately read previously updated words as NumPy does.
            for i in 0..<624 {
                let y = (state[i] & 0x8000_0000) |
                    (state[(i + 1) % 624] & 0x7fff_ffff)
                state[i] = state[(i + 397) % 624] ^ (y >> 1) ^
                    ((y & 1) == 0 ? 0 : 0x9908_b0df)
            }
            index = 0
        }
        var y = state[index]
        index += 1
        y ^= y >> 11
        y ^= (y << 7) & 0x9d2c_5680
        y ^= (y << 15) & 0xefc6_0000
        y ^= y >> 18
        return y
    }

    mutating func randomSample() -> Double {
        let a = Double(nextUInt32() >> 5)
        let b = Double(nextUInt32() >> 6)
        return (a * 67_108_864.0 + b) / 9_007_199_254_740_992.0
    }

    static func validateReference() throws -> String {
        guard GeneratedSourceMT19937Reference.cases.count >= 3 else {
            throw ValidationError.invalid("MT19937：缺少原版 NumPy 种子对照")
        }
        var totalUInt = 0
        var totalFloat = 0
        for reference in GeneratedSourceMT19937Reference.cases {
            var bits = OriginalSourceMT19937(seed: reference.seed)
            for (index, expected) in reference.uint32.enumerated() {
                let actual = bits.nextUInt32()
                guard actual == expected else {
                    throw ValidationError.invalid(
                        "MT19937 seed=\(reference.seed) UInt32[\(index)] " +
                        "Python=\(expected) Swift=\(actual)"
                    )
                }
                totalUInt += 1
            }
            var doubleGenerator = OriginalSourceMT19937(seed: reference.seed)
            for (index, expected) in reference.uniform53.enumerated() {
                let actual = doubleGenerator.randomSample()
                guard actual.bitPattern == expected.bitPattern else {
                    throw ValidationError.invalid(
                        "MT19937 seed=\(reference.seed) Float64[\(index)] " +
                        "Python=\(expected) Swift=\(actual)"
                    )
                }
                totalFloat += 1
            }
        }
        return "NumPy legacy MT19937 位流通过：\(totalUInt) UInt32 / " +
            "\(totalFloat) Float64，尚未等价移植 SciPy Poisson/Binomial"
    }

    enum ValidationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(value) = self { return value }
            return nil
        }
    }
}
