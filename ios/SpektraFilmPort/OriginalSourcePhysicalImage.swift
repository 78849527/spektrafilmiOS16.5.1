import Foundation
import CoreGraphics
import ImageIO
#if os(iOS)
import os
#endif

/// v1.8.22: opt-in full-source *nonlinear* optical spatial image pipeline.
/// It calls the ACTUAL Swift production Hanatos, H-D, optical enlarger,
/// s023 paper development and measured-spectrum scanner for EACH pixel.
/// Unlike the older exact-DIR path, it never creates or interpolates a
/// colour 3D LUT. Only original 2D FIR/YVV is used for spatial DIR.
/// Unsupported stochastic grain, RAW and post-scanner effects
/// remain deliberately unavailable, without a silent approximate fallback.
///
/// Remaining limits: some original measured data are Float32-packed; this
/// is not all-modules Float64 parity or source Numba stochastic emulation.
enum OriginalSourcePhysicalImage {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    /// 13 MP is a metadata ceiling, NOT a promise of enough device memory.
    /// Unlike v1.8.23, actual process and physical memory budgets are checked
    /// before any full-size ImageIO decode. This includes the user's
    /// 3888x2592 (10.08MP) only when measured available memory permits.
    static let maximumPixels = 13_000_000
    // Build114: full-frame DIR now uses an in-place channel accumulator.
    // The original conservative 120 B/pixel was reduced by ONLY the 8 B/pixel
    // measured-array peak delta from replacing the 3-channel result array
    // with per-channel source + accumulator. The 13MP safety gate still
    // requires independent real-device RSS/Jetsam evidence.
    static let estimatedPeakBytesPerPixel: UInt64 = 112
    // Full-size scanner finish requires an additional 3-channel Double
    // filtered result and two 1-channel Double Gaussian workspaces.
    static let scannerFinishExtraBytesPerPixel: UInt64 = 40
    // Controlled source glare currently retains a 3-channel Double
    // source field, full-frame filtered output and two 1-channel works.
    // Conservative peak budget; no automatic smaller-image fallback.
    static let scannerGlareExtraBytesPerPixel: UInt64 = 96
    static let cameraLensExtraBytesPerPixel: UInt64 = 40
    static let filmHalationExtraBytesPerPixel: UInt64 = 120
    static let printDiffusionExtraBytesPerPixel: UInt64 = 40

    static func validateMemoryBudget(
        width:Int,height:Int,
        additionalBytesPerPixel:UInt64=0,
        physicalMemory:UInt64?=nil,
        processAvailableMemory:UInt64?=nil,
        cameraDiffusion:(settings:OriginalSourceDiffusion.Settings,pixelUM:Double)?=nil,
        paperDiffusion:(settings:OriginalSourceDiffusion.Settings,pixelUM:Double)?=nil
    ) throws {
        guard width>0,height>0,width<=8192,height<=8192,
              width<=maximumPixels/height else {
            throw Failure.invalid(
                "逐像素全光学（实验）：当前最大 1300 万像素，单边不超过 8192。" +
                "禁止自动缩图或切换快速算法。"
            )
        }
        let physical=physicalMemory ?? ProcessInfo.processInfo.physicalMemory
        let headroom:UInt64?
        if let explicit=processAvailableMemory {
            headroom=explicit
        } else {
            #if os(iOS)
            headroom=UInt64(os_proc_available_memory())
            #else
            headroom=nil
            #endif
        }
        // Build91 preflight includes original reflect FFT full-frame
        // complex scratch and PSF for CAMERA and PAPER diffusion.
        // Do it before decoding or allocating photon/density frames.
        let plan=try Build91PhysicalMemory.plan(
            width:width,height:height,
            baseBytesPerPixel:estimatedPeakBytesPerPixel,
            additionalBytesPerPixel:additionalBytesPerPixel,
            physicalMemory:physical,processAvailable:headroom,
            camera:cameraDiffusion,paper:paperDiffusion
        )
        try Build91PhysicalMemory.validate(plan)
    }

    struct Parameters {
        let filmID: String
        let paperID: String
        let cameraEV: Double
        let paperEV: Double
        let dir: SpatialDIRSettings
        let print: OriginalPrintOptics.Settings
        let morph: OriginalPrintMorph.Settings
        /// Original DirCouplersParams.active=false bypasses BOTH chemistry
        /// and pre-DIR corrected curves. Default preserves prior production.
        var sourceCouplersActive: Bool = true
        /// Original diffusion_size_um=0 runs non-spatial DIR chemistry but
        /// skips FIR/YVV, without dividing by pixel_size_um.
        var sourceSpatialDiffusionEnabled: Bool = true
        /// Explicit original custom film DIR parameters. nil preserves the
        /// verified stock-specific original path without recalibration.
        var sourceDIR: Build84OriginalFilmDIR.RuntimeSettings? = nil
        // Separate opt-in deterministic Python source scan finishing.
        // Defaults preserve all user-validated v1.8.25 RGB and memory paths.
        var scannerOptics: OriginalSourceScannerOptics.Settings = .init()
        // OFF unless user explicitly chooses controlled *single-worker*
        // glare. This is NOT unseeded original prange equivalence.
        var scannerGlare: OriginalSourceScannerGlare.Settings = .init(active:false)
        var scannerGlareSeed: UInt32? = nil
        /// Source ScannerParams black_correction / white_correction.
        /// Default false/false preserves the v1.8.58 imaging baseline;
        /// opt-in executes source per-stock Y calibration in true XYZ.
        var sourceColorReference: Build87OriginalColorReference.Settings = .init()
        /// Exact io.output_cctf_encoding. true is the existing default
        /// (encoded display sRGB); false preserves source LINEAR RGB
        /// after gamut compression and optional scan-lens filtering.
        var sourceOutputCCTFEncoding = true
        /// Opt-in original source output gamut dispatcher. nil preserves
        /// the existing Build88 ACES and CI image behaviour. A nonnil
        /// setting receives RAW linear sRGB after true spectral XYZ;
        /// CAM16-UCS executes Float64 appearance per pixel, NOT 33³ LUT.
        var sourceOutputGamut: Build89OriginalOutputGamut.Settings? = nil
        // Original grain.py 3x3 sublayer SciPy counts + dye clouds +
        // controlled one-worker Numba microstructure + final blur.
        // OFF by default, separate from Gaussian/Metal fast grain.
        var sourceGrain: OriginalSourcePhysicalGrain.Settings = .init()
        var cameraOptics: OriginalSourceCameraOptics.Settings = .init()
        var filmHalation: OriginalSourceFilmHalation.Settings = .init()
        // Upstream SettingsParams.rgb_to_raw_method plus camera UV/IR
        // spectral bandpass; all stages remain per-pixel Double.
        var cameraRawMethod: SpectralPhysics.CameraRawMethod = .hanatos2025
        // The app's current strict 8-bit ingress is explicitly sRGB.
        // ProPhoto linear is a separate *numerical engine* source branch
        // until real ICC/raw ingress has passed independent verification.
        var cameraInputColorSpace: OriginalHanatosResponse.InputColorSpace = .sRGB
        /// Source InputGamutCompressSpec().algorithm. Default .xy unchanged.
        /// .oklch REBUILDS the original Hanatos TC LUT (not post RGB).
        var sourceInputGamutAlgorithm: Build81OriginalInputGamut.Algorithm = .xy
        var cameraBandpass: OriginalSourceCameraBandpass.Settings = .init()
        /// Build83 literal original source post-optics film-reference photon
        /// multiplier. 1.0 is an explicit uncalibrated diagnostic default;
        /// the Python source calibration service is NOT yet ported.
        var cameraFilmingReferenceScale: Double = 1.0
        /// Explicit original 81-wavelength Hanatos TC LUT full recompute,
        /// exposing the source poly4 surface even when UV/IR is off.
        var hanatosSourceRecompute: Bool = false
        // Original PrintingStage.expose: optical paper photon domain,
        // after enlarger/preflash/EV and before paper H-D.
        var printDiffusion: OriginalSourceDiffusion.Settings = .init()

        func validate() throws {
            guard SpectralPhysics.supportedFilmIDs.contains(filmID),
                  SpectralPhysics.supportedPaperIDs.contains(paperID),
                  cameraEV.isFinite && abs(cameraEV) <= 4,
                  paperEV.isFinite && abs(paperEV) <= 4,
                  dir.enabled && dir.valid && dir.sourceConvolutionEnabled,
                  print.isValid else {
                throw Failure.invalid(
                    "原版逐像素物理模式需要有效胶片/相纸、源 DIR 和原版光学参数"
                )
            }
            if let sourceDIR {
                try sourceDIR.validate()
                guard sourceCouplersActive else {
                    throw Failure.invalid(
                        "自定义 DIR 与旧版关闭 DIR 开关冲突，请明确选择一种模式"
                    )
                }
            }
            try sourceColorReference.validate()
            if let sourceOutputGamut {
                try sourceOutputGamut.validate()
                // Source destination matrices are implemented for wide
                // output colours, but physical JPEG ICC tagging is NOT.
                // Avoid exporting P3/BT2020 numeric values as sRGB bytes.
                guard sourceOutputGamut.outputSpace == .sRGB else {
                    throw Failure.invalid(
                        "Build89 Display P3/BT.2020 数值色域算法已单独验证，" +
                        "但真实图像 ICC 与文件标记未验收，" +
                        "禁止将广色域线性 RGB 当 sRGB JPEG 导出"
                    )
                }
            }
            // Source scanning.py order is:
            // measured XYZ -> B/W Y transform -> stochastic XYZ glare
            // -> XYZ_to_RGB -> gamut -> FIR/YVV -> output CCTF.
            // Build88 source-stage tests cover the combined operations.
            try scannerOptics.validate()
            try scannerGlare.validate()
            try sourceGrain.validate()
            if scannerGlare.active && scannerGlare.percent > 0 {
                guard !SpectralPhysics.isPositiveFilm(filmID),
                      (!scannerGlare.consumesNumbaRandomness ||
                       scannerGlareSeed != nil) else {
                    throw Failure.invalid(
                        "源扫描眩光仅用于负片相纸；实际 Numba 正态抽样" +
                        "必须提供受控单线程种子；sigma<1e-6 的原版" +
                        "无随机抽样路径允许省略 seed"
                    )
                }
            }
            try cameraOptics.validate()
            try filmHalation.validate()
            try cameraBandpass.validate()
            guard cameraFilmingReferenceScale.isFinite &&
                  cameraFilmingReferenceScale >= 0 else {
                throw Failure.invalid(
                    "原版摄影黑白参考 RAW 光子倍率无效；禁止自动代入估算值"
                )
            }
            if cameraInputColorSpace == .proPhotoLinear &&
                cameraRawMethod != .hanatos2025 {
                throw Failure.invalid(
                    "原版 ProPhoto 仅在完整 Hanatos 光谱输入路径已实现，"
                    + "不支持当前 Mallett 组合"
                )
            }
            try printDiffusion.validate()
            if printDiffusion.active && printDiffusion.strength>0 &&
                printDiffusion.spatialScale>0 &&
                SpectralPhysics.isPositiveFilm(filmID) {
                throw Failure.invalid(
                    "原版放大机扩散只能用于负片相纸印相，" +
                    "正片绕过原版放大机，禁止静默应用在扫描后"
                )
            }
            // Build82: UV/IR is supported by a complete source-spectra
            // recomputation in Hanatos; backend failures remain explicit.
            if !SpectralPhysics.isPositiveFilm(filmID) && !print.enabled {
                throw Failure.invalid(
                    "负片逐像素物理模式需要启用原版放大机光学印相和相纸 H-D"
                )
            }
        }

        func createEngine() throws -> SpectralPhysics {
            try validate()
            return try SpectralPhysics(
                filmID: filmID, paperID: paperID,
                sourceScanner: true,
                scannerBlackWhite: false,
                cam16Gamut: false,
                printReferenceCorrection: false,
                printMorph: morph,
                printOptics: print,
                cameraExposureEV: cameraEV,
                hanatosPrecision: .originalFloat64,
                sourceMeasuredFloat64: true,
                cameraRawMethod: cameraRawMethod,
                cameraInputColorSpace:cameraInputColorSpace,
                cameraBandpass: cameraBandpass,
                hanatosSourceRecompute: hanatosSourceRecompute,
                sourceInputGamutAlgorithm:sourceInputGamutAlgorithm,
                sourceColorReference: sourceColorReference.enabled
                    ? sourceColorReference : nil,
                sourceFilmDensityMin: sourceGrain.densityMin
            )
        }
    }

    /// Compatibility API for existing Python image diagnostic fixtures.
    /// Large-image production calls developInPlace, which takes unique
    /// ownership of an existing ImageIO Double buffer instead of retaining
    /// the source and also allocating separate logRaw + printed frames.
    static func develop(
        _ input: OriginalSourcePixelIO.Frame,
        parameters: Parameters,
        stageDoubleObserver: ((String, [Double]) -> Void)? = nil
    ) throws -> OriginalSourcePixelIO.Frame {
        var frame=input
        try developInPlace(
            &frame,parameters:parameters,
            stageDoubleObserver:stageDoubleObserver
        )
        return frame
    }

    /// Full-resolution source photon / H-D / DIR / print / scan, reusing
    /// one mutable full-size Double RGB array for input, camera log exposure
    /// AND final encoded RGB. Full-dimension FIR and YVV remain exact:
    /// NO independent tiles, cropped Gaussian support or altered seed.
    static func developInPlace(
        _ frame: inout OriginalSourcePixelIO.Frame,
        parameters: Parameters,
        stageDoubleObserver: ((String, [Double]) -> Void)? = nil,
        phaseMemoryObserver: ((String) -> Void)? = nil
    ) throws {
        try parameters.validate()
        let w=frame.width,h=frame.height
        let activePrintDiffusion=parameters.printDiffusion.active &&
            parameters.printDiffusion.strength>0 &&
            parameters.printDiffusion.spatialScale>0
        let controlledScannerGlare=parameters.scannerGlare.active &&
            parameters.scannerGlare.percent>0
        let controlledFilmGrain=parameters.sourceGrain.active
        // The production paper taps are opt-in; reserve their 2x3 Double
        // buffers in the memory gate BEFORE any full-frame allocation.
        let capturePaperStages=stageDoubleObserver != nil &&
            !SpectralPhysics.isPositiveFilm(parameters.filmID)
        let cameraDiffusionEnabled=(parameters.cameraOptics.active ||
            parameters.filmHalation.active) &&
            parameters.cameraOptics.diffusion.active &&
            parameters.cameraOptics.diffusion.strength>0 &&
            parameters.cameraOptics.diffusion.spatialScale>0
        let pixelUMForFFT=parameters.cameraOptics.filmFormatMM *
            1000.0 / Double(max(w,h))
        let cameraFFT:(settings:OriginalSourceDiffusion.Settings,
                       pixelUM:Double)? = cameraDiffusionEnabled
            ? (parameters.cameraOptics.diffusion,pixelUMForFFT) : nil
        let paperFFT:(settings:OriginalSourceDiffusion.Settings,
                      pixelUM:Double)? = activePrintDiffusion
            ? (parameters.printDiffusion,pixelUMForFFT) : nil
        // Build106: ONE audited feature ledger for both pre-decode and
        // the actual in-place renderer. A diagnostic callback may retain
        // every source Float64 tap, not just the latest three-channel tap.
        let extraPeakBytesPerPixel=Build106SourceMemoryLedger.productionAdditional(
            scannerFinish:parameters.scannerOptics.active,
            scannerGlare:controlledScannerGlare,
            grain:controlledFilmGrain,
            grainSublayers:parameters.sourceGrain.sublayersActive,
            cameraActive:parameters.cameraOptics.active,
            cameraLens:parameters.cameraOptics.needsWholeImageBlur,
            filmHalation:parameters.filmHalation.active,
            paperDiffusion:parameters.printDiffusion.active,
            stageObserver:stageDoubleObserver != nil,
            paperStageObserver:capturePaperStages,
            outputGamut:parameters.sourceOutputGamut != nil,
            parallelGrain:parameters.sourceGrain.useUnseededParallel
        )
        try validateMemoryBudget(
            width:w,height:h,
            additionalBytesPerPixel:extraPeakBytesPerPixel,
            cameraDiffusion:cameraFFT,paperDiffusion:paperFFT
        )
        guard frame.rgb.count==w*h*3,
              frame.rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else {
            throw Failure.invalid(
                "逐像素原版显影输入 RGB 尺寸／颜色范围错误，" +
                "不能静默截断或改用移动模式"
            )
        }

        phaseMemoryObserver?("source_input_ready")
        let engine=try parameters.createEngine()
        let source=try engine.sourceSpatialFilmParameters()
        let dynamicDIR:Build84OriginalFilmDIR.Prepared?
        if let custom=parameters.sourceDIR {
            let measured=try engine.sourceSpatialMeasuredHDCurves()
            dynamicDIR=try Build84OriginalFilmDIR.prepare(
                stock:parameters.filmID,positive:source.positive,
                logExposure:measured.logExposure,
                normalizedDensityCurves:measured.normalizedDensityCurves,
                settings:custom
            )
        } else {
            dynamicDIR=nil
        }
        let dirOn=dynamicDIR?.settings.active ?? parameters.sourceCouplersActive
        let size=w*h*3
        var inhibitors=[Double](repeating:0,count:size)
        var initialObserved:[Double]?=stageDoubleObserver == nil
            ? nil : [Double](repeating:0,count:size)
        // Capture only the actual encoded RGB multiplied by source metering
        // BEFORE conversion into film photons. This is the source rgb_pre
        // interface on supported no-crop/no-rescale sRGB inputs, NOT a
        // claim that original ProPhoto/RAW/crop are fully implemented.
        let cameraPreActive=parameters.cameraOptics.active ||
            parameters.filmHalation.active
        var rgbPreObserved:[Double]? = stageDoubleObserver != nil &&
            cameraPreActive ? [Double](repeating:0,count:size) : nil

        // Original Python chronological camera stage:
        // 1. full-frame decoded RGB -> source exposure-metering preview,
        // 2. global RGB auto-exposure before Hanatos spectral conversion,
        // 3. film exposure compensation in linear RAW photon units,
        // 4. global image-maximum highlight boost (Numba scalar formula),
        // 5. source Double camera 2D PSF+reflect FFT diffusion if enabled,
        // 6. source full-dimension reflect FIR/YVV camera lens Gaussian,
        // 7. source scattering/halation if enabled; then log10 -> H-D/DIR.
        //
        // RAW modes are disabled by default; the established v1.8.29 path
        // below remains byte-for-byte unchanged if all options are off.
        if cameraPreActive {
            let autoEV=try OriginalSourceCameraOptics.measureAutoExposureEV(
                encodedRGB:frame.rgb,width:w,height:h,
                method:parameters.cameraOptics.metering
            )
            stageDoubleObserver?("cameraAutoExposureEV",[autoEV])
            let autoScale=pow(2.0,autoEV)
            guard autoScale.isFinite && autoScale>0 else {
                throw Failure.invalid("原版源测光 RGB 倍率溢出")
            }
            for p in 0..<(w*h) {
                let k=p*3
                let rgb=[
                    frame.rgb[k]*autoScale,
                    frame.rgb[k+1]*autoScale,
                    frame.rgb[k+2]*autoScale
                ]
                // Store the same pre-exposure input that the production
                // photon conversion consumes, without recalculating it.
                for c in 0..<3 { rgbPreObserved?[k+c]=rgb[c] }
                let photons=try engine.sourceCameraRaw(
                    encodedRGB:rgb,cameraEV:parameters.cameraEV
                )
                for c in 0..<3 { frame.rgb[k+c]=photons[c] }
            }
            if let rgbPreObserved {
                stageDoubleObserver?("rgbPre",rgbPreObserved)
            }
            stageDoubleObserver?("cameraRaw",frame.rgb)
            try OriginalSourceCameraOptics.boostHighlightsInPlace(
                &frame.rgb,
                boostEV:parameters.cameraOptics.boostEV,
                boostRange:parameters.cameraOptics.boostRange,
                protectEV:parameters.cameraOptics.protectEV
            )
            stageDoubleObserver?("cameraBoost",frame.rgb)
            // Original FilmingStage.expose chronology is:
            //   boost_highlights -> camera diffusion_filter PSF -> 
            //   lens Gaussian -> film scattering & halation -> log10 H-D.
            // This is the real Double FFT source, never CI bloom/blur.
            let diffusion=parameters.cameraOptics.diffusion
            if diffusion.active && diffusion.strength > 0 &&
                diffusion.spatialScale > 0 {
                let pixelUM=parameters.cameraOptics.filmFormatMM *
                    1000.0 / Double(max(w,h))
                frame.rgb=try OriginalSourceDiffusion.apply(
                    frame.rgb,width:w,height:h,pixelUM:pixelUM,
                    settings:diffusion
                )
                stageDoubleObserver?("cameraDiffusion",frame.rgb)
            }
            if parameters.cameraOptics.needsWholeImageBlur {
                frame.rgb=try OriginalSourceCameraOptics.applyLensBlur(
                    frame.rgb,width:w,height:h,
                    settings:parameters.cameraOptics
                )
            }
            stageDoubleObserver?("cameraLensBlur",frame.rgb)
            if parameters.filmHalation.active {
                try OriginalSourceFilmHalation.applyInPlace(
                    &frame.rgb,width:w,height:h,
                    settings:parameters.filmHalation
                )
                stageDoubleObserver?("filmScatterHalation",frame.rgb)
            }
        }
        // If no camera pre-stage was selected, source pre-processing is
        // identity on the supported uncropped, 1:1 8-bit sRGB input.
        // Preserve the exact former production image (no copies if not observed).
        if !cameraPreActive {
            stageDoubleObserver?("rgbPre",frame.rgb)
        }
        // Compute initial H-D and donor/receiver inhibitors from either the
        // original unchanged legacy source or optional source-RAW pipeline.
        for p in 0..<(w*h) {
            let k=p*3
            let sample=[frame.rgb[k],frame.rgb[k+1],frame.rgb[k+2]]
            let initial=try (parameters.cameraOptics.active || parameters.filmHalation.active)
                ? engine.sourceSpatialInputFromCameraRaw(
                    sample,filmingReferenceScale:parameters.cameraFilmingReferenceScale
                )
                : engine.sourceSpatialInput(
                    encodedRGB:sample,cameraEV:parameters.cameraEV
                )
            let initialDensity=try dynamicDIR?.develop(
                initial.rawLog,corrected:false
            ) ?? initial.initialDensity
            let sourceInhibition:[Double]
            if !dirOn {
                sourceInhibition=[0,0,0]
            } else if let dynamicDIR {
                sourceInhibition=try dynamicDIR.inhibitor(initialDensity)
            } else {
                sourceInhibition=try Build84OriginalFilmDIR.inhibitors(
                    density:initialDensity,
                    maximum:source.densityMaximum,
                    matrix:source.matrix,
                    positive:source.positive
                )
            }
            for receiver in 0..<3 {
                inhibitors[k+receiver]=sourceInhibition[receiver]
            }
            for c in 0..<3 {
                frame.rgb[k+c]=initial.rawLog[c]
                initialObserved?[k+c]=initialDensity[c]
            }
        }
        phaseMemoryObserver?("camera_photons_ready")
        stageDoubleObserver?("logRaw",frame.rgb)
        if let initialObserved {
            stageDoubleObserver?("initial",initialObserved)
        }
        stageDoubleObserver?("inhibitors",inhibitors)

        // All four exact source Gaussian passes operate on the entire
        // original image with TWO reusable 1-channel work arrays.
        // Only one additional 3-channel result buffer is ever retained.
        let pixelUM=parameters.dir.referencePixelSizeUM ??
            (36_000.0/Double(max(w,h)))
        let radius=parameters.dir.diffusionRadiusScale
        var diffused:[Double]
        if !dirOn {
            // Source active=false: no chemistry, no spatial filter.
            diffused=[Double](repeating:0,count:size)
        } else if !parameters.sourceSpatialDiffusionEnabled ||
                    dynamicDIR?.settings.diffusionSizeUM == 0 {
            // Source diffusion_size_um=0: skip filter, retain inhibitors.
            diffused=inhibitors
        } else {
            try SourceSpatialDIRConvolution.diffuseInPlaceMemoryBounded(
                &inhibitors,width:w,height:h,
                coreSigma:(dynamicDIR?.settings.diffusionSizeUM ?? 20.0)*radius/pixelUM,
                tailSigma:(dynamicDIR?.settings.diffusionTailUM ?? 200.0)*radius/pixelUM,
                tailWeight:dynamicDIR?.settings.diffusionTailWeight ?? parameters.dir.tailWeight
            )
            diffused=inhibitors
        }
        // Do not keep another full-frame 3-channel inhibitor buffer alive
        // while computing the real spectral paper/scan output.
        inhibitors.removeAll(keepingCapacity:false)
        phaseMemoryObserver?("spatial_DIR_ready")
        stageDoubleObserver?("diffused",diffused)

        var correctedObserved:[Double]?=stageDoubleObserver == nil
            ? nil : [Double](repeating:0,count:size)
        var densityObserved:[Double]?=stageDoubleObserver == nil
            ? nil : [Double](repeating:0,count:size)
        var paperLogObserved:[Double]? = capturePaperStages
            ? [Double](repeating:0,count:size) : nil
        var paperDensityObserved:[Double]? = capturePaperStages
            ? [Double](repeating:0,count:size) : nil
        // The exact source PrintingStage is fused with the scanner in the
        // current iOS implementation. Observe its REAL computed Double
        // boundaries from BOTH print paths, never call a second renderer.
        func recordPaper(_ offset:Int) -> (([Double],[Double]) -> Void)? {
            guard capturePaperStages else { return nil }
            return { logExposure,developedDensity in
                for ch in 0..<3 {
                    paperLogObserved?[offset+ch]=logExposure[ch]
                    paperDensityObserved?[offset+ch]=developedDensity[ch]
                }
            }
        }
        // Each corrected pixel is completely consumed before its
        // historical camera log buffer is overwritten by final scan RGB.
        for p in 0..<(w*h) {
            let k=p*3
            let corrected=(0..<3).map { c in
                frame.rgb[k+c]-diffused[k+c]
            }
            let density:[Double]
            if let dynamicDIR {
                density=try dynamicDIR.develop(corrected,corrected:dirOn)
            } else {
                density=try dirOn
                    ? engine.sourceSpatialDevelopCorrectedLog(corrected)
                    : engine.sourceSpatialDevelopInitialLog(corrected)
            }
            // PrintingStage source chronology: film CMY -> optical
            // paper raw -> source full-frame diffuser -> log10 -> paper
            // H-D -> original scanner. Never diffuse scanned RGB.
            let rgb:[Double]
            if controlledFilmGrain {
                // Delay print/scan until ALL 9 measured emulsion sublayers
                // have consumed source SciPy counts + source dye clouds.
                // This is pre-print optical-density CMY, not display RGB.
                rgb=density
            } else if activePrintDiffusion {
                rgb=try engine.sourceSpatialPrintPhoton(
                    filmDensity:density,paperEV:parameters.paperEV
                )
            } else if controlledScannerGlare ||
                        parameters.sourceOutputGamut != nil {
                // Store actual developed PAPER XYZ in the reusable Double
                // frame, not sRGB or post-gamut RGB.
                rgb=try engine.sourceSpatialScanXYZ(
                    filmDensity:density,paperEV:parameters.paperEV,
                    paperStageObserver:recordPaper(k)
                )
            } else {
                rgb=try (parameters.scannerOptics.active ||
                           !parameters.sourceOutputCCTFEncoding)
                    ? engine.sourceSpatialScanLinear(
                        filmDensity:density,paperEV:parameters.paperEV,
                        paperStageObserver:recordPaper(k)
                      )
                    : engine.sourceSpatialScan(
                        filmDensity:density,paperEV:parameters.paperEV,
                        paperStageObserver:recordPaper(k)
                      )
            }
            for c in 0..<3 {
                correctedObserved?[k+c]=corrected[c]
                densityObserved?[k+c]=density[c]
                frame.rgb[k+c]=rgb[c]
            }
        }
        // Build116 memory-only: all corrected film pixels have now
        // consumed the full-frame DIR field. Release this 3-channel
        // Float64 buffer BEFORE allocating source 3×3 grain workspace.
        // The observer, when enabled, already received its original tap.
        // No arithmetic, filter boundary or RGB output is modified.
        diffused.removeAll(keepingCapacity:false)
        phaseMemoryObserver?("film_density_ready_DIR_released")
        if let correctedObserved {
            stageDoubleObserver?("correctedLog",correctedObserved)
        }
        if let densityObserved {
            stageDoubleObserver?("density",densityObserved)
        }
        if controlledFilmGrain {
            let pixelUM=parameters.dir.referencePixelSizeUM ??
                (parameters.cameraOptics.filmFormatMM * 1000.0 / Double(max(w,h)))
            if parameters.sourceGrain.sublayersActive {
                frame.rgb=try OriginalSourcePhysicalGrain.apply(
                    frame.rgb,width:w,height:h,
                    pixelUM:pixelUM,
                    measured:engine.sourceSpatialGrainLayers(),
                    settings:parameters.sourceGrain,
                    stageObserver:stageDoubleObserver,
                    phaseMemoryObserver:phaseMemoryObserver
                )
            } else {
                frame.rgb=try OriginalSourcePhysicalGrain.applySingleLayer(
                    frame.rgb,width:w,height:h,pixelUM:pixelUM,
                    maximum:engine.sourceSpatialGrainSingleLayerMaximum(),
                    settings:parameters.sourceGrain,
                    stageObserver:stageDoubleObserver
                )
            }
            phaseMemoryObserver?("three_sublayer_grain_ready")
            stageDoubleObserver?("grainDensity",frame.rgb)
            // Original develop.py: apply_grain(DIR-developed film density)
            // THEN print_expose or direct reversal scan; never RGB overlay.
            for p in 0..<(w*h) {
                let k=p*3
                let density=[frame.rgb[k],frame.rgb[k+1],frame.rgb[k+2]]
                let printed:[Double]
                if activePrintDiffusion {
                    printed=try engine.sourceSpatialPrintPhoton(
                        filmDensity:density,paperEV:parameters.paperEV
                    )
                } else if controlledScannerGlare ||
                          parameters.sourceOutputGamut != nil {
                    printed=try engine.sourceSpatialScanXYZ(
                        filmDensity:density,paperEV:parameters.paperEV,
                        paperStageObserver:recordPaper(k)
                    )
                } else {
                    printed=try (parameters.scannerOptics.active ||
                           !parameters.sourceOutputCCTFEncoding)
                        ? engine.sourceSpatialScanLinear(
                            filmDensity:density,paperEV:parameters.paperEV,
                            paperStageObserver:recordPaper(k)
                          )
                        : engine.sourceSpatialScan(
                            filmDensity:density,paperEV:parameters.paperEV,
                            paperStageObserver:recordPaper(k)
                          )
                }
                for ch in 0..<3 {frame.rgb[k+ch]=printed[ch]}
            }
        }
        if activePrintDiffusion {
            let pixelUM=parameters.cameraOptics.filmFormatMM * 1000.0 /
                Double(max(w,h))
            // Raw paper photons are already multiplied by the enlarger EV.
            // The original source applies the PSF here, before paper CDF.
            frame.rgb=try OriginalSourceDiffusion.apply(
                frame.rgb,width:w,height:h,pixelUM:pixelUM,
                settings:parameters.printDiffusion
            )
            stageDoubleObserver?("printDiffusion",frame.rgb)
            for p in 0..<(w*h) {
                let k=p*3
                let output=try engine.sourceSpatialScanPrintedPhoton(
                    [frame.rgb[k],frame.rgb[k+1],frame.rgb[k+2]],
                    sourceLinearOutput:parameters.scannerOptics.active ||
                        !parameters.sourceOutputCCTFEncoding,
                    sourceXYZOutput:controlledScannerGlare ||
                        parameters.sourceOutputGamut != nil,
                    paperStageObserver:recordPaper(k)
                )
                for c in 0..<3 { frame.rgb[k+c]=output[c] }
            }
        }
        if let paperLogObserved {
            stageDoubleObserver?("paperLogExposure",paperLogObserved)
        }
        if let paperDensityObserved {
            stageDoubleObserver?("paperDevelopedDensity",paperDensityObserved)
        }
        if controlledScannerGlare {
            // Python scanning.py exact sequence for negative prints:
            // printed density -> XYZ [B/W adjustment is forbidden here]
            // -> source 2D random glare with normalized scanner lamp XYZ
            // -> per-pixel XYZ→linear sRGB→ACES gamut compression
            // -> optional scanner lens blur/unsharp -> sRGB CCTF.
            // One explicit seeded Numba worker, NOT unseeded prange parity.
            frame.rgb=try OriginalSourceScannerGlare.addToXYZ(
                frame.rgb,
                illuminantXYZ:engine.sourceSpatialScannerIlluminantXYZ(),
                width:w,height:h,
                settings:parameters.scannerGlare,
                controlledSeed:parameters.scannerGlareSeed
            )
            stageDoubleObserver?("scannerGlareXYZ",frame.rgb)
        }
        if let exactGamut=parameters.sourceOutputGamut {
            // Build89 source order: FULL spectral XYZ incl black/white
            // -> optional stochastic glare in XYZ -> RAW linear RGB
            // -> user-selected ORIGINAL output gamut (per-pixel CPU Double)
            // -> scanner FIR/YVV/unsharp -> optional output CCTF.
            // This NEVER calls a 33³ CAM16 RGB LUT or hidden ACES fallback.
            for p in 0..<(w*h) {
                let k=p*3
                let raw=try engine.sourceSpatialXYZToRawLinearRGB(
                    [frame.rgb[k],frame.rgb[k+1],frame.rgb[k+2]]
                )
                let compressed=try Build89OriginalOutputGamut.compress(
                    raw,settings:exactGamut
                )
                for ch in 0..<3 {
                    frame.rgb[k+ch]=compressed[ch]
                }
            }
            stageDoubleObserver?("sourceGamutLinear",frame.rgb)
            if controlledScannerGlare {
                stageDoubleObserver?("scannerGlareLinearRGB",frame.rgb)
            }
        } else if controlledScannerGlare {
            for p in 0..<(w*h) {
                let k=p*3
                let linear=try engine.sourceSpatialXYZToLinearRGB(
                    [frame.rgb[k],frame.rgb[k+1],frame.rgb[k+2]]
                )
                for ch in 0..<3 {frame.rgb[k+ch]=linear[ch]}
            }
            stageDoubleObserver?("scannerGlareLinearRGB",frame.rgb)
        }
        if parameters.scannerOptics.active {
            // Source ScanningStage applies lens FIR/YVV and Unsharp only
            // AFTER the true XYZ→gamut RGB conversion.
            try OriginalSourceScannerOptics.applyInPlace(
                &frame.rgb,width:w,height:h,
                settings:parameters.scannerOptics,
                stageDoubleObserver:stageDoubleObserver
            )
        }
        if parameters.sourceOutputCCTFEncoding &&
           (parameters.sourceOutputGamut != nil ||
            parameters.scannerOptics.active || controlledScannerGlare) {
            // Original colour.RGB_to_RGB(sRGB→sRGB) performs a Float64
            // 3x3 pass BEFORE its CCTF, even for same-colourspace RGB.
            // Do this over the entire LINEAR scan output only after all
            // scanner optics, never per channel on a single scalar.
            for p in 0..<(w*h) {
                let k=p*3
                let encoded=OriginalScannerMath.sourceCCTFEncoding(
                    [frame.rgb[k],frame.rgb[k+1],frame.rgb[k+2]]
                )
                for ch in 0..<3 {frame.rgb[k+ch]=encoded[ch]}
            }
        }
        phaseMemoryObserver?("scanner_output_ready")
        stageDoubleObserver?("printed",frame.rgb)
        guard frame.rgb.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("逐像素源光学计算产生非有限扫描 RGB")
        }
    }

}

#if canImport(UIKit)
import UIKit
#endif

extension OriginalSourcePixelIO {
    // Keep source-physical utilities separate so existing original DIR-only
    // ImageIO and source kernel tests compile without SpectralPhysics.
    #if canImport(UIKit)
    static func previewPhysical(
        _ data:Data,parameters:OriginalSourcePhysicalImage.Parameters
    ) throws -> UIImage {
        var frame=try decode(
            data,previewMaxSide:640,
            maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
        )
        try OriginalSourcePhysicalImage.developInPlace(
            &frame,parameters:parameters
        )
        return UIImage(cgImage:try displayImage(frame))
    }
    #endif

    private static func renderPhysicalExportFrame(
        _ data:Data,parameters:OriginalSourcePhysicalImage.Parameters,
        resizedTo:(width:Int,height:Int)?
    ) throws -> Frame {
        // Original-sized rendering still uses the 13 MP guard.
        // Explicitly confirmed safe/economy rendering may accept source
        // metadata up to 16 MP, but ALL original physical equations run
        // at the confirmed reduced geometry; no fallback to fast/CI.
        let originalLimit = resizedTo == nil
            ? OriginalSourcePhysicalImage.maximumPixels : 16_000_000
        try preflightExport(
            data,maximumAllowedPixels:originalLimit
        )
        guard let imageSource=CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache:false] as CFDictionary
        ), let metadata=CGImageSourceCopyPropertiesAtIndex(
            imageSource,0,nil
        ) as NSDictionary?,
        let w=metadata[kCGImagePropertyPixelWidth] as? NSNumber,
        let h=metadata[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw Failure.invalid("原版全光学导出前无法确认原图尺寸")
        }
        let targetW=resizedTo?.width ?? w.intValue
        let targetH=resizedTo?.height ?? h.intValue
        let sourcePixelsUM=parameters.cameraOptics.filmFormatMM *
            1000.0 / Double(max(targetW,targetH))
        let cameraEnabled=(parameters.cameraOptics.active ||
            parameters.filmHalation.active) &&
            parameters.cameraOptics.diffusion.active &&
            parameters.cameraOptics.diffusion.strength>0 &&
            parameters.cameraOptics.diffusion.spatialScale>0
        let paperEnabled=parameters.printDiffusion.active &&
            parameters.printDiffusion.strength>0 &&
            parameters.printDiffusion.spatialScale>0
        let preflightCamera:(settings:OriginalSourceDiffusion.Settings,
                             pixelUM:Double)?=cameraEnabled
            ? (parameters.cameraOptics.diffusion,sourcePixelsUM):nil
        let preflightPaper:(settings:OriginalSourceDiffusion.Settings,
                            pixelUM:Double)?=paperEnabled
            ? (parameters.printDiffusion,sourcePixelsUM):nil
        // Build106: call the EXACT same source-feature ledger as the
        // renderer; the export has no stage observer. No unsafe optimistic
        // budget before ImageIO allocates full-resolution Float64 buffers.
        let preflightAdditional=Build106SourceMemoryLedger.productionAdditional(
            scannerFinish:parameters.scannerOptics.active,
            scannerGlare:parameters.scannerGlare.active &&
                parameters.scannerGlare.percent>0,
            grain:parameters.sourceGrain.active,
            grainSublayers:parameters.sourceGrain.sublayersActive,
            cameraActive:parameters.cameraOptics.active,
            cameraLens:parameters.cameraOptics.needsWholeImageBlur,
            filmHalation:parameters.filmHalation.active,
            paperDiffusion:parameters.printDiffusion.active,
            stageObserver:false,
            paperStageObserver:false,
            outputGamut:parameters.sourceOutputGamut != nil,
            parallelGrain:parameters.sourceGrain.useUnseededParallel
        )
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:targetW,height:targetH,
            additionalBytesPerPixel:preflightAdditional,
            cameraDiffusion:preflightCamera,paperDiffusion:preflightPaper
        )
        var frame=try decode(
            data,maximumAllowedPixels:originalLimit,resizedTo:resizedTo
        )
        guard frame.width==targetW,frame.height==targetH else {
            throw Failure.invalid(
                "逐像素全光学：实际 ImageIO 降采样尺寸与用户确认尺寸不一致"
            )
        }
        try OriginalSourcePhysicalImage.developInPlace(
            &frame,parameters:parameters
        )
        return frame
    }

    // Preserve existing 98% JPEG/Photos/Files semantics EXACTLY,
    // independent of Build90 opt-in file-format and uint-truncation.
    static func exportPhysicalJPEG(
        _ data:Data,parameters:OriginalSourcePhysicalImage.Parameters,
        resizedTo:(width:Int,height:Int)?=nil
    ) throws -> URL {
        return try createJPEG(
            renderPhysicalExportFrame(
                data,parameters:parameters,resizedTo:resizedTo
            )
        )
    }

    /// Build90 opt-in native file export. Source image optics and
    /// memory guard are shared with the existing verified JPEG path.
    /// Different colourspace inputs are REFUSED here because the
    /// current true spectral scanner raw-linear path is sRGB-only;
    /// a synthetic wide-space writer test is not certification of
    /// the physical scanner producing that output colourspace.
    static func exportPhysicalOriginalFile(
        _ data:Data,parameters:OriginalSourcePhysicalImage.Parameters,
        format:Build90SourceOutputQuantization.FileFormat,
        bitDepth:Int,outputSpace:String="sRGB",
        cctfEncoded:Bool=true,
        resizedTo:(width:Int,height:Int)?=nil
    ) throws ->URL {
        guard outputSpace=="sRGB",
              parameters.sourceOutputCCTFEncoding==cctfEncoded,
              parameters.sourceOutputGamut?.outputSpace
                != .displayP3,
              parameters.sourceOutputGamut?.outputSpace
                != .bt2020 else {
            throw Failure.invalid(
                "Build90 源光谱 XYZ→线性 RGB 的真实宽色域转换" +
                "未获图像级认证，禁止将 sRGB 数值贴成 P3/BT.2020"
            )
        }
        let frame=try renderPhysicalExportFrame(
            data,parameters:parameters,resizedTo:resizedTo
        )
        let options=Build90NativeOutputWriter.Options(
            format:format,bitDepth:bitDepth,
            outputSpace:outputSpace,cctfEncoded:cctfEncoded,
            sourceImageData:data
        )
        return try Build90NativeOutputWriter.write(
            width:frame.width,height:frame.height,
            rgb:frame.rgb,options:options
        )
    }
}
