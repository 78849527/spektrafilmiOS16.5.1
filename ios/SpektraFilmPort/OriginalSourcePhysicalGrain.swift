import Foundation

/// Experimental full Double physical-density grain, from upstream
/// model/grain.py::apply_grain_to_density_layers. NOT the old RGB or Metal
/// Gaussian surrogate. Four distinct source stages are run in order:
/// (1) measured 3x3 sublayer Poisson→Binomial SciPy arrays (9 per image),
/// (2) per-sublayer dye-cloud Gaussian on density BEFORE accumulation,
/// (3) 3-channel Numba lognormal microstructure, where threshold enables,
/// (4) final full-image reflect FIR/YVV grain Gaussian.
///
/// SciPy uses fixed original layer seeds (channel + 10*sublayer). Numba
/// prange is normally unseeded and multi-worker; here microstructure is
/// only possible with one explicitly seeded, controlled CPU worker.
/// This is NOT default Python parallel RNG/full-image parity.
/// No post-scanner RGB noise and no silent algorithm fallback.
enum OriginalSourcePhysicalGrain {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(value) = self { return value }
            return nil
        }
    }

    struct Settings {
        var active = false
        var particleAreaUM2 = 0.2
        var particleScale: [Double] = [1.6,1.6,3.2]
        var sublayerScale: [Double] = [2.0,1.0,0.5]
        var densityMin: [Double] = [0.03,0.03,0.03]
        var uniformity: [Double] = [0.97,0.99,0.97]
        var grainBlur = 0.65
        var dyeCloudBlurUM = 1.0
        var microstructureUM = 0.2
        var microstructureNM = 30.0
        /// Fixed one-worker diagnostic seed; never auto-seed from time.
        var numbaSeed: UInt32? = nil

        func validate() throws {
            let arrays=[particleScale,sublayerScale,densityMin,uniformity]
            guard arrays.allSatisfy({$0.count==3 && $0.allSatisfy({$0.isFinite})}),
                  particleAreaUM2.isFinite,particleAreaUM2>0,
                  particleScale.allSatisfy({$0>0}),
                  sublayerScale.allSatisfy({$0>0}),
                  densityMin.allSatisfy({$0>=0}),
                  uniformity.allSatisfy({$0>=0 && $0<=1}),
                  grainBlur.isFinite,grainBlur>=0,
                  dyeCloudBlurUM.isFinite,dyeCloudBlurUM>=0,
                  microstructureUM.isFinite,microstructureUM>=0,
                  microstructureNM.isFinite,microstructureNM>=0 else {
                throw Failure.invalid("源颗粒参数必须严格使用合法的原版数量、面积、模糊及 3×3 亚层")
            }
            if active && numbaSeed == nil {
                throw Failure.invalid("原版颗粒受控 Numba RNG 需要显式固定种子，不允许自动近似")
            }
        }
    }

    /// For parent pre-decode safety budget. Additional whole-frame Double
    /// sublayer field + SciPy counts + blur scratch; do not auto-resize.
    static let extraBytesPerPixel: UInt64 = 272

    /// A sampled, fully measured source 3x3 film density profile.
    /// Ordering is [sublayer][CMY] and each layer uses the original
    /// measured per-layer maxima from normalized source curves.
    struct MeasuredLayers {
        let maxima: [Double]
        let sublayers: ([Double]) throws -> [Double]
    }

    static func apply(
        _ densityCMY: [Double], width: Int, height: Int,
        pixelUM: Double, measured: MeasuredLayers,
        settings: Settings,
        stageObserver: ((String,[Double])->Void)? = nil
    ) throws -> [Double] {
        try settings.validate()
        guard width>0,height>0,
              width<=Int.max/height/3,
              densityCMY.count==width*height*3,
              pixelUM.isFinite,pixelUM>0,
              densityCMY.allSatisfy({$0.isFinite}),
              measured.maxima.count==9,
              measured.maxima.allSatisfy({$0.isFinite && $0>0}) else {
            throw Failure.invalid("原版 3×3 颗粒需要有限的整图 CMY、有效亚层最大值和像素 μm")
        }
        if !settings.active { return densityCMY }
        let pixels=width*height
        let maxLayers=measured.maxima
        var fractions=[Double](repeating:0,count:9)
        var minLayers=[Double](repeating:0,count:9)
        var densityMax=[Double](repeating:0,count:9)
        var particleN=[Double](repeating:0,count:9)
        var densityOD=[Double](repeating:0,count:9)
        for ch in 0..<3 {
            let total=maxLayers[ch]+maxLayers[3+ch]+maxLayers[6+ch]
            guard total.isFinite,total>0 else {
                throw Failure.invalid("原版亚层最大密度总和小于零")
            }
            for sl in 0..<3 {
                let ix=sl*3+ch
                let fraction=maxLayers[ix]/total
                fractions[ix]=fraction
                minLayers[ix]=fraction*settings.densityMin[ch]
                densityMax[ix]=maxLayers[ix]+minLayers[ix]
                // grain.py: pixel_area * density_max_fractions /
                // (particle_area * particle_scale[color] *
                //  particle_scale_layers[sublayer])
                particleN[ix]=pixelUM*pixelUM*fraction /
                    (settings.particleAreaUM2 * settings.particleScale[ch] *
                     settings.sublayerScale[sl])
                densityOD[ix]=densityMax[ix]/particleN[ix]
                guard particleN[ix].isFinite,particleN[ix]>0,
                      densityOD[ix].isFinite,densityOD[ix]>0 else {
                    throw Failure.invalid("原版颗粒粒子密度/亚层比例计算错误")
                }
            }
        }
        // Interpolate all 9 sublayers BEFORE SciPy RNG; the source uses
        // this measured inversion, not total CMY RGB surrogates.
        var layerInputs=[Double](repeating:0,count:pixels*9)
        for p in 0..<pixels {
            let k=p*3
            let layer=try measured.sublayers(
                [densityCMY[k],densityCMY[k+1],densityCMY[k+2]]
            )
            guard layer.count==9,layer.allSatisfy({$0.isFinite}) else {
                throw Failure.invalid("原版胶片三亚层密度未完整计算")
            }
            for i in 0..<9 { layerInputs[p*9+i]=layer[i] }
        }
        stageObserver?("sourceGrainSublayers",layerInputs)

        // The original density_min is added to *each sublayer* before
        // probability-of-development. Accumulate sublayer particle
        // density, later subtract total channel density_min once.
        var out=[Double](repeating:0,count:pixels*3)
        // Float64 3×3 performance: each of the 9 SciPy source layers
        // overwrites ALL pixels in these temporary arrays. Reuse them
        // instead of allocating 9 × (3 scalar fields + 1 RGB blur field).
        // RNG order, formula order, source spatial kernel and precision
        // are unchanged. Independent Python stage + final RGB parity
        // must remain the authority for this allocation-only optimization.
        var probabilities=[Double](repeating:0,count:pixels)
        var rates=[Double](repeating:0,count:pixels)
        var saturations=[Double](repeating:0,count:pixels)
        var cloud=[Double](repeating:0,count:pixels*3)
        for ch in 0..<3 {
            for sl in 0..<3 {
                let li=sl*3+ch
                let n=particleN[li],od=densityOD[li]
                for p in 0..<pixels {
                    let sourceD=layerInputs[p*9+li]+minLayers[li]
                    let probability=min(1.0-1e-6,max(1e-6,sourceD/densityMax[li]))
                    let saturation=1.0-probability*settings.uniformity[ch]*(1.0-1e-6)
                    probabilities[p]=probability
                    saturations[p]=saturation
                    rates[p]=n/saturation
                }
                let counts=try OriginalSourceSciPySampler.drawLayer(
                    rates:rates,probabilities:probabilities,
                    seed:UInt32(ch+sl*10)
                )
                // dye-cloud blur_particle in grain.py deliberately passes
                // blur_dye_clouds_um WITHOUT dividing by pixelUM, then
                // multiplies sqrt(optical density per particle).
                let sigma=settings.dyeCloudBlurUM*sqrt(od)
                if sigma>0 {
                    for p in 0..<pixels {
                        cloud[p*3]=Double(counts[p])*od*saturations[p]
                    }
                    let smoothed=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                        cloud,width:width,height:height,
                        coreSigma:sigma,tailSigma:0,tailWeight:0
                    )
                    for p in 0..<pixels {out[p*3+ch]+=smoothed[p*3]}
                } else {
                    for p in 0..<pixels {
                        out[p*3+ch]+=Double(counts[p])*od*saturations[p]
                    }
                }
            }
        }
        stageObserver?("sourceGrainDyeClouds",out)

        // Upstream fast_lognormal_from_mean_std(mean=1,std=30nm/px);
        // only enabled if std > 0.05. Controlled Numba one-worker draw.
        let microStd=settings.microstructureNM*0.001/pixelUM
        let microBlur=settings.microstructureUM/pixelUM
        if microStd>0.05 {
            guard let seed=settings.numbaSeed else {
                throw Failure.invalid("原版 Numba 微结构随机线程未定义")
            }
            var numba=OriginalSourceNumbaSingleThreadNormal(seed:seed)
            var clump=[Double](repeating:0,count:pixels*3)
            for ix in clump.indices {
                clump[ix]=try OriginalSourceMicrostructure.lognormal(
                    microStd:microStd,z:numba.nextNormal()
                )
            }
            if microBlur>0.4 {
                clump=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                    clump,width:width,height:height,
                    coreSigma:microBlur,tailSigma:0,tailWeight:0
                )
            }
            for ix in out.indices {out[ix]*=clump[ix]}
        }
        stageObserver?("sourceGrainMicrostructure",out)

        for p in 0..<pixels {
            for ch in 0..<3 {
                out[p*3+ch]-=settings.densityMin[ch]
            }
        }
        if settings.grainBlur>0 {
            out=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                out,width:width,height:height,
                coreSigma:settings.grainBlur,tailSigma:0,tailWeight:0
            )
        }
        guard out.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版颗粒输出出现 NaN/Inf，拒绝静默降级")
        }
        stageObserver?("sourceGrainFinalDensity",out)
        return out
    }
}
