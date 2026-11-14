import Foundation

/// Controlled single-worker port of the Python source's
/// model/glare.py::compute_random_glare_amount and add_glare.
///
/// Exact source stage: Numba fast_lognormal_from_mean_std(percent,
/// roughness*percent) -> fast_gaussian_filter(2D, blur) -> /100 ->
/// xyz[p,c] += glare[p]*illuminantXYZ[c].
///
/// A source Numba prange worker is unseeded in normal production. The
/// explicit seed here only certifies the controlled one-worker diagnostic.
/// This module is deliberately NOT wired into the production source scan
/// because adding glare after XYZ->RGB would be the wrong algorithm.
/// Do not substitute this module for the stochastic production scanner
/// until original XYZ staging and multi-worker RNG are verified.
enum OriginalSourceScannerGlare {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(value) = self { return value }
            return nil
        }
    }

    struct Settings {
        var active: Bool = true
        var percent: Double = 0.03
        var roughness: Double = 0.7
        var blur: Double = 0.5

        func validate() throws {
            guard percent.isFinite, percent >= 0,
                  roughness.isFinite, roughness >= 0,
                  blur.isFinite, blur >= 0,
                  // Resource guards are explicit experimental limits,
                  // never a silent blur or sigma downgrade.
                  percent <= 100, roughness <= 100,
                  blur <= 100 else {
                throw Failure.invalid(
                    "原版 scanner glare 参数非有限、负数或超过明确实验安全上限"
                )
            }
        }
    }

    /// Produces the one-channel Python glare_amount AFTER /100.
    ///
    /// Either a complete externally supplied original Numba N(0,1) field
    /// or a single explicitly-seeded worker must be supplied. A missing
    /// RNG source always fails rather than silently using hash noise.
    static func computeAmount(
        width: Int, height: Int, settings: Settings,
        controlledSeed: UInt32? = nil,
        sourceNormals: [Double]? = nil
    ) throws -> [Double] {
        try settings.validate()
        guard width > 0, height > 0,
              width <= 8192, height <= 8192,
              width <= 12_000_000 / height else {
            throw Failure.invalid("原版眩光：图片大小或宽高无效")
        }
        let count = width * height
        if !settings.active || settings.percent <= 0 {
            return [Double](repeating: 0, count: count)
        }
        guard (controlledSeed != nil) != (sourceNormals != nil) else {
            throw Failure.invalid(
                "原版眩光：必须且只能提供单线程显式种子或源 Numba 原始正态场"
            )
        }
        if let sourceNormals {
            guard sourceNormals.count == count,
                  sourceNormals.allSatisfy({ $0.isFinite }) else {
                throw Failure.invalid("原版眩光：源正态随机场维度或数值不合法")
            }
        }

        // Python fast_stats.py:
        // sigma2=np.log(1+(s*s)/(m*m)); sigma=sqrt(sigma2)
        // mu=np.log(m)-sigma2/2.0; exp(mu+sigma*np.random.randn())
        let mean = settings.percent
        let std = settings.roughness * settings.percent
        let sigmaSquared = log(1.0 + (std * std) / (mean * mean))
        let sigma = sqrt(sigmaSquared)
        let mu = log(mean) - sigmaSquared / 2.0
        guard sigma.isFinite, mu.isFinite else {
            throw Failure.invalid("原版眩光：对数正态参数超出 Float64 范围")
        }
        var rng = controlledSeed.map {
            OriginalSourceNumbaSingleThreadNormal(seed: $0)
        }
        var samples = [Double](repeating: 0, count: count * 3)
        for pixel in 0..<count {
            let normal: Double
            if sigma < 1e-6 {
                // Source fast_lognormal() avoids RNG draws entirely.
                normal = 0
            } else if let sourceNormals {
                normal = sourceNormals[pixel]
            } else {
                guard rng != nil else {
                    throw Failure.invalid("原版眩光：缺少可控 Numba 随机流")
                }
                normal = try rng!.nextNormal()
            }
            let value = sigma < 1e-6
                ? exp(mu) : exp(mu + sigma * normal)
            guard value.isFinite else {
                throw Failure.invalid("原版眩光：对数正态随机场产生 NaN/Inf")
            }
            let k = pixel * 3
            samples[k] = value
            samples[k + 1] = value
            samples[k + 2] = value
        }

        // Reuse the already source-validated Double FIR/YVV filtering.
        // Its RGB channels are identical copies of the original 2D field;
        // this is not three independent RNG streams.
        let filtered = try SourceSpatialDIRConvolution.diffuseMemoryBounded(
            samples, width: width, height: height,
            coreSigma: settings.blur, tailSigma: 0, tailWeight: 0
        )
        var amount = [Double](repeating: 0, count: count)
        for pixel in 0..<count {
            let result = filtered[pixel * 3] / 100.0
            guard result.isFinite else {
                throw Failure.invalid("原版眩光：反射空间滤波结果无效")
            }
            amount[pixel] = result
        }
        return amount
    }

    /// True XYZ-domain source addition. Do not feed display RGB here.
    static func addToXYZ(
        _ xyz: [Double], illuminantXYZ: [Double],
        width: Int, height: Int, settings: Settings,
        controlledSeed: UInt32? = nil,
        sourceNormals: [Double]? = nil
    ) throws -> [Double] {
        guard illuminantXYZ.count == 3,
              illuminantXYZ.allSatisfy({ $0.isFinite }),
              width > 0, height > 0,
              width <= 12_000_000 / height,
              xyz.count == width * height * 3,
              xyz.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid(
                "原版扫描眩光只能在真实 Float64 XYZ/光源归一化之后叠加"
            )
        }
        let glare = try computeAmount(
            width: width, height: height, settings: settings,
            controlledSeed: controlledSeed, sourceNormals: sourceNormals
        )
        var result = xyz
        for pixel in 0..<(width * height) {
            for ch in 0..<3 {
                let index = pixel * 3 + ch
                result[index] = xyz[index] + glare[pixel] * illuminantXYZ[ch]
                guard result[index].isFinite else {
                    throw Failure.invalid("原版扫描 XYZ 眩光叠加产生 NaN/Inf")
                }
            }
        }
        return result
    }
}
