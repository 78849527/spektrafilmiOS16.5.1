import Foundation

/// iPhone CPU-only diagnostic appendix: original fast_stats.py
/// explicitly-seeded ONE-worker Numba vs this native Swift implementation.
/// Source reference is generated in CI before the application build.
/// This is NOT production-grain GPU or unseeded prange stream certification.
enum OriginalSourceNumbaFastCountsDiagnostic {
    enum ValidationError: LocalizedError {
        case mismatch(String)

        var errorDescription: String? {
            if case let .mismatch(message) = self { return message }
            return nil
        }
    }

    static func evaluate() throws -> String {
        let fixtures = GeneratedSourceNumbaFastCountsReference.cases
        guard fixtures.count == 3,
              GeneratedSourceNumbaFastCountsReference.fastStatsBlob ==
                "9e80d29ce6b9f7820ae70f5c09da15edfaa70a0d",
              GeneratedSourceNumbaFastCountsReference.grainBlob ==
                "f2d2b23e3eab4f4a1d919f69bcb4aceb714e024d"
        else {
            throw ValidationError.mismatch("原版 Numba fast_stats 源码身份/参考向量错误")
        }
        var poissonCount = 0
        var binomialCount = 0
        for fixture in fixtures {
            let n = fixture.rates.count
            guard n == 60,
                  fixture.probabilities.count == n,
                  fixture.poisson.count == n,
                  fixture.binomial.count == n,
                  fixture.fixedNs.count == 60,
                  fixture.fixedPs.count == 60,
                  fixture.fixedBinomial.count == 60 else {
                throw ValidationError.mismatch("Numba FastCounts 输入或原版参考维度不匹配")
            }
            var chain = OriginalSourceNumbaFastCounts(seed: fixture.seed)
            let output = try chain.runOriginalTwoPhase(
                rates: fixture.rates, probabilities: fixture.probabilities
            )
            for i in 0..<n {
                guard output.poisson[i] == fixture.poisson[i],
                      output.binomial[i] == fixture.binomial[i] else {
                    throw ValidationError.mismatch(
                        "Numba 原版 Poisson/Binomial 不同：seed=\(fixture.seed) index=\(i)"
                    )
                }
            }
            guard output.afterPoisson.bitPattern ==
                      fixture.afterPoisson.bitPattern,
                  output.afterBinomial.bitPattern ==
                      fixture.afterBinomial.bitPattern else {
                throw ValidationError.mismatch("Numba 采样结束后的 MT19937 随机消耗次序不一致")
            }
            var fixed = OriginalSourceNumbaFastCounts(seed: fixture.seed &+ 1)
            for i in fixture.fixedNs.indices {
                let actual = try fixed.fastBinomial(
                    fixture.fixedNs[i], probability: fixture.fixedPs[i]
                )
                guard actual == fixture.fixedBinomial[i] else {
                    throw ValidationError.mismatch(
                        "Numba 阈值分支不同：seed=\(fixture.seed) index=\(i)"
                    )
                }
            }
            guard fixed.peekNextUniform().bitPattern ==
                  fixture.afterFixedBinomial.bitPattern else {
                throw ValidationError.mismatch("Numba 阈值分支随机流计数不一致")
            }
            poissonCount += n
            binomialCount += n + fixture.fixedNs.count
        }
        return "原版 Numba 0.64 / NumPy 2.4，单线程显式固定种子 0、8888、123456；" +
               "逐项整数等价：\(poissonCount) Poisson + \(binomialCount) Binomial；" +
               "随机流结束后下一个 Float64 位级一致。\n" +
               "【范围限制】仅 Swift CPU 原版对照。尚未认证原版 Numba prange 多线程 " +
               "RNG、生产 Metal 颗粒、完整 RGB 图像或真实 iPhone 原版浮点等价。"
    }
}
