import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class PhotoEditorModel: ObservableObject {
    @Published var originalPreview: UIImage?
    @Published var processedPreview: UIImage?
    @Published var lut: FilmLUT?
    @Published var strength = 1.0
    @Published var status = "选择照片，再导入 sRGB→sRGB .cube LUT。"
    /// Persistent, multiline self-test result; the compact toast is NOT the report.
    @Published var hardwareDiagnosticReport: String? = nil
    @Published var busy = false
    @Published var photoDimensions = ""
    /// Original Bayer DNG file from the most recent RAW+JPEG capture.
    @Published var capturedRAWURL: URL?
    @Published var filmExposureEV = 0.0
    @Published var printExposureEV = 0.0
    @Published var hanatosOriginalPrecisionEnabled = true
    @Published var scatterEnabled = false
    @Published var halationEnabled = false
    @Published var halationAmount = 1.0
    @Published var grainEnabled = false
    @Published var grainAmount = 1.0
    // Original measured 3-emulsion sublayer variance is opt-in.
    @Published var grainSublayersEnabled = false
    @Published var grainDiscreteParticlesEnabled = false
    // Source-order Metal: three emulsion layers, per-layer dye clouds,
    // conditional lognormal microstructure and reflect boundaries.
    @Published var grainOriginalMetalEnabled = false
    // Only after explicit user opt-in: source NumPy/SciPy per-channel RNG
    // and existing whole-frame source FIR/YVV Metal filters.
    @Published var grainOriginalSciPyEnabled = false
    // Experimental source-scanner path is OPT-IN. Initial UI and
    // old calculated looks remain identical to user-tested v1.0.1.
    @Published var originalScannerEnabled = false
    @Published var scannerCAM16Enabled = false
    @Published var scannerBlackWhiteEnabled = false
    @Published var scannerFinishingEnabled = false
    @Published var scannerSharpenAmount = 0.7
    // New v1.3 effects opt-in. The confirmed-safe v1.0.1 floating UI
    // and old v1.2 scanner results remain unchanged until toggled.
    @Published var exposureReferenceEnabled = false
    @Published var printMorphEnabled = false
    @Published var printGamma = 1.0
    @Published var printFastGamma = 1.0
    @Published var printSlowGamma = 1.0
    @Published var printDeveloperExhaustion = 0.0
    // Opt-in original spectral enlarger path; default stays v1.3.
    @Published var originalPrintOpticsEnabled = false
    // Source TH-KG3 default; optional TH-KG3-L measured Canon lens.
    @Published var printIlluminant: OriginalPrintOptics.Illuminant = .thKG3
    // Original Python EnlargerParams.diffusion_filter, opt-in.
    // Applied to full-frame paper photons before fitted paper H-D.
    @Published var printSourceDiffusionEnabled = false
    @Published var printSourceDiffusionFamily: OriginalSourceDiffusion.Family = .blackProMist
    @Published var printSourceDiffusionStrength = 0.5
    @Published var printSourceDiffusionSpatialScale = 1.0
    @Published var printSourceDiffusionWarmth = 0.0
    @Published var printSourceDiffusionCoreIntensity = 1.0
    @Published var printSourceDiffusionCoreSize = 1.0
    @Published var printSourceDiffusionHaloIntensity = 1.0
    @Published var printSourceDiffusionHaloSize = 1.0
    @Published var printSourceDiffusionBloomIntensity = 1.0
    @Published var printSourceDiffusionBloomSize = 1.0
    @Published var normalizePrintExposure = true
    @Published var printExposureCompensation = true
    @Published var printCyanShift = 0.0
    @Published var printMagentaShift = 0.0
    @Published var printYellowShift = 0.0
    @Published var preflashEnabled = false
    @Published var preflashExposure = 0.0
    @Published var preflashMagentaShift = 0.0
    @Published var preflashYellowShift = 0.0
    private var densityGrainStage: DensityGrainStage?
    private var spatialDIRStage: SpatialDIRStage?
    // Original DIR inhibition diffusion, opt-in to retain v1.4.1 visuals.
    @Published var spatialDIREnabled = false
    @Published var spatialDIRRadiusScale = 1.0
    // The source FIR/YVV reflect boundary route is default. Fast CI blur
    // remains an explicit user selection, never an implicit failure path.
    @Published var spatialDIRSourceConvolutionEnabled = true
    // v1.8.19 experimental: photo 8-bit ImageIO -> direct Double DIR
    // -> direct JPEG. Not a certified all-modules accuracy mode.
    @Published var sourcePixelIOEnabled = false
    // Separate opt-in v1.8.22 REAL nonlinear image optics. Never default to
    // it or replace the user-validated v1.8.21 direct-DIR route.
    @Published var sourcePhysicalDirectEnabled = false
    // Independent opt-in deterministic original Python ScanningStage:
    // post-ACES LINEAR Gaussian lens blur and unsharp, before display CCTF.
    // Existing scannerFinishingEnabled includes unported stochastic glare.
    @Published var sourceScannerOpticalEnabled = false
    @Published var sourceScannerLensBlurSigma = 0.0
    @Published var sourceScannerUnsharpSigma = 1.0
    @Published var sourceScannerUnsharpAmount = 0.7
    // Explicit opt-in experimental ORIGINAL XYZ glare, not unseeded
    // source multiworker equivalence. Fixed one-worker diagnostic seed.
    @Published var sourceScannerGlareEnabled = false
    @Published var sourceScannerGlarePercent = 0.03
    @Published var sourceScannerGlareRoughness = 0.7
    @Published var sourceScannerGlareBlur = 0.5
    // v1.8.30: three linked original Python camera stages. All are
    // explicitly opt-in and operate on actual source Double camera photons.
    @Published var sourceCameraPreFilmEnabled = false
    @Published var sourceCameraMeteringMethod: OriginalSourceCameraOptics.Metering = .centerWeighted
    @Published var sourceCameraHighlightBoostEV = 0.0
    @Published var sourceCameraHighlightBoostRange = 0.3
    @Published var sourceCameraHighlightProtectEV = 4.0
    @Published var sourceCameraLensBlurUM = 0.0
    // Original Python CameraParams.diffusion_filter: opt-in, with
    // every preset/advanced override. OFF preserves prior source output.
    @Published var sourceCameraDiffusionEnabled = false
    @Published var sourceCameraDiffusionFamily: OriginalSourceDiffusion.Family = .blackProMist
    @Published var sourceCameraDiffusionStrength = 0.5
    @Published var sourceCameraDiffusionSpatialScale = 1.0
    @Published var sourceCameraDiffusionWarmth = 0.0
    @Published var sourceCameraDiffusionCoreIntensity = 1.0
    @Published var sourceCameraDiffusionCoreSize = 1.0
    @Published var sourceCameraDiffusionHaloIntensity = 1.0
    @Published var sourceCameraDiffusionHaloSize = 1.0
    @Published var sourceCameraDiffusionBloomIntensity = 1.0
    @Published var sourceCameraDiffusionBloomSize = 1.0
    // Original Python SettingsParams.rgb_to_raw_method.
    // Hanatos remains the default; Mallett is a real source-Double
    // photon-input alternate, not a preview LUT approximation.
    @Published var sourceCameraRawMethod:
        SpectralPhysics.CameraRawMethod = .hanatos2025
    // Original Python CameraParams.filter_uv/ir tuples. Only used
    // inside source physical mode; off preserves the existing baseline.
    @Published var sourceCameraUVEnabled = false
    @Published var sourceCameraUVAmount = 1.0
    @Published var sourceCameraUVCutoffNM = 410.0
    @Published var sourceCameraUVWidthNM = 8.0
    @Published var sourceCameraIREnabled = false
    @Published var sourceCameraIRAmount = 1.0
    @Published var sourceCameraIRCutoffNM = 675.0
    @Published var sourceCameraIRWidthNM = 15.0
    @Published var sourceFilmHalationEnabled = false
    @Published var sourceFilmScatterAmount = 1.0
    @Published var sourceFilmScatterScale = 1.0
    @Published var sourceFilmHalationAmount = 1.0
    @Published var sourceFilmHalationScale = 1.0

    /// Legacy-position switches select the original source kernels ONLY
    /// in full physical mode. For ordinary CI rendering their meaning is
    /// unchanged. This also reserves actual full-frame halation memory.
    private var sourcePhysicalHalationRequested: Bool {
        sourceFilmHalationEnabled || scatterEnabled || halationEnabled
    }

    private var spatialDIRSettings: SpatialDIRSettings {
        SpatialDIRSettings(
            enabled: spatialDIREnabled && spatialDIRStage != nil,
            diffusionRadiusScale: spatialDIRRadiusScale,
            tailWeight: 0.06,
            sourceConvolutionEnabled: spatialDIRSourceConvolutionEnabled
        )
    }

    private var scannerFinishSettings: ScannerFinishSettings {
        let filmID = UserDefaults.standard.string(forKey: "compactFilmStock")
            ?? "kodak_portra_400"
        return ScannerFinishSettings(
            enabled: scannerFinishingEnabled,
            applyGlare: !SpectralPhysics.isPositiveFilm(filmID),
            unsharpAmount: scannerSharpenAmount,
            glarePercent: 0.03,
            seed: 8888
        )
    }

    private var grainSettings: DensityGrainSettings? {
        guard grainEnabled, grainAmount > 0, let stage = densityGrainStage else {
            return nil
        }
        return DensityGrainSettings(
            stage: stage, amount: grainAmount, seed: 8888,
            measuredSublayersEnabled: grainSublayersEnabled,
            discreteParticlesEnabled: grainDiscreteParticlesEnabled,
            originalMetalEnabled: grainOriginalMetalEnabled,
            sourceSciPySampling: grainOriginalMetalEnabled &&
                grainOriginalSciPyEnabled
        )
    }

    // Spatial convolution settings depend on the original stock's base
    // material and antihalation layer. Original film data lives in generated
    // metadata; no large JSON bundle is read at app launch.
    private var spatialSettings: SpatialOpticsSettings {
        let selected = UserDefaults.standard.string(forKey: "compactFilmStock")
            ?? "kodak_portra_400"
        let info = GeneratedMeasuredProfiles.entries.first { $0.id == selected }
        return SpatialOpticsSettings(
            scatterAmount: scatterEnabled ? 1.0 : 0.0,
            halationAmount: halationEnabled ? halationAmount : 0.0,
            filmUse: info?.usage ?? "still",
            antihalation: info?.antihalation ?? "strong"
        )
    }

    // Debounce scrolling wheels; never let a stale render replace new settings.
    private var renderGeneration = 0
    private var pendingRender: Task<Void, Never>?
    private var originalMetalPreviewVersion = 0

    func queueSpectralPreview() {
        pendingRender?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        guard hasPhoto else { return }
        pendingRender = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled && generation == renderGeneration else { return }
            applyMeasuredSimulation(generation: generation)
        }
    }

    private func invalidateSimulation() {
        pendingRender?.cancel()
        renderGeneration &+= 1
    }

    private var source: CIImage?
    private var originalPhotoData: Data?
    var hasPhoto: Bool { source != nil }

    /// Explicitly reject all unported combinations in direct source mode.
    /// No silent switch back to Core Image when the user selected precision.
    private func validateSourcePixelIO() throws -> (Data,SpatialDIRStage) {
        guard let data=originalPhotoData, let stage=spatialDIRStage,
              spatialDIREnabled,spatialDIRSourceConvolutionEnabled,
              lut != nil,abs(strength-1.0)<1e-9 else {
            throw ImageProcessingError.invalid(
                "原版 8-bit 像素直连需要先选胶片/相纸，启用原版 DIR FIR/YVV 和 100% 强度"
            )
        }
        // Plain 8-bit direct DIR still cannot use ANY spatial glow. The
        // separate full-physical source mode explicitly routes the familiar
        // scatter/halation switches to OriginalSourceFilmHalation instead.
        // Random-density grain and old CI scanner finishing stay rejected
        // in both modes. No unsupported option silently falls back to CI.
        guard (sourcePhysicalDirectEnabled || !spatialSettings.enabled),
              !grainEnabled,!scannerFinishingEnabled else {
            throw ImageProcessingError.invalid(
                sourcePhysicalDirectEnabled
                ? "逐像素全光学暂不支持密度随机颗粒或旧版 CI 扫描后处理。" +
                  "请显式关闭这些模块；乳剂散射与光晕使用原版 Double。"
                : "普通 8-bit DIR 像素直连不支持散射/光晕、密度颗粒或扫描后处理。" +
                  "需要原版乳剂效果时请开启「逐像素全光学」，禁止退回 Core Image。"
            )
        }
        return (data,stage)
    }

    /// Source-real optical settings are read once on the main actor,
    /// then passed by immutable value into the detached whole-image render.
    /// Original-only mode does not silently use unsupported colour/scatter.
    private func sourcePhysicalParameters()
        throws -> OriginalSourcePhysicalImage.Parameters {
        guard sourcePixelIOEnabled, sourcePhysicalDirectEnabled,
              hanatosOriginalPrecisionEnabled,
              originalScannerEnabled,
              !scannerBlackWhiteEnabled,
              !scannerCAM16Enabled,
              !exposureReferenceEnabled else {
            throw ImageProcessingError.invalid(
                "逐像素原版物理模式需要 Hanatos Float64、原版扫描 ACES；" +
                "关闭尚未验证的 CAM16/黑白参考/曝光参考，禁止自动降级"
            )
        }
        let filmID=UserDefaults.standard.string(forKey:"compactFilmStock")
            ?? "kodak_portra_400"
        let paperID=UserDefaults.standard.string(forKey:"compactPaperStock")
            ?? "kodak_portra_endura"
        let print=OriginalPrintOptics.Settings(
            enabled:originalPrintOpticsEnabled,
            illuminant:printIlluminant,
            normalizePrintExposure:normalizePrintExposure,
            printExposureCompensation:printExposureCompensation,
            cyanShift:printCyanShift,
            magentaShift:printMagentaShift,
            yellowShift:printYellowShift,
            preflashExposure:preflashEnabled ? preflashExposure : 0,
            preflashMagentaShift:preflashMagentaShift,
            preflashYellowShift:preflashYellowShift
        )
        let morph=printMorphEnabled
            ? OriginalPrintMorph.Settings(
                gamma:printGamma,fast:printFastGamma,
                slow:printSlowGamma,
                developerExhaustion:printDeveloperExhaustion
              )
            : OriginalPrintMorph.Settings()
        let sourceScan=sourceScannerOpticalEnabled
            ? OriginalSourceScannerOptics.Settings(
                lensBlurSigma:sourceScannerLensBlurSigma,
                unsharpSigma:sourceScannerUnsharpSigma,
                unsharpAmount:sourceScannerUnsharpAmount
            )
            : OriginalSourceScannerOptics.Settings()
        let preCamera=sourceCameraPreFilmEnabled
            ? OriginalSourceCameraOptics.Settings(
                metering:sourceCameraMeteringMethod,
                boostEV:sourceCameraHighlightBoostEV,
                boostRange:sourceCameraHighlightBoostRange,
                protectEV:sourceCameraHighlightProtectEV,
                lensBlurUM:sourceCameraLensBlurUM,
                filmFormatMM:35,
                diffusion:OriginalSourceDiffusion.Settings(
                    active:sourceCameraDiffusionEnabled,
                    family:sourceCameraDiffusionFamily,
                    strength:sourceCameraDiffusionStrength,
                    spatialScale:sourceCameraDiffusionSpatialScale,
                    haloWarmth:sourceCameraDiffusionWarmth,
                    coreIntensity:sourceCameraDiffusionCoreIntensity,
                    coreSize:sourceCameraDiffusionCoreSize,
                    haloIntensity:sourceCameraDiffusionHaloIntensity,
                    haloSize:sourceCameraDiffusionHaloSize,
                    bloomIntensity:sourceCameraDiffusionBloomIntensity,
                    bloomSize:sourceCameraDiffusionBloomSize
                )
              )
            : OriginalSourceCameraOptics.Settings()
        // In source-physical mode BOTH locations in the adjustment panel
        // enter this source Double optic, never the old SpatialOptics CI.
        let sourceBandpass=OriginalSourceCameraBandpass.Settings(
            uv:.init(
                amount:sourceCameraUVEnabled ? sourceCameraUVAmount : 0,
                centerNM:sourceCameraUVCutoffNM,
                widthNM:sourceCameraUVWidthNM
            ),
            ir:.init(
                amount:sourceCameraIREnabled ? sourceCameraIRAmount : 0,
                centerNM:sourceCameraIRCutoffNM,
                widthNM:sourceCameraIRWidthNM
            )
        )
        // Do not silently ignore a selected filter: the precomputed
        // Hanatos TC spectral LUT cannot be used for modified sensitivities.
        guard sourceCameraRawMethod == .mallett2019 ||
              !sourceBandpass.active else {
            throw ImageProcessingError.invalid(
                "UV/IR 需要按新感光度重建 Hanatos 光谱 LUT；" +
                "请选择原版 Mallett 2019 或关闭滤镜，不允许静默忽略"
            )
        }
        let sourceHalation=OriginalSourceFilmHalation.routedSettings(
            combinedEnabled:sourceFilmHalationEnabled,
            scatterToggle:scatterEnabled,
            halationToggle:halationEnabled,
            legacyHalationAmount:halationAmount,
            sourceScatterAmount:sourceFilmScatterAmount,
            sourceScatterScale:sourceFilmScatterScale,
            sourceHalationAmount:sourceFilmHalationAmount,
            sourceHalationScale:sourceFilmHalationScale
        )
        let p=OriginalSourcePhysicalImage.Parameters(
            filmID:filmID,paperID:paperID,
            cameraEV:filmExposureEV,paperEV:printExposureEV,
            dir:spatialDIRSettings,print:print,morph:morph,
            scannerOptics:sourceScan,
            scannerGlare:OriginalSourceScannerGlare.Settings(
                active:sourceScannerGlareEnabled,
                percent:sourceScannerGlarePercent,
                roughness:sourceScannerGlareRoughness,
                blur:sourceScannerGlareBlur
            ),
            scannerGlareSeed:sourceScannerGlareEnabled ? 8888 : nil,
            cameraOptics:preCamera,
            filmHalation:sourceHalation,
            cameraRawMethod:sourceCameraRawMethod,
            cameraBandpass:sourceBandpass,
            printDiffusion:OriginalSourceDiffusion.Settings(
                active:printSourceDiffusionEnabled,
                family:printSourceDiffusionFamily,
                strength:printSourceDiffusionStrength,
                spatialScale:printSourceDiffusionSpatialScale,
                haloWarmth:printSourceDiffusionWarmth,
                coreIntensity:printSourceDiffusionCoreIntensity,
                coreSize:printSourceDiffusionCoreSize,
                haloIntensity:printSourceDiffusionHaloIntensity,
                haloSize:printSourceDiffusionHaloSize,
                bloomIntensity:printSourceDiffusionBloomIntensity,
                bloomSize:printSourceDiffusionBloomSize
            )
        )
        try p.validate()
        return p
    }

    func selectFromPhotos(_ selection: PhotosPickerItem?) {
        guard let selection else { return }
        busy = true
        status = "正在读取照片…"
        Task {
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw ImageProcessingError.invalid("相册未提供照片数据")
                }
                try loadPhoto(data)
            } catch {
                status = "相册导入失败：" + error.localizedDescription
            }
            busy = false
        }
    }

    /// Keep RAW bytes separately in Documents. The original optical stage
    /// only accepts processed JPEG/HEIC input, never pretends to develop DNG.
    func loadCapturedPhoto(_ capture: NextLevelCapturedPhoto) {
        do {
            var rawFile: URL?
            if let raw = capture.rawDNG {
                guard !raw.isEmpty else {
                    throw ImageProcessingError.invalid("DNG 数据为空；拒绝保存假 RAW")
                }
                guard let docs = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                ).first else {
                    throw ImageProcessingError.invalid("无法找到安全的 RAW 存储目录")
                }
                let folder = docs.appendingPathComponent("SpektraFilm RAW", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true
                )
                let output = folder.appendingPathComponent(
                    "SF-RAW-" + UUID().uuidString + ".dng"
                )
                try raw.write(to: output, options: .atomic)
                rawFile = output
            }
            try loadPhoto(capture.processed)
            capturedRAWURL = rawFile
            status = rawFile == nil
                ? "\(capture.format) 拍摄完成，已进入当前胶片／相纸冲印"
                : "DNG 原片已保留在「文件」/ SpektraFilm RAW，JPEG 伴随片进入冲印；尚非 RAW 显影"
        } catch {
            status = "相机照片处理失败：" + error.localizedDescription
        }
    }

    func loadPhotoFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            try loadPhoto(Data(contentsOf: url))
        } catch {
            status = "文件导入失败：" + error.localizedDescription
        }
    }

    private func loadPhoto(_ data: Data) throws {
        invalidateSimulation()
        let decoded = try PhotoProcessor.decode(data)
        source = decoded
        originalPhotoData = data
        capturedRAWURL = nil
        photoDimensions = "\(Int(decoded.extent.width)) × \(Int(decoded.extent.height))"
        originalPreview = try PhotoProcessor.preview(decoded, lut: nil, strength: 0)
        try refresh()
        queueSpectralPreview()
    }

    func loadLUTFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let importedLUT = try FilmLUT.read(text: text,
                filename: url.deletingPathExtension().lastPathComponent)
            invalidateSimulation()
            densityGrainStage = nil
            spatialDIRStage = nil
            spatialDIREnabled = false
            grainEnabled = false
            grainSublayersEnabled = false
            grainDiscreteParticlesEnabled = false
            grainOriginalMetalEnabled = false
            grainOriginalSciPyEnabled = false
            lut = importedLUT
            busy = false
            try refresh()
        } catch {
            status = "LUT 导入失败：" + error.localizedDescription
        }
    }

    /// Compute an internal optical LUT from measured wavelength data.
    /// Keep the proven photo importer and CoreImage renderer unchanged.
    func applyMeasuredSimulation() {
        pendingRender?.cancel()
        renderGeneration &+= 1
        applyMeasuredSimulation(generation: renderGeneration)
    }

    private func applyMeasuredSimulation(generation: Int) {
        guard hasPhoto else {
            status = "请先选择照片，再模拟真实胶片数据。"
            return
        }
        let filmID = UserDefaults.standard.string(forKey: "compactFilmStock") ?? "kodak_portra_400"
        let paperID = UserDefaults.standard.string(forKey: "compactPaperStock") ?? "kodak_portra_endura"
        guard SpectralPhysics.supportedFilmIDs.contains(filmID),
              SpectralPhysics.supportedPaperIDs.contains(paperID) else {
            status = "该组合暂时只有原版目录数据，没有可用的光学模拟。请从目录中选择标注「可模拟」的胶片与相纸。"
            return
        }
        let sourceNames = Dictionary(uniqueKeysWithValues:
            GeneratedMeasuredProfiles.entries.map { ($0.id, $0.name) }
        )
        let filmName = sourceNames[filmID] ?? filmID
        let paperName = sourceNames[paperID] ?? paperID
        let selectionDescription = SpectralPhysics.isPositiveFilm(filmID)
            ? (filmName + " · 反转片直扫")
            : (filmName + " → " + paperName)
        busy = true
        status = "正在计算 \(selectionDescription)，原版 Hanatos2025 光谱输入…"
        let cameraExposure = filmExposureEV
        let enlargerExposure = printExposureEV
        let hanatosPrecision: OriginalHanatosResponse.Precision =
            hanatosOriginalPrecisionEnabled ? .originalFloat64 : .mobileFloat16
        let requiresGrainStage = grainEnabled
        let requiresSpatialDIRStage = spatialDIREnabled
        let originalScanner = originalScannerEnabled
        let referenceBW = scannerBlackWhiteEnabled
        let cam16 = scannerCAM16Enabled
        let useExposureReference = exposureReferenceEnabled
        let printOptics = OriginalPrintOptics.Settings(
            enabled: originalPrintOpticsEnabled,
            illuminant: printIlluminant,
            normalizePrintExposure: normalizePrintExposure,
            printExposureCompensation: printExposureCompensation,
            cyanShift: printCyanShift,
            magentaShift: printMagentaShift,
            yellowShift: printYellowShift,
            preflashExposure: preflashEnabled ? preflashExposure : 0,
            preflashMagentaShift: preflashMagentaShift,
            preflashYellowShift: preflashYellowShift
        )
        let printMorph = printMorphEnabled
            ? OriginalPrintMorph.Settings(
                gamma: printGamma, fast: printFastGamma,
                slow: printSlowGamma, developerExhaustion: printDeveloperExhaustion
              )
            : OriginalPrintMorph.Settings()
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let cube = try SpectralPhysics.makeCubeData(
                        filmID: filmID, paperID: paperID,
                        exposureEV: cameraExposure, paperEV: enlargerExposure,
                        size: 17,
                        sourceScanner: originalScanner,
                        scannerBlackWhite: referenceBW,
                        cam16Gamut: cam16,
                        printReferenceCorrection: useExposureReference,
                        printMorph: printMorph,
                        printOptics: printOptics,
                        hanatosPrecision: hanatosPrecision
                    )
                    let density = try requiresGrainStage
                        ? SpectralPhysics.makeDensityStageData(
                            filmID: filmID, paperID: paperID,
                            exposureEV: cameraExposure, paperEV: enlargerExposure,
                            size: 17,
                            sourceScanner: originalScanner,
                            scannerBlackWhite: referenceBW,
                            cam16Gamut: cam16,
                            printReferenceCorrection: useExposureReference,
                            printMorph: printMorph,
                            printOptics: printOptics,
                        hanatosPrecision: hanatosPrecision
                          ) : nil
                    let spatialDIR = try requiresSpatialDIRStage
                        ? SpectralPhysics.makeSpatialDIRStageData(
                            filmID: filmID, paperID: paperID,
                            exposureEV: cameraExposure,
                            paperEV: enlargerExposure,
                            sourceScanner: originalScanner,
                            scannerBlackWhite: referenceBW,
                            cam16Gamut: cam16,
                            printReferenceCorrection: useExposureReference,
                            printMorph: printMorph,
                            printOptics: printOptics,
                        hanatosPrecision: hanatosPrecision
                          ) : nil
                    return (cube, density, spatialDIR)
                }.value
                guard generation == renderGeneration else { return }
                spatialDIRStage = result.2
                if let stage = result.1 {
                    densityGrainStage = DensityGrainStage(
                        toDensity: stage.inputCube,
                        fromDensity: stage.printCube,
                        cubeDimension: stage.size,
                        maxDensity: stage.ranges,
                        sublayerCubes: stage.sublayerCubes,
                        sublayerRawMaxima: stage.sublayerRawMaxima
                    )
                } else {
                    densityGrainStage = nil
                }
                lut = FilmLUT(
                    title: "实测光谱 · \(selectionDescription) (实验)",
                    dimension: 17, rgbaFloatData: result.0
                )
                strength = 1.0
                try refresh()
                status = "已应用 \(selectionDescription)，胶片 \(String(format: "%+.2f", cameraExposure)) EV。" +
                    (requiresSpatialDIRStage
                        ? "DIR 空间抑制扩散 → 显影密度 → 光谱印相已启用。"
                        : (requiresGrainStage
                            ? "显影密度颗粒 → 原版印相链路已启用。"
                            : "原版光谱链路已启用。"))
            } catch {
                guard generation == renderGeneration else { return }
                status = "光谱计算失败：" + error.localizedDescription
            }
            if generation == renderGeneration { busy = false }
        }
    }

    func refresh() throws {
        guard let source else {
            status = lut == nil ? "请先导入照片。" : "LUT 已导入，请选择照片。"
            return
        }
        if grainOriginalMetalEnabled && grainEnabled && grainAmount > 0 {
            guard grainSublayersEnabled, densityGrainStage != nil,
                  lut != nil else {
                throw ImageProcessingError.invalid(
                    "原版 Metal 显影缺少实测亚层或光谱输入，禁止降级为快速 LUT"
                )
            }
        }
        originalMetalPreviewVersion &+= 1
        let revision = originalMetalPreviewVersion
        if sourcePixelIOEnabled {
            // A refused precision request must never leave an earlier,
            // potentially half-quantized preview looking like its result.
            processedPreview=nil
            let (data,stage)=try validateSourcePixelIO()
            let settings=spatialDIRSettings
            let physical=sourcePhysicalDirectEnabled
                ? try sourcePhysicalParameters() : nil
            status=physical == nil
                ? "原版 8-bit 像素直连：ImageIO→Double DIR→无 CI 预览计算中…"
                : "逐像素原版光学：Hanatos→H-D→FIR/YVV→相纸→ACES 预览中…"
            Task.detached(priority:.userInitiated) {
                do {
                    let image:UIImage
                    if let physical {
                        image=try OriginalSourcePixelIO.previewPhysical(
                            data,parameters:physical
                        )
                    } else {
                        image=try OriginalSourcePixelIO.preview(
                            data,stage:stage,settings:settings
                        )
                    }
                    await MainActor.run {
                        guard revision==self.originalMetalPreviewVersion else {return}
                        self.processedPreview=image
                        self.status=(physical == nil
                            ? "原版 8-bit 像素直连预览成功 · "
                            : "逐像素原版光学预览成功 · ") + self.photoDimensions
                    }
                } catch {
                    await MainActor.run {
                        guard revision==self.originalMetalPreviewVersion else {return}
                        self.processedPreview=nil
                        self.status = "原版 8-bit 像素直连失败（禁止回退）：" + error.localizedDescription
                    }
                }
            }
            return
        }
        // The full source-law Metal stage is synchronous and can perform
        // multiple tiled GPU passes; never run it on the SwiftUI actor.
        if grainOriginalMetalEnabled, grainEnabled, grainAmount > 0, lut != nil {
            let currentLUT = lut
            let currentStrength = strength
            let currentSpatial = spatialSettings
            let currentGrain = grainSettings
            let currentScanner = scannerFinishSettings
            let currentDIR = spatialDIRStage
            let currentDIRSettings = spatialDIRSettings
            status = grainOriginalSciPyEnabled
                ? "原版 SciPy 两阶段整图抽样中：需要串行计算全部九路颗粒…"
                : "原版 Metal 显影中：实测乳剂、染料云、微结构与反射边界…"
            Task.detached(priority: .userInitiated) {
                do {
                    let preview = try PhotoProcessor.preview(
                        source, lut: currentLUT, strength: currentStrength,
                        spatial: currentSpatial, grain: currentGrain,
                        scanner: currentScanner,
                        dirStage: currentDIR, dirSettings: currentDIRSettings
                    )
                    await MainActor.run {
                        guard revision == self.originalMetalPreviewVersion
                        else { return }
                        self.processedPreview = preview
                        self.status = (self.grainOriginalSciPyEnabled
                            ? "SciPy 原版序列 + Metal 显影预览完成 · "
                            : "原版 Metal 颗粒预览完成 · ") +
                            self.photoDimensions
                    }
                } catch {
                    await MainActor.run {
                        guard revision == self.originalMetalPreviewVersion
                        else { return }
                        self.status = "原版 Metal 显影失败（未退回快速模式）：" +
                            error.localizedDescription
                    }
                }
            }
            return
        }
        // v1.8.16: the exact source FIR/YVV is whole-image, Double
        // and may require multiple full-frame sweeps; ALWAYS do it off the
        // UI thread. Respect revision protection when sliders move.
        if spatialDIRSettings.enabled,
           spatialDIRSettings.sourceConvolutionEnabled {
            let currentLUT=lut
            let currentStrength=strength
            let currentSpatial=spatialSettings
            let currentGrain=grainSettings
            let currentScanner=scannerFinishSettings
            let currentDIR=spatialDIRStage
            let currentSettings=spatialDIRSettings
            status="正在后台执行原版 DIR FIR/YVV 空间扩散（非 CI 近似）…"
            Task.detached(priority:.userInitiated) {
                do {
                    let preview=try PhotoProcessor.preview(
                        source,lut:currentLUT,strength:currentStrength,
                        spatial:currentSpatial,grain:currentGrain,
                        scanner:currentScanner,dirStage:currentDIR,
                        dirSettings:currentSettings
                    )
                    await MainActor.run {
                        guard revision==self.originalMetalPreviewVersion else {return}
                        self.processedPreview=preview
                        self.status="原版空间 DIR FIR/YVV 预览完成 · "+self.photoDimensions
                    }
                } catch {
                    await MainActor.run {
                        guard revision==self.originalMetalPreviewVersion else {return}
                        self.status="原版空间 DIR 失败（没有降级 CI 近似）：" +
                            error.localizedDescription
                    }
                }
            }
            return
        }
        processedPreview = try PhotoProcessor.preview(
            source, lut: lut, strength: strength, spatial: spatialSettings,
            grain: grainSettings, scanner: scannerFinishSettings,
            dirStage: spatialDIRStage, dirSettings: spatialDIRSettings
        )
        if let lut {
            status = "已应用 \(lut.title) · \(lut.dimension)³ LUT · \(photoDimensions)"
        } else {
            status = "原图预览成功，尚未导入 LUT（未进行胶片模拟）。"
        }
    }

    /// Keep the complete eight-stage hardware evidence separately from status.
    /// One- or two-line UI summaries must never hide a partial failure.
    func checkOriginalMetalHardware() {
        hardwareDiagnosticReport = nil
        status = "正在检测本机原版 Metal，请在检测完成后点击上方查看报告…"
        Task.detached(priority: .userInitiated) {
            var checks: [String] = []
            let stages = 8
            do {
                let grain = try OriginalMetalGrain.hardwareDiagnostic()
                checks.append("1/8 【通过】Metal 硬件、纹理透传及 reflect\n" + grain)
                let poisson = try OriginalMetalGrain.poissonHardwareDiagnostic()
                checks.append("2/8 【通过】原生 Metal Poisson / PTRS\n" + poisson)
                let iir = try OriginalMetalIIR.hardwareDiagnostic()
                checks.append("3/8 【通过】原版 Young–van Vliet IIR\n" + iir)
                let replay = try OriginalMetalSourceReplay.hardwareDiagnostic()
                checks.append("4/8 【通过】Python 九路颗粒场与 Metal 密度回放\n" + replay)
                let mt = try OriginalSourceMT19937.validateReference()
                checks.append("5/8 【通过】NumPy MT19937 原始位流\n" + mt)
                let scipy = try OriginalSourceSciPySampler.validateSourceReference()
                checks.append("6/8 【通过】SciPy Poisson→Binomial 计数与 MT 顺序\n" + scipy)
                let production = try OriginalSourceSciPyParticles.hardwareDiagnostic()
                checks.append("7/8 【通过】正式显影 SciPy 随机数 → Metal 颗粒密度\n" + production)
                let micro = try OriginalSourceMicrostructure.hardwareDiagnostic()
                checks.append("8/8 【通过】Numba 微结构确定性 lognormal 变换\n" + micro)
                // v1.8.43: newest Numba fast_stats one-worker source reference.
                // Kept OUTSIDE 8/8 Metal certification; failure is displayed.
                do {
                    let fastCounts = try OriginalSourceNumbaFastCountsDiagnostic.evaluate()
                    checks.append("附录【v1.8.43 Numba 快速计数｜仅受控单线程数值对照】\n" + fastCounts)
                } catch {
                    checks.append("附录【v1.8.43 Numba 快速计数｜未通过／未认证】\n" + error.localizedDescription)
                }
                // v1.8.45: original Python scanner glare Float64 two-dimensional
                // lognormal + FIR/YVV + XYZ. Appendix is controlled RNG
                // numerical evidence, NOT full production scanner certification.
                do {
                    let glare = try OriginalSourceScannerGlareDiagnostic.evaluate()
                    checks.append("附录【v1.8.45 原版扫描器眩光｜受控单线程源数值对照】\n" + glare)
                } catch {
                    checks.append("附录【v1.8.45 原版扫描器眩光｜未通过／未认证】\n" + error.localizedDescription)
                }
                // Stage-specific RGB evidence is NOT an 9th certified
                // item. Explicitly preserve failures and measured drift.
                do {
                    let evidence = try OriginalSourceRGBParity.report()
                    checks.append("附录【原版 RGB 数值对照｜不计入 8/8 认证】\n" + evidence)
                } catch {
                    checks.append("附录【原版 RGB 对照不可用】\n" +
                        error.localizedDescription)
                }
                // The contiguous negative print chain is an INDEPENDENT
                // on-device appendix. It is not a 9th certified Metal test.
                // Source Python Float64 reference vectors are generated in
                // the existing CI before this same iPhoneOS app is compiled.
                // Evaluate the real production Swift optical, CDF H-D, XYZ,
                // ACES and display path on the current device. A failing
                // numerical stage is never renamed as a pass or omitted.
                do {
                    let evidence = try OriginalNegativePrintChainParity.evaluate()
                    if evidence.channels == 54 &&
                       evidence.stageOutsideTolerance == 0 &&
                       evidence.outputOutsideTolerance == 0 {
                        checks.append("附录【原版负片→相纸 H-D→RGB · 本机数值对照｜通过，不计入 8/8 认证】\n" +
                                      evidence.text)
                    } else {
                        checks.append("附录【原版负片→相纸 H-D→RGB · 本机数值对照｜未通过】\n" +
                                      evidence.text)
                    }
                } catch {
                    checks.append("附录【原版负片→相纸 H-D→RGB · 本机数值对照｜无法完成】\n" +
                                  error.localizedDescription)
                }
                // v1.8.14: film measured H-D + original Python nonspatial
                // DIR + same original s023 paper/scanning production functions.
                // This is stage-limited, NOT a ninth certified 8/8 item.
                do {
                    let evidence=try OriginalFilmDIRPrintParity.evaluate()
                    if evidence.channels==54 &&
                       evidence.stageOutsideTolerance==0 &&
                       evidence.outputOutsideTolerance==0 {
                        checks.append(
                            "附录【原版负片 H-D/DIR→相纸→RGB · 本机连续链｜通过，不计入 8/8 认证】\n" +
                            evidence.text
                        )
                    } else {
                        checks.append(
                            "附录【原版负片 H-D/DIR→相纸→RGB · 本机连续链｜未通过】\n" +
                            evidence.text
                        )
                    }
                } catch {
                    checks.append(
                        "附录【原版负片 H-D/DIR→相纸→RGB · 本机连续链｜无法完成】\n" +
                        error.localizedDescription
                    )
                }
                // v1.8.15 direct upstream Hanatos (source Float64) ->
                // camera EV -> measured negative H-D / nonspatial DIR ->
                // print / source XYZ ACES + separate Float16 quantization.
                // This is an appendix, NEVER an unearned ninth 8/8 item.
                do {
                    let result=try OriginalCameraFilmPrintParity.evaluate()
                    if result.channels==72 &&
                       result.preciseStageExceed==0 &&
                       result.preciseOutputExceed==0 {
                        checks.append(
                            "附录【原版 Hanatos Float64→负片 DIR→相纸→RGB｜通过；含快速模式对照】\n" +
                            result.text
                        )
                    } else {
                        checks.append(
                            "附录【原版 Hanatos Float64→负片 DIR→相纸→RGB｜未通过】\n" +
                            result.text
                        )
                    }
                } catch {
                    checks.append(
                        "附录【原版 Hanatos Float64→负片 DIR→相纸→RGB｜无法完成】\n" +
                        error.localizedDescription
                    )
                }
                // v1.8.16: distinct source 2D spatial DIR parity appendix;
                // real 13x11 CIImage production path, not an extra 8/8 item.
                do {
                    let result=try SourceSpatialDIR2DParity.evaluate()
                    if result.cases==3 && result.channels==1287 &&
                       result.numericOutside==0 &&
                       result.productionOutside==0 &&
                       result.directOutside==0 {
                        checks.append(
                            "附录【原版二维空间 DIR FIR/YVV｜本机通过，不计入 8/8 认证】\n" +
                            result.text
                        )
                    } else {
                        checks.append(
                            "附录【原版二维空间 DIR FIR/YVV｜本机未通过】\n" +
                            result.text
                        )
                    }
                } catch {
                    checks.append(
                        "附录【原版二维空间 DIR FIR/YVV｜无法完成】\n" +
                        error.localizedDescription
                    )
                }
                let report = "本机原版算法诊断 · 8/8 项全部通过\n" +
                    "注意：通过的是列出的数值测试，不代表完整 Numba 随机流、RAW 或 Float64 整图 RGB 已认证。\n\n" +
                    checks.joined(separator: "\n\n")
                await MainActor.run {
                    self.hardwareDiagnosticReport = report
                    self.status = "原版 Metal 检测 8/8 项通过 · 点击查看完整报告"
                }
            } catch {
                let done = checks.count
                let report = "本机原版算法诊断 · 未全部通过（\(done)/\(stages) 项完成）\n" +
                    "仅下列项目已通过，其余步骤未完成或未执行。\n\n" +
                    checks.joined(separator: "\n\n") +
                    "\n\n【失败原因】\n" + error.localizedDescription
                await MainActor.run {
                    self.hardwareDiagnosticReport = report
                    self.status = "原版 Metal 检测未通过（\(done)/\(stages)）· 点击查看错误"
                }
            }
        }
    }

    func prepareExport(resolution: ExportResolutionMode) throws
        -> SafeExportResolution.Plan {
        guard let src = source else {
            throw ImageProcessingError.invalid("请先导入照片")
        }
        if sourcePixelIOEnabled {
            // Before opening the confirmation sheet, validate the ORIGINAL
            // ImageIO dimensions and selected source algorithm budget.
            // Do not show a 16MP normal-export memory estimate when the
            // separately selected physical mode can process only 2MP.
            guard resolution == .original else {
                throw ImageProcessingError.invalid(
                    "原版像素直连实验版仅支持原尺寸高清输出，不允许隐式缩图"
                )
            }
            let (data, _) = try validateSourcePixelIO()
            if sourcePhysicalDirectEnabled {
                _ = try sourcePhysicalParameters()
            }
            try OriginalSourcePixelIO.preflightExport(
                data, maximumAllowedPixels: sourcePhysicalDirectEnabled
                    ? OriginalSourcePhysicalImage.maximumPixels : 16_000_000
            )
        }
        let bounds = src.extent.integral
        if sourcePixelIOEnabled && sourcePhysicalDirectEnabled {
            // In-place full-image physical optics now handles 10MP-class
            // input conditionally. Validate the REAL device/process budget
            // before showing a misleading "ready to export" sheet.
            try OriginalSourcePhysicalImage.validateMemoryBudget(
                width:Int(bounds.width),height:Int(bounds.height),
                additionalBytesPerPixel:
                    (sourceScannerOpticalEnabled
                        ? OriginalSourcePhysicalImage.scannerFinishExtraBytesPerPixel : 0) +
                    (sourceScannerGlareEnabled && sourceScannerGlarePercent>0
                        ? OriginalSourcePhysicalImage.scannerGlareExtraBytesPerPixel : 0) +
                    (sourceCameraPreFilmEnabled && sourceCameraLensBlurUM > 0
                        ? OriginalSourcePhysicalImage.cameraLensExtraBytesPerPixel : 0) +
                    (sourcePhysicalHalationRequested
                        ? OriginalSourcePhysicalImage.filmHalationExtraBytesPerPixel : 0)
            )
        }
        return try SafeExportResolution.capture(
            width: Int(bounds.width), height: Int(bounds.height),
            mode: resolution,
            estimatedBytesPerPixel:
                sourcePixelIOEnabled && sourcePhysicalDirectEnabled
                ? (OriginalSourcePhysicalImage.estimatedPeakBytesPerPixel +
                   (sourceScannerOpticalEnabled
                    ? OriginalSourcePhysicalImage.scannerFinishExtraBytesPerPixel
                    : 0) +
                   (sourceScannerGlareEnabled && sourceScannerGlarePercent>0
                    ? OriginalSourcePhysicalImage.scannerGlareExtraBytesPerPixel
                    : 0) +
                   (sourceCameraPreFilmEnabled && sourceCameraLensBlurUM > 0
                    ? OriginalSourcePhysicalImage.cameraLensExtraBytesPerPixel : 0) +
                   (sourcePhysicalHalationRequested
                    ? OriginalSourcePhysicalImage.filmHalationExtraBytesPerPixel : 0))
                : SafeExportResolution.estimatedBytesPerPixel
        )
    }

    func exportJPEG(
        resolution: ExportResolutionMode = .original,
        confirmedPlan: SafeExportResolution.Plan? = nil
    ) async throws -> URL {
        guard let imageSource = source else {
            throw ImageProcessingError.invalid("请先导入照片")
        }
        if grainOriginalMetalEnabled && grainEnabled && grainAmount > 0 {
            guard grainSublayersEnabled, densityGrainStage != nil,
                  lut != nil else {
                throw ImageProcessingError.invalid(
                    "原版 Metal 导出缺少显影数据，禁止静默使用快速算法"
                )
            }
        }
        if sourcePixelIOEnabled {
            let (data,stage)=try validateSourcePixelIO()
            guard resolution == .original else {
                throw ImageProcessingError.invalid(
                    "原版像素直连实验版仅支持原尺寸高清输出，不允许隐式缩图"
                )
            }
            let settings=spatialDIRSettings
            let physical=sourcePhysicalDirectEnabled
                ? try sourcePhysicalParameters() : nil
            let url=try await Task.detached(priority:.userInitiated) {
                if let physical {
                    return try OriginalSourcePixelIO.exportPhysicalJPEG(
                        data,parameters:physical
                    )
                }
                return try OriginalSourcePixelIO.exportJPEG(
                    data,stage:stage,settings:settings
                )
            }.value
            status=physical == nil
                ? "原版像素直连：原尺寸 JPEG 已输出（8-bit，不含 CI 中间量化）"
                : "逐像素原版光学：原尺寸 JPEG 已输出，未使用颜色 LUT"
            return url
        }
        // Keep full-resolution Core Image evaluation off the SwiftUI main
        // actor to avoid freezing the iOS 16.5.1 floating workspace.
        let currentLUT = lut
        let currentStrength = strength
        let currentSpatial = spatialSettings
        let currentGrain = grainSettings
        let currentScanner = scannerFinishSettings
        let currentDIRStage = spatialDIRStage
        let currentDIRSettings = spatialDIRSettings
        let output = try await Task.detached(priority: .userInitiated) {
            try PhotoProcessor.exportJPEG(
                imageSource, lut: currentLUT, strength: currentStrength,
                spatial: currentSpatial, grain: currentGrain,
                scanner: currentScanner,
                dirStage: currentDIRStage,
                dirSettings: currentDIRSettings,
                resolution: resolution,
                confirmedPlan: confirmedPlan
            )
        }.value
        let label = resolution.title
        status = "\(label) \(output.width) × \(output.height) JPEG 已完成"
        return output.url
    }
}

struct ContentView: View {
    @StateObject private var model = PhotoEditorModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var cameraPresented = false
    @State private var activeSheet: ImportSheet?
    @State private var message: String?
    @State private var pendingExport: ExportProposal?

    private struct ExportProposal: Identifiable {
        let id = UUID()
        let toPhotos: Bool
        let plan: SafeExportResolution.Plan
    }

    @AppStorage("compactFilmStock") private var selectedFilmID = "kodak_portra_400"
    @AppStorage("compactPaperStock") private var selectedPaperID = "kodak_portra_endura"

    // Use a single native document picker for both file entry points. A
    // restrictive UTType or multiple fileImporter modifiers can hide .cube
    // files and nonstandard images from third-party Files providers.
    private enum ImportSheet: Identifiable {
        case photo
        case lut
        case stocks
        case share(URL)

        var id: String {
            switch self {
            case .photo: return "photo-file"
            case .lut: return "lut-file"
            case .stocks: return "stock-catalog"
            case .share(let url): return "share-" + url.absoluteString
            }
        }
    }

    var body: some View {
        NavigationStack {
            FloatingEditorWorkspace(
                model: model,
                selectedPhoto: $selectedPhoto,
                selectedFilmID: $selectedFilmID,
                selectedPaperID: $selectedPaperID,
                onOpenPhotoFile: {
                    model.status = "请选择 JPEG / HEIC / PNG / TIFF 图片文件"
                    activeSheet = .photo
                },
                onOpenCamera: {
                    guard !model.busy else { return }
                    cameraPresented = true
                },
                onShareRaw: {
                    if let url = model.capturedRAWURL {
                        activeSheet = .share(url)
                    }
                },
                onOpenLUT: {
                    model.status = "请选择 .cube 文件"
                    activeSheet = .lut
                },
                onOpenCatalog: {
                    activeSheet = .stocks
                },
                onExport: { resolution in
                    proposeExport(saveToPhotos: false, resolution: resolution)
                },
                onSaveToPhotos: { resolution in
                    proposeExport(saveToPhotos: true, resolution: resolution)
                },
                onRefresh: { refresh() }
            )
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: selectedPhoto) { item in
                model.selectFromPhotos(item)
            }
            .onChange(of: selectedFilmID) { _ in
                model.queueSpectralPreview()
            }
            .onChange(of: selectedPaperID) { _ in
                model.queueSpectralPreview()
            }
            .fullScreenCover(isPresented: $cameraPresented) {
                NextLevelCameraScreen(
                    onCancel: { cameraPresented = false },
                    onCapture: { photo in
                        cameraPresented = false
                        model.loadCapturedPhoto(photo)
                    }
                )
            }
            .sheet(item: $activeSheet) { selection in
                switch selection {
                case .photo:
                    FilesDocumentPicker(onPick: { url in
                        model.loadPhotoFile(url)
                        activeSheet = nil
                    }, onCancel: {
                        activeSheet = nil
                    })
                case .lut:
                    FilesDocumentPicker(onPick: { url in
                        model.loadLUTFile(url)
                        activeSheet = nil
                    }, onCancel: {
                        activeSheet = nil
                    })
                case .stocks:
                    CompactStockCatalogView()
                case .share(let url):
                    ActivitySheet(items: [url])
                }
            }
            .sheet(item: $pendingExport) { proposal in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(proposal.plan.mode.title)
                                .font(.headline)
                            Text(proposal.plan.summary)
                                .font(.system(size: 14, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text("实际内存会波动。此模式按确认的输出尺寸执行完整显影；失败会提示，不会擅自降低像素或切换颗粒算法。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Button {
                                pendingExport = nil
                                performExport(
                                    saveToPhotos: proposal.toPhotos,
                                    resolution: proposal.plan.mode,
                                    confirmedPlan: proposal.plan
                                )
                            } label: {
                                Text(proposal.toPhotos
                                    ? "确认尺寸并保存相册"
                                    : "确认尺寸并导出文件")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy)
                        }
                        .padding(20)
                    }
                    .navigationTitle("导出前确认")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("取消") { pendingExport = nil }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("确定", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func refresh() {
        do { try model.refresh() }
        catch { message = error.localizedDescription }
    }

    private func proposeExport(
        saveToPhotos: Bool, resolution: ExportResolutionMode
    ) {
        guard model.hasPhoto && !model.busy else { return }
        do {
            let plan = try model.prepareExport(resolution: resolution)
            pendingExport = ExportProposal(
                toPhotos: saveToPhotos, plan: plan
            )
        } catch {
            message = error.localizedDescription
        }
    }

    private func performExport(
        saveToPhotos: Bool, resolution: ExportResolutionMode,
        confirmedPlan: SafeExportResolution.Plan
    ) {
        guard model.hasPhoto && !model.busy else { return }
        model.busy = true
        let mode = resolution.title
        model.status = saveToPhotos
            ? "正在制作\(mode) JPEG 并写入系统相册…"
            : "正在制作\(mode) JPEG…"
        Task { @MainActor in
            defer { model.busy = false }
            do {
                let file = try await model.exportJPEG(
                    resolution: resolution, confirmedPlan: confirmedPlan
                )
                if saveToPhotos {
                    try await PhotoLibrarySaver.saveJPEG(at: file)
                    model.status = "\(mode)照片已保存到系统相册"
                } else {
                    activeSheet = .share(file)
                }
            } catch {
                message = error.localizedDescription
                model.status = "高清导出失败：" + error.localizedDescription
            }
        }
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ viewController: UIActivityViewController, context: Context) {}
}

    
/// We intentionally open *all* document items instead of filtering .cube or
/// .image up front. Some providers (iCloud Drive, On My iPhone, third-party
/// file providers) do not advertise uncommon extensions as these UTTypes.
/// We validate the extension and actual content after selecting the file.
private struct FilesDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            // The picker supplies a sandbox copy. Consume it synchronously
            // before dismissing the sheet and releasing the temporary URL.
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}


