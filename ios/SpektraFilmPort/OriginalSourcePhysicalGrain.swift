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
/// prange is normally unseeded and multi-worker. Build115 offers the
/// separate OS-entropy 2–8-worker stochastic branch, while retaining the
/// fixed-seed one-worker exact reference. Parallel moments may be verified;
/// arbitrary Python worker scheduling and bitstream are NOT certified.
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
        /// Original grain.sublayers_active=false uses
        /// apply_grain_to_density; default preserves 3×3 measured emulsion.
        var sublayersActive = true
        var nSubLayers = 1
        /// One explicitly seeded Numba worker, not source prange parity.
        /// The default keeps SciPy RandomState layer sampling unchanged.
        var useFastStats = false
        var fastStatsSeed: UInt32? = nil
        /// Upstream default unseeded Numba prange candidate; distinct from
        /// the previous exact seeded single-worker diagnostic.
        var useUnseededParallel = false
        /// Zero means activeProcessorCount (clamped 2...8).
        var parallelWorkerCount = 0
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
                  microstructureNM.isFinite,microstructureNM>=0,
                  nSubLayers>=1,nSubLayers<=Int(UInt32.max/10),
                  (parallelWorkerCount==0 ||
                   (2...8).contains(parallelWorkerCount)) else {
                throw Failure.invalid("源颗粒参数必须严格使用合法的原版数量、面积、模糊及 3×3 亚层")
            }
            // Python grain.py only samples Numba for active microstructure
            // (30nm/px > 0.05) or the 3x3 fast_stats path. The microstructure
            // threshold depends on pixelUM and is enforced in apply().
            // When sublayers_active=false, Python ignores use_fast_stats and
            // always uses seeded SciPy Poisson/Binomial.
            if useUnseededParallel {
                guard sublayersActive && numbaSeed == nil &&
                      fastStatsSeed == nil else {
                    throw Failure.invalid(
                        "原版 Numba 多线程和单线程种子冲突，必须明确选择一种路径"
                    )
                }
            } else if active && sublayersActive && useFastStats &&
                      fastStatsSeed == nil {
                throw Failure.invalid(
                    "源三亚层 Numba fast_stats 必须提供受控单线程 RNG 种子"
                )
            }
            // The microstructure seed is conditional on pixelUM and
            // validated in apply(), not required for inactive lognormal.
        }
    }

    /// For parent pre-decode safety budget. Additional whole-frame Double
    /// Production no-observer input holds 3 rather than 9 layer values
    /// per pixel (48 B/px less); other conservative scratch stays budgeted.
    /// Stage-observer captures retain all 9 fields and are charged separately.
    static let extraBytesPerPixel: UInt64 = 224
    /// Extra retained worker-local particle input/count copies at
    /// concurrency boundaries, over the existing seeded grain ledger.
    static let unseededParallelExtraBytesPerPixel: UInt64 = 56

    /// A sampled, fully measured source 3x3 film density profile.
    /// Ordering is [sublayer][CMY] and each layer uses the original
    /// measured per-layer maxima from normalized source curves.
    struct MeasuredLayers {
        let maxima: [Double]
        let sublayers: ([Double]) throws -> [Double]
        /// Original source only: write 9 measured Float64 densities into
        /// a caller-owned scratch array; no per-pixel heap allocation.
        /// Legacy test fixtures can still supply just `sublayers`.
        var sublayersInto: (([Double], inout [Double]) throws -> Void)? = nil
        /// Write only indices sl*3+channel for the current production pass.
        /// All-channel observers retain the existing nine-value contract.
        var channelSublayersInto: (([Double], Int, inout [Double]) throws -> Void)? = nil
    }

    // Independent deterministic operations only: no reduction, FMA,
    // reciprocal, RNG or channel-order change. Keep scalar observer path.
    static func multiplyMicrostructureSIMD(
        _ density:inout [Double],_ clump:[Double]
    ) throws {
        guard density.count==clump.count else {
            throw Failure.invalid("原版微结构 SIMD 尺寸不一致")
        }
        try density.withUnsafeMutableBufferPointer { dst in
            try clump.withUnsafeBufferPointer { src in
                var i=0
                while i+4<=dst.count {
                    if i & 4095 == 0 {try Task.checkCancellation()}
                    let a=SIMD4<Double>(dst[i],dst[i+1],dst[i+2],dst[i+3])
                    let b=SIMD4<Double>(src[i],src[i+1],src[i+2],src[i+3])
                    let v=a*b
                    dst[i]=v[0];dst[i+1]=v[1];dst[i+2]=v[2];dst[i+3]=v[3]
                    i+=4
                }
                while i<dst.count {dst[i]*=src[i];i+=1}
            }
        }
    }

    static func subtractDensityMinSIMD(
        _ density:inout [Double],_ minimum:[Double]
    ) throws {
        guard minimum.count==3,density.count%3==0 else {
            throw Failure.invalid("原版 CMY 最小密度 SIMD 尺寸不一致")
        }
        let a=SIMD4<Double>(minimum[0],minimum[1],minimum[2],minimum[0])
        let b=SIMD4<Double>(minimum[1],minimum[2],minimum[0],minimum[1])
        let c=SIMD4<Double>(minimum[2],minimum[0],minimum[1],minimum[2])
        try density.withUnsafeMutableBufferPointer { dst in
            var i=0
            while i+12<=dst.count {
                if i & 4095 == 0 {try Task.checkCancellation()}
                let x=SIMD4<Double>(dst[i],dst[i+1],dst[i+2],dst[i+3])-a
                let y=SIMD4<Double>(dst[i+4],dst[i+5],dst[i+6],dst[i+7])-b
                let z=SIMD4<Double>(dst[i+8],dst[i+9],dst[i+10],dst[i+11])-c
                dst[i]=x[0];dst[i+1]=x[1];dst[i+2]=x[2];dst[i+3]=x[3]
                dst[i+4]=y[0];dst[i+5]=y[1];dst[i+6]=y[2];dst[i+7]=y[3]
                dst[i+8]=z[0];dst[i+9]=z[1];dst[i+10]=z[2];dst[i+11]=z[3]
                i+=12
            }
            while i<dst.count {dst[i]-=minimum[i%3];i+=1}
        }
    }

    static func apply(
        _ densityCMY: [Double], width: Int, height: Int,
        pixelUM: Double, measured: MeasuredLayers,
        settings: Settings,
        stageObserver: ((String,[Double])->Void)? = nil,
        phaseMemoryObserver: ((String)->Void)? = nil
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
        // Fail before consuming ANY SciPy/Numba draws or delivering
        // intermediate stages. Python only calls lognormal when > 0.05.
        let requestedMicroStd=settings.microstructureNM*0.001/pixelUM
        if requestedMicroStd>0.05 && !settings.useUnseededParallel {
            guard let microSeed=settings.numbaSeed else {
                throw Failure.invalid("原版 Numba 微结构随机线程未定义")
            }
            if settings.useFastStats && settings.fastStatsSeed != microSeed {
                throw Failure.invalid(
                    "原版 fast_stats 与微结构必须接续同一 Numba 单线程 RNG 状态"
                )
            }
        }
        let pixels=width*height
        let maxLayers=measured.maxima
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
        // Original measured inversion is deterministic, before each
        // channel's SciPy/Numba draws. Preserve full nine-field layout when
        // an observer requires the exact Python sublayer stage snapshot.
        // Normal production retains only the current channel's 3 sublayers.
        // RNG order remains ch outer / sl inner; no Float32 or tiling.
        let retainAllSublayers=stageObserver != nil
        var layerInputs=[Double](
            repeating:0,count:pixels*(retainAllSublayers ? 9 : 3)
        )
        var inputCMY=[Double](repeating:0,count:3)
        var layerScratch=[Double](repeating:0,count:9)
        if retainAllSublayers {
            for p in 0..<pixels {
                let k=p*3
                for ch in 0..<3 { inputCMY[ch]=densityCMY[k+ch] }
                if let sublayersInto=measured.sublayersInto {
                    try sublayersInto(inputCMY,&layerScratch)
                } else {
                    layerScratch=try measured.sublayers(inputCMY)
                }
                guard layerScratch.count==9,
                      layerScratch.allSatisfy({$0.isFinite}) else {
                    throw Failure.invalid("原版胶片三亚层密度未完整计算")
                }
                for i in 0..<9 {layerInputs[p*9+i]=layerScratch[i]}
            }
            stageObserver?("sourceGrainSublayers",layerInputs)
        }

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
        // Saturation is reconstructed from the exact stored probability.
        // No extra full-resolution Double saturation field is needed.
        // Build116: dye cloud carries ONE channel per source sublayer.
        // Reuse its scalar buffer for full-frame FIR/YVV output.
        var cloud=settings.dyeCloudBlurUM>0
            ? [Double](repeating:0,count:pixels) : []
        var controlledFastSampler:OriginalSourceNumbaFastCounts? =
            settings.useFastStats && !settings.useUnseededParallel
                ? OriginalSourceNumbaFastCounts(seed:settings.fastStatsSeed!)
                : nil
        // Create the independent worker RNG states ONCE before the first
        // fast_stats array, then keep them alive through all nine layers
        // and the later Numba lognormal microstructure. SciPy remains on
        // its original fixed per-sublayer seeds when fast_stats is OFF.
        let multiworker:OriginalSourceNumbaParallelWorkers? =
            settings.useUnseededParallel &&
            (settings.useFastStats || requestedMicroStd>0.05)
                ? try OriginalSourceNumbaParallelWorkers(
                    workerCount:settings.parallelWorkerCount==0
                        ? OriginalSourceNumbaParallelWorkers.defaultWorkers
                        : settings.parallelWorkerCount
                  )
                : nil
        // One serial count plane per render. No retained alias across
        // sublayers; release before the late microstructure allocation.
        // Parallel workers and the observed reference keep their old paths.
        var serialCounts=[Int64]()
        for ch in 0..<3 {
            let uniformity=settings.uniformity[ch]
            if !retainAllSublayers {
                // Invert only this channel's three measured layers when
                // the production profile provides its exact channel writer.
                // Keep 3 Float64 layers per pixel, not 9. RNG unchanged.
                for p in 0..<pixels {
                    let k=p*3
                    for c in 0..<3 {inputCMY[c]=densityCMY[k+c]}
                    if p & 4095 == 0 {try Task.checkCancellation()}
                    if let channelWriter=measured.channelSublayersInto {
                        try channelWriter(inputCMY,ch,&layerScratch)
                        guard layerScratch.count==9,
                              layerScratch[ch].isFinite,
                              layerScratch[3+ch].isFinite,
                              layerScratch[6+ch].isFinite else {
                            throw Failure.invalid("原版胶片当前通道三亚层密度无效")
                        }
                    } else {
                        if let sublayersInto=measured.sublayersInto {
                            try sublayersInto(inputCMY,&layerScratch)
                        } else {
                            layerScratch=try measured.sublayers(inputCMY)
                        }
                        guard layerScratch.count==9,
                              layerScratch.allSatisfy({$0.isFinite}) else {
                            throw Failure.invalid("原版胶片三亚层密度未完整计算")
                        }
                    }
                    for sl in 0..<3 {
                        layerInputs[p*3+sl]=layerScratch[sl*3+ch]
                    }
                }
            }
            phaseMemoryObserver?("grain_channel_\(ch)_inputs_ready")
            for sl in 0..<3 {
                let li=sl*3+ch
                let n=particleN[li],od=densityOD[li]
                let minimum=minLayers[li],maximum=densityMax[li]
                for p in 0..<pixels {
                    let sourceD=layerInputs[retainAllSublayers ? p*9+li : p*3+sl]+minimum
                    let probability=min(1.0-1e-6,max(1e-6,sourceD/maximum))
                    let saturation=1.0-probability*uniformity*(1.0-1e-6)
                    probabilities[p]=probability
                    rates[p]=n/saturation
                }
                // Scoped read-only view dies at the end of this sublayer.
                // The next iteration may mutate serialCounts without COW.
                let counts:[Int64]
                if !retainAllSublayers && (!settings.useFastStats || multiworker==nil) {
                    // One event at each boundary, never a per-pixel log.
                    // Timing includes all source RNG draws for that phase.
                    phaseMemoryObserver?("grain_\(ch)_\(sl)_poisson_begin")
                    let poissonCompleted:(()->Void)? = phaseMemoryObserver.map { observer in
                        {observer("grain_\(ch)_\(sl)_poisson_done")}
                    }
                    if settings.useFastStats {
                        try controlledFastSampler!.runOriginalTwoPhaseCountsInto(
                            rates:rates,probabilities:probabilities,counts:&serialCounts,
                            poissonCompleted:poissonCompleted
                        )
                    } else {
                        try OriginalSourceSciPySampler.drawLayerInto(
                            rates:rates,probabilities:probabilities,
                            seed:UInt32(ch+sl*10),counts:&serialCounts,
                            poissonCompleted:poissonCompleted
                        )
                    }
                    phaseMemoryObserver?("grain_\(ch)_\(sl)_binomial_done")
                    counts=serialCounts
                } else if settings.useFastStats {
                    if let multiworker {
                        // Default Python fast_stats is unseeded per worker.
                        // The same workers persist through every sublayer.
                        counts=try multiworker.particleLayer(
                            rates:rates,probabilities:probabilities
                        )
                    } else {
                        // Existing certified one-worker source bit replay.
                        counts=try controlledFastSampler!.runOriginalTwoPhaseCounts(
                            rates:rates,probabilities:probabilities
                        )
                    }
                } else {
                    counts=try OriginalSourceSciPySampler.drawLayer(
                        rates:rates,probabilities:probabilities,
                        seed:UInt32(ch+sl*10)
                    )
                }
                // dye-cloud blur_particle in grain.py deliberately passes
                // blur_dye_clouds_um WITHOUT dividing by pixelUM, then
                // multiplies sqrt(optical density per particle).
                let sigma=settings.dyeCloudBlurUM*sqrt(od)
                if sigma>0 {
                    for p in 0..<pixels {
                        let saturation=1.0-probabilities[p]*uniformity*(1.0-1e-6)
                        cloud[p]=Double(counts[p])*od*saturation
                    }
                    // The previous RGB filter wrote channel zero only.
                    // Preserve same full-frame reflect FIR/YVV in Float64,
                    // without allocating two unused RGB channels.
                    if retainAllSublayers {
                        try SourceGrainScalarGaussian.blurInPlace(
                            &cloud,width:width,height:height,sigma:sigma
                        )
                    } else {
                        // All three samplers have completed synchronously;
                        // no later code reads rates until the next sublayer
                        // overwrites every element. Borrow that dead plane.
                        // No additional scratch survives into the next draw.
                        try SourceGrainScalarGaussian.blurInPlace(
                            &cloud,width:width,height:height,sigma:sigma,
                            intermediate:&rates
                        )
                    }
                    for p in 0..<pixels {out[p*3+ch]+=cloud[p]}
                } else {
                    for p in 0..<pixels {
                        let saturation=1.0-probabilities[p]*uniformity*(1.0-1e-6)
                        out[p*3+ch]+=Double(counts[p])*od*saturation
                    }
                }
            }
        }
        serialCounts.removeAll(keepingCapacity:false)
        phaseMemoryObserver?("grain_particle_clouds_ready")
        stageObserver?("sourceGrainDyeClouds",out)

        // Build117: release the current 3-layer (or observed 9-layer) field,
        // 2 Poisson/Binomial preparation fields (2 Double/px) and dye-cloud
        // scalar dye-cloud workspace are dead after this final SciPy/fast_stats draw.
        // Explicitly relinquish their storage BEFORE allocating Numba
        // microstructure and the final Gaussian workspaces. This does not
        // change RNG order, Float64 arithmetic or any observed stage data;
        // diagnostic closures may independently retain their snapshots.
        layerInputs.removeAll(keepingCapacity:false)
        probabilities.removeAll(keepingCapacity:false)
        rates.removeAll(keepingCapacity:false)
        cloud.removeAll(keepingCapacity:false)
        phaseMemoryObserver?("grain_particle_scratch_released")

        // Upstream fast_lognormal_from_mean_std(mean=1,std=30nm/px);
        // only enabled if std > 0.05. Controlled Numba one-worker draw.
        let microStd=settings.microstructureNM*0.001/pixelUM
        let microBlur=settings.microstructureUM/pixelUM
        if microStd>0.05 {
            var clump:[Double]
            if let multiworker {
                // Real concurrent independent per-worker RNG stream.
                // Each render is unseeded and may differ, as in original
                // Numba default. Never report bit-for-bit Python parity.
                clump=try multiworker.microstructure(
                    count:pixels*3,microStd:microStd
                )
            } else {
                guard let seed=settings.numbaSeed else {
                    throw Failure.invalid("原版 Numba 微结构随机线程未定义")
                }
                // Preserve previously certified single-worker seed 8888.
                var numba=OriginalSourceNumbaSingleThreadNormal(seed:seed)
                // Only the deterministic coefficients are reusable.
                // Observed reference retains the original per-sample math.
                let prepared=retainAllSublayers ? nil :
                    try OriginalSourceMicrostructure.PreparedLognormal(microStd:microStd)
                clump=[Double](repeating:0,count:pixels*3)
                for ix in clump.indices {
                    let normal:Double
                    if settings.useFastStats {
                        normal=try controlledFastSampler!.nextMicrostructureNormal()
                    } else {
                        normal=try numba.nextNormal()
                    }
                    if let prepared {
                        clump[ix]=try prepared.sample(z:normal)
                    } else {
                        clump[ix]=try OriginalSourceMicrostructure.lognormal(
                            microStd:microStd,z:normal
                        )
                    }
                }
            }
            if microBlur>0.4 {
                // Build147-C: the production clump is locally owned and
                // consumed once. Avoid a separate RGB result frame.
                // Keep the allocating reference for observed stage parity.
                if retainAllSublayers {
                    clump=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                        clump,width:width,height:height,
                        coreSigma:microBlur,tailSigma:0,tailWeight:0
                    )
                } else {
                    try SourceSpatialDIRConvolution.diffuseInPlaceMemoryBounded(
                        &clump,width:width,height:height,
                        coreSigma:microBlur,tailSigma:0,tailWeight:0
                    )
                }
            }
            if retainAllSublayers {
                for ix in out.indices {out[ix]*=clump[ix]}
            } else {
                try multiplyMicrostructureSIMD(&out,clump)
            }
        }
        phaseMemoryObserver?("grain_microstructure_ready")
        stageObserver?("sourceGrainMicrostructure",out)

        if retainAllSublayers {
            for p in 0..<pixels {
                for ch in 0..<3 {
                    out[p*3+ch]-=settings.densityMin[ch]
                }
            }
        } else {
            try subtractDensityMinSIMD(&out,settings.densityMin)
        }
        phaseMemoryObserver?("grain_density_min_removed")
        if settings.grainBlur>0 {
            // Observers can retain the earlier CMY snapshots. Only the
            // unobserved, locally owned production result is mutated.
            if retainAllSublayers {
                out=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                    out,width:width,height:height,
                    coreSigma:settings.grainBlur,tailSigma:0,tailWeight:0
                )
            } else {
                try SourceSpatialDIRConvolution.diffuseInPlaceMemoryBounded(
                    &out,width:width,height:height,
                    coreSigma:settings.grainBlur,tailSigma:0,tailWeight:0
                )
            }
        }
        guard out.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版颗粒输出出现 NaN/Inf，拒绝静默降级")
        }
        phaseMemoryObserver?("grain_final_blur_ready")
        stageObserver?("sourceGrainFinalDensity",out)
        return out
    }

    /// Source grain.py::apply_grain_to_density, selected when
    /// grain.sublayers_active=false. This is NOT the measured 3x3 path.
    /// Keep each channel/sub-layer SciPy seed equal to ch+10*sublayer.
    static func applySingleLayer(
        _ densityCMY:[Double],width:Int,height:Int,
        pixelUM:Double,maximum:[Double],settings:Settings,
        stageObserver:((String,[Double])->Void)?=nil
    ) throws -> [Double] {
        try settings.validate()
        // Upstream apply_grain() deliberately does not forward
        // use_fast_stats into apply_grain_to_density(). For this branch,
        // even useFastStats=true must keep the SciPy source path.
        guard settings.active,!settings.sublayersActive,
              width>0,height>0,width<=Int.max/height/3,
              densityCMY.count==width*height*3,
              densityCMY.allSatisfy({ $0.isFinite }),
              pixelUM.isFinite,pixelUM>0,
              maximum.count==3,maximum.allSatisfy({$0.isFinite && $0>0})
        else {
            throw Failure.invalid("源单层颗粒需要完整 Float64 胶片 H-D 和 SciPy RandomState")
        }
        let pixels=width*height
        var result=[Double](repeating:0,count:densityCMY.count)
        var rates=[Double](repeating:0,count:pixels)
        var probabilities=[Double](repeating:0,count:pixels)
        var saturations=[Double](repeating:0,count:pixels)
        for ch in 0..<3 {
            let totalMax=maximum[ch]+settings.densityMin[ch]
            let n=Double(pixelUM*pixelUM) /
                (settings.particleAreaUM2*settings.particleScale[ch]) /
                Double(settings.nSubLayers)
            let opticalParticle=totalMax/n
            guard totalMax.isFinite,totalMax>0,n.isFinite,n>0,
                  opticalParticle.isFinite else {
                throw Failure.invalid("原版单层颗粒数量或密度溢出")
            }
            for layer in 0..<settings.nSubLayers {
                for p in 0..<pixels {
                    let density=densityCMY[p*3+ch]+settings.densityMin[ch]
                    let probability=min(1.0-1e-6,max(1e-6,density/totalMax))
                    let saturation=1-probability*settings.uniformity[ch]*(1-1e-6)
                    probabilities[p]=probability
                    saturations[p]=saturation
                    rates[p]=n/saturation
                }
                let counts=try OriginalSourceSciPySampler.drawLayer(
                    rates:rates,probabilities:probabilities,
                    seed:UInt32(ch+layer*10)
                )
                for p in 0..<pixels {
                    result[p*3+ch] +=
                        Double(counts[p])*opticalParticle*saturations[p]
                }
            }
            for p in 0..<pixels {
                result[p*3+ch] =
                    result[p*3+ch]/Double(settings.nSubLayers) -
                    settings.densityMin[ch]
            }
        }
        stageObserver?("sourceGrainSingleLayer",result)
        // The single-layer upstream uses grain_blur > 0.4. The 3x3
        // grain.py path uses > 0.0: never conflate the two boundaries.
        if settings.grainBlur>0.4 {
            result=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                result,width:width,height:height,
                coreSigma:settings.grainBlur,tailSigma:0,tailWeight:0
            )
        }
        guard result.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("原版单层颗粒输出 NaN/Inf")
        }
        stageObserver?("sourceGrainFinalDensity",result)
        return result
    }
}
