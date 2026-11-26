import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit
#if os(iOS)
import os
#endif

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
    /// Build111 admission result for the *currently committed* photo.
    @Published var photoInputProfile: Build111PhotoInputProfile.Inspection?
    @Published var photoInputConvertedFromP3 = false
    /// Explicit true RAW source; never use compatible CI preview as optical input.
    @Published var rawOriginalSourceActive = false
    /// Build139: default FAST optical preview from reduced linear RAW.
    /// User can explicitly opt into full source-resolution optical preview.
    /// This state never affects export, which ALWAYS develops original RAW.
    @Published private(set) var rawFullResolutionPreview = false
    /// Build141: non-destructive selection in native LibRaw ACES16 pixel
    /// coordinates, captured from an UNCROPPED source optical preview.
    @Published private(set) var rawCropSelection:Build141RAWPreCrop.Selection?
    @Published private(set) var rawCropReferencePreview:UIImage?
    @Published private(set) var rawCropReferenceWidth=0
    @Published private(set) var rawCropReferenceHeight=0
    private var photoOriginalBeforeColorConversion: Data?
    var photoDirectInputReady:Bool {
        (originalPhotoData != nil && !rawFastModeActive &&
            photoInputProfile?.directCompatible == true) ||
            (rawOriginalSourceActive && capturedRAWURL != nil && source != nil)
    }
    var photoP3ConversionPossible:Bool {
        originalPhotoData != nil && !rawFastModeActive &&
            photoInputProfile?.convertibleP3 == true
    }
    var photoInputSummary:String {
        guard let p=photoInputProfile else {
            if rawOriginalSourceActive && capturedRAWURL != nil {
                return "RAW 原片直通｜ACES16｜精细光学真机测试"
            }
            if rawFastModeActive && capturedRAWURL != nil {
                return "真实 DNG / Apple RAW 已解码｜胶片效果可用"
            }
            return hasPhoto ? "未认证输入：原版像素直连不可用" : "尚未导入照片"
        }
        return p.summary + (photoInputConvertedFromP3 ? "｜ColorSync 已转换" : "")
    }
    var photoInputExplanation:String {
        if rawOriginalSourceActive && capturedRAWURL != nil {
            return "精细冲印直接重读 RAW 原片并进行线性 ACES16 显影，" +
                "不使用兼容预览或手动 TIFF 副本。" +
                "rawpy 数值等价尚未认证；当前全光学 13MP 内存上限仍生效。"
        }
        if rawFastModeActive && capturedRAWURL != nil {
            return "DNG 原片已完整保存，Apple RAW 高精度解码／兼容冲印可用。" +
                "不是必须转 8-bit：可直接进行兼容光学处理并最终导出 TIFF16。" +
                "如需进入原版 Float64 像素直连，可明确生成经验证的 " +
                "Float32 TIFF 副本（按实际 ICC sRGB／扩展 sRGB 校验，不经过 JPEG／RGBA8）；" +
                "这是 Apple RAW 色彩管理结果，不是传感器 Bayer 或 Python rawpy 数值等价。" +
                "旧 8-bit 副本仍为可选，绝不自动转换或覆盖原 DNG。"
        }
        return photoInputProfile?.reason ??
            "此照片没有可检测的原始文件数据，原版像素直连不可用。"
    }

    func convertCurrentP3ToSRGB() throws {
        guard !busy,photoP3ConversionPossible,
              let bytes=originalPhotoData else {
            throw ImageProcessingError.invalid("当前照片不满足可转换的 P3 8-bit 条件")
        }
        let original=photoOriginalBeforeColorConversion ?? bytes
        let converted=try Build111PhotoInputProfile.convertP3ToSRGB(bytes)
        try loadPhoto(converted,entry:.converted)
        photoOriginalBeforeColorConversion=original
        photoInputConvertedFromP3=true
        status="已明确使用 Apple ColorSync 将 P3 转为独立 sRGB JPEG；原始照片保留。(photoInputSummary)。原版全光学仍需通过其独立内存预算。"
    }
    /// Build125: ONLY an explicit user selection can create a secondary
    /// 8-bit sRGB file from genuinely developed RAW pixels. Never change the
    /// original DNG, never claim source RAW or Python rawpy equivalence.
    func convertActiveRAWTo8BitSRGBCopy() {
        guard !busy,rawFastModeActive,
              let preservedDNG=capturedRAWURL,
              let rawImage=source else {
            status="当前没有可转换的 Apple RAW 编辑图；原编辑未改变"
            return
        }
        busy=true
        status="正在将 Apple RAW 解码像素明确转换为独立 sRGB 8-bit 副本；原 DNG 不变…"
        Task { @MainActor in
            defer {busy=false}
            do {
                let output=try await Task.detached(priority:.userInitiated) {
                    try Build125RAW8BitTransport.makeCertifiedCopy(rawImage)
                }.value
                let profile=Build111PhotoInputProfile.inspect(
                    output,entry:.converted
                )
                guard profile.directCompatible else {
                    throw ImageProcessingError.invalid(
                        "转换后的 8-bit 文件不满足原版像素入口：" +
                        profile.summary + "。" + profile.reason
                    )
                }
                let decoded=try PhotoProcessor.decode(output)
                let preview=try PhotoProcessor.preview(
                    decoded,lut:nil,strength:0
                )
                try commitDecodedPhoto(
                    image:decoded,preview:preview,
                    data:output,rawURL:preservedDNG,rawCompatible:false,
                    dimensions:"\(profile.dimensions) · DNG→sRGB 8-bit 副本",
                    inputProfile:profile
                )
                status="8-bit sRGB 副本已通过原版像素输入预检，" +
                    "可按原有前置条件开启 8-bit 直连／全光学。" +
                    "输入已是 Apple RAW 转换的有损 JPEG 副本，" +
                    "不等同于 RAW 传感器原始值或 Python rawpy 精确显影；" +
                    "原始 DNG 已保留。"
            } catch {
                status="RAW 转 8-bit sRGB 副本失败；保持 RAW 冲印与原始 DNG：" +
                    error.localizedDescription
            }
        }
    }


    /// Build128: opt-in RAW high-precision bridge; ALWAYS reopen the real
    /// preserved DNG through CIRAWFilter. Do not reuse a JPEG companion or
    /// a potentially different LibRaw compatible CI preview.
    func convertActiveRAWToFloat32ExtendedSRGBCopy() {
        guard !busy,rawFastModeActive,
              let originalDNG=capturedRAWURL else {
            status="当前没有真实 RAW 原片可转换；照片与参数未改变"
            return
        }
        busy=true
        status="正在从原始 DNG 生成明确的 Float32 TIFF（ICC 独立验证），"
            + "不经过 8-bit JPEG、不改变原片…"
        Task { @MainActor in
            defer {busy=false}
            do {
                let result=try await Task.detached(priority:.userInitiated) {
                    let decoded=try Build93AppleRAWImport.open(originalDNG)
                    return try Build128RAWFloat32Transport.makeVerifiedCopy(
                        decoded.image
                    )
                }.value
                let input=try PhotoProcessor.decode(result.bytes)
                let preview=try PhotoProcessor.preview(
                    input,lut:nil,strength:0
                )
                try commitDecodedPhoto(
                    image:input,preview:preview,data:result.bytes,
                    rawURL:originalDNG,rawCompatible:false,
                    dimensions:"\(result.admission.dimensions) · Apple RAW → Float32 TIFF",
                    inputProfile:result.admission
                )
                status = "RAW→Float32 " + result.admission.color.rawValue +
                    " TIFF 已通过真实位深／ICC 入口验证，" +
                    "可在符合 DIR／全光学前置条件时使用 Float64 像素路径；" +
                    "没有 8-bit 中间 JPEG。原 DNG 无损保留。" +
                    "注意：Apple RAW 去马赛克／色彩管理与 Python rawpy 不保证等价。"
            } catch {
                status="RAW→Float32 高位深入口拒绝／失败，原照片、冲印与 DNG 保留：" +
                    error.localizedDescription
            }
        }
    }

    /// Build129: regular JPEG/HEIC/P3/PNG can request a *separate*
    /// Float32 TIFF without changing the archived source bytes. The file
    /// must have an independently identified RGB ICC profile; untagged,
    /// unknown, grayscale and unverified input cannot be re-labelled.
    var photoHighDepthCopyPossible:Bool {
        guard hasPhoto,!rawFastModeActive,
              originalPhotoData != nil,source != nil,
              let p=photoInputProfile,p.imageIOUsable,
              p.failureReason == nil,(!p.directCompatible ||
                 !originalPixelInputAvailable) else {return false}
        return p.color == .sRGB ||
               p.color == .displayP3 ||
               p.color == .extendedSRGB
    }

    func convertActivePhotoToFloat32Copy() {
        guard !busy,photoHighDepthCopyPossible,
              let originalBytes=originalPhotoData,
              let image=source,let previousProfile=photoInputProfile else {
            status="当前普通照片缺少已识别的 RGB ICC 或原文件；" +
                "不能凭空生成原版像素数据，原编辑保持不变"
            return
        }
        busy=true
        status="正在明确生成普通照片的 Float32 TIFF 副本；" +
            "保留原图、实际验证 ICC 和位深，不经过 JPEG8…"
        Task { @MainActor in
            defer {busy=false}
            do {
                let result=try await Task.detached(priority:.userInitiated) {
                    try Build128RAWFloat32Transport.makeVerifiedCopy(image)
                }.value
                let decoded=try PhotoProcessor.decode(result.bytes)
                let preview=try PhotoProcessor.preview(decoded,lut:nil,strength:0)
                try commitDecodedPhoto(
                    image:decoded,preview:preview,data:result.bytes,
                    rawURL:nil,rawCompatible:false,
                    dimensions:result.admission.dimensions +
                        " · 普通照片→Float32 TIFF",
                    inputProfile:result.admission
                )
                // This is an in-memory backup of the previous source file,
                // never an overwrite. Photos/Files original also remain.
                photoOriginalBeforeColorConversion=originalBytes
                photoInputConvertedFromP3 = (previousProfile.color == .displayP3)
                status="普通照片 Float32 " + result.admission.color.rawValue +
                    " TIFF 已通过输入预检，可在确认 DIR 和内存依赖后" +
                    "进入原版全光学。原照片没有改写；" +
                    "原版 Python 色彩数值等价尚未认证。"
            } catch {
                status="普通照片 Float32 副本生成失败；旧照片、参数、预览均保留：" +
                    error.localizedDescription
            }
        }
    }


    // Build126 recipes are a separate, opt-in persistence domain. The source
    // image, sensor DNG, simulated stage caches and preview are NOT persisted.
    @Published private(set) var savedRecipes:[Build126Recipe]=[]
    @Published private(set) var isRecipeApplying=false
    private struct RecipeUndo {
        let settings:Build126Recipe
        let lut:FilmLUT?
        let density:DensityGrainStage?
        let dir:SpatialDIRStage?
        let preview:UIImage?
        let previousStatus:String
        let hadPendingSimulation:Bool
        let desiredName:String
    }
    private var recipeUndo:RecipeUndo?
    // One-shot suppression: SwiftUI's @AppStorage reacts to recipe stock
    // changes, but the recipe transaction already owns the optical render.
    private var recipeFilmSelectionToIgnore:String?
    private var recipePaperSelectionToIgnore:String?

    func consumeRecipeFilmSelection(_ id:String) -> Bool {
        let skip=recipeFilmSelectionToIgnore==id
        recipeFilmSelectionToIgnore=nil
        return skip
    }
    func consumeRecipePaperSelection(_ id:String) -> Bool {
        let skip=recipePaperSelectionToIgnore==id
        recipePaperSelectionToIgnore=nil
        return skip
    }

    init() {
        do {
            savedRecipes=try Build126RecipeStorage.load()
        } catch {
            status="配方库验证失败（未覆盖原数据）：" + error.localizedDescription
        }
    }

    // Reflect the INPUT file independently from the currently selected
    // processing mode; a recipe must be applicable from fast mode too.
    private func currentRecipeInputContract() -> String? {
        guard let p=photoInputProfile else {return nil}
        if p.floatingComponents && p.color == .extendedSRGB {
            if p.decodedDepth==32 {return "float32ExtendedSRGB"}
            if p.decodedDepth==16 {return "float16ExtendedSRGB"}
        }
        if p.floatingComponents && p.color == .sRGB &&
            p.declaredDepth==32 && p.decodedDepth==32 &&
            p.format=="TIFF" {
            return "float32SRGB"
        }
        if !p.floatingComponents && p.color == .sRGB {
            if p.decodedDepth==16 {return "uint16SRGB"}
            if p.decodedDepth==8 {return "uint8SRGB"}
        }
        return nil
    }

    private func recipeSnapshot(name:String,includeCover:Bool) -> Build126Recipe {
        let cover:Data? = {
            guard includeCover,let preview=processedPreview else {return nil}
            let s=preview.size
            let factor=min(1.0,240.0/max(1.0,max(s.width,s.height)))
            let target=CGSize(width:max(1.0,s.width*factor),
                              height:max(1.0,s.height*factor))
            let image=UIGraphicsImageRenderer(size:target).image { _ in
                preview.draw(in:CGRect(origin:.zero,size:target))
            }
            return image.jpegData(compressionQuality:0.60)
        }()
        let originalLUT:Build126RecipeLUT? = {
            guard let l=lut,!l.title.hasPrefix("实测光谱 ·") else{return nil}
            return Build126RecipeLUT(
                title:l.title,dimension:l.dimension,
                rgbaFloatData:l.rgbaFloatData
            )
        }()
        return Build126Recipe(
            schemaVersion:Build126Recipe.schema,
            id:UUID(),name:name,createdAt:Date(),modifiedAt:Date(),
            favorite:false,
            filmID:UserDefaults.standard.string(forKey:"compactFilmStock")
                ?? "kodak_portra_400",
            paperID:UserDefaults.standard.string(forKey:"compactPaperStock")
                ?? "kodak_portra_endura",
            bools:[
            "hanatosOriginalPrecisionEnabled":hanatosOriginalPrecisionEnabled,
            "scatterEnabled":scatterEnabled,
            "halationEnabled":halationEnabled,
            "grainEnabled":grainEnabled,
            "grainSublayersEnabled":grainSublayersEnabled,
            "grainDiscreteParticlesEnabled":grainDiscreteParticlesEnabled,
            "grainOriginalMetalEnabled":grainOriginalMetalEnabled,
            "grainOriginalSciPyEnabled":grainOriginalSciPyEnabled,
            "originalScannerEnabled":originalScannerEnabled,
            "scannerCAM16Enabled":scannerCAM16Enabled,
            "scannerBlackWhiteEnabled":scannerBlackWhiteEnabled,
            "scannerFinishingEnabled":scannerFinishingEnabled,
            "exposureReferenceEnabled":exposureReferenceEnabled,
            "printMorphEnabled":printMorphEnabled,
            "originalPrintOpticsEnabled":originalPrintOpticsEnabled,
            "neutralPrintFiltersFromDatabase":neutralPrintFiltersFromDatabase,
            "printSourceDiffusionEnabled":printSourceDiffusionEnabled,
            "normalizePrintExposure":normalizePrintExposure,
            "printExposureCompensation":printExposureCompensation,
            "preflashEnabled":preflashEnabled,
            "spatialDIREnabled":spatialDIREnabled,
            "spatialDIRSourceConvolutionEnabled":spatialDIRSourceConvolutionEnabled,
            "sourcePixelIOEnabled":sourcePixelIOEnabled,
            "sourcePhysicalDirectEnabled":sourcePhysicalDirectEnabled,
            "sourcePhysicalCAM16DefaultGamutEnabled":sourcePhysicalCAM16DefaultGamutEnabled,
            "sourcePhysicalInputOklchEnabled":sourcePhysicalInputOklchEnabled,
            "sourceScannerOpticalEnabled":sourceScannerOpticalEnabled,
            "sourceScannerGlareEnabled":sourceScannerGlareEnabled,
            "sourcePhysicalGrainEnabled":sourcePhysicalGrainEnabled,
            "sourceGrainUseUnseededParallel":sourceGrainUseUnseededParallel,
            "sourceGrainFastStatsEnabled":sourceGrainFastStatsEnabled,
            "sourceCameraPreFilmEnabled":sourceCameraPreFilmEnabled,
            "sourceCameraDiffusionEnabled":sourceCameraDiffusionEnabled,
            "sourceHanatosFullRecompute":sourceHanatosFullRecompute,
            "sourceCameraUVEnabled":sourceCameraUVEnabled,
            "sourceCameraIREnabled":sourceCameraIREnabled,
            "sourceFilmHalationEnabled":sourceFilmHalationEnabled
            ],
            numbers:[
            "strength":strength,
            "filmExposureEV":filmExposureEV,
            "printExposureEV":printExposureEV,
            "halationAmount":halationAmount,
            "grainAmount":grainAmount,
            "scannerSharpenAmount":scannerSharpenAmount,
            "printGamma":printGamma,
            "printFastGamma":printFastGamma,
            "printSlowGamma":printSlowGamma,
            "printDeveloperExhaustion":printDeveloperExhaustion,
            "printSourceDiffusionStrength":printSourceDiffusionStrength,
            "printSourceDiffusionSpatialScale":printSourceDiffusionSpatialScale,
            "printSourceDiffusionWarmth":printSourceDiffusionWarmth,
            "printSourceDiffusionCoreIntensity":printSourceDiffusionCoreIntensity,
            "printSourceDiffusionCoreSize":printSourceDiffusionCoreSize,
            "printSourceDiffusionHaloIntensity":printSourceDiffusionHaloIntensity,
            "printSourceDiffusionHaloSize":printSourceDiffusionHaloSize,
            "printSourceDiffusionBloomIntensity":printSourceDiffusionBloomIntensity,
            "printSourceDiffusionBloomSize":printSourceDiffusionBloomSize,
            "printCyanShift":printCyanShift,
            "printMagentaShift":printMagentaShift,
            "printYellowShift":printYellowShift,
            "preflashExposure":preflashExposure,
            "preflashMagentaShift":preflashMagentaShift,
            "preflashYellowShift":preflashYellowShift,
            "spatialDIRRadiusScale":spatialDIRRadiusScale,
            "sourceScannerLensBlurSigma":sourceScannerLensBlurSigma,
            "sourceScannerUnsharpSigma":sourceScannerUnsharpSigma,
            "sourceScannerUnsharpAmount":sourceScannerUnsharpAmount,
            "sourceScannerGlarePercent":sourceScannerGlarePercent,
            "sourceScannerGlareRoughness":sourceScannerGlareRoughness,
            "sourceScannerGlareBlur":sourceScannerGlareBlur,
            "sourcePhysicalGrainBlur":sourcePhysicalGrainBlur,
            "sourcePhysicalGrainDyeCloudBlur":sourcePhysicalGrainDyeCloudBlur,
            "sourcePhysicalGrainMicroUM":sourcePhysicalGrainMicroUM,
            "sourcePhysicalGrainMicroNM":sourcePhysicalGrainMicroNM,
            "sourceCameraHighlightBoostEV":sourceCameraHighlightBoostEV,
            "sourceCameraHighlightBoostRange":sourceCameraHighlightBoostRange,
            "sourceCameraHighlightProtectEV":sourceCameraHighlightProtectEV,
            "sourceCameraLensBlurUM":sourceCameraLensBlurUM,
            "sourceCameraDiffusionStrength":sourceCameraDiffusionStrength,
            "sourceCameraDiffusionSpatialScale":sourceCameraDiffusionSpatialScale,
            "sourceCameraDiffusionWarmth":sourceCameraDiffusionWarmth,
            "sourceCameraDiffusionCoreIntensity":sourceCameraDiffusionCoreIntensity,
            "sourceCameraDiffusionCoreSize":sourceCameraDiffusionCoreSize,
            "sourceCameraDiffusionHaloIntensity":sourceCameraDiffusionHaloIntensity,
            "sourceCameraDiffusionHaloSize":sourceCameraDiffusionHaloSize,
            "sourceCameraDiffusionBloomIntensity":sourceCameraDiffusionBloomIntensity,
            "sourceCameraDiffusionBloomSize":sourceCameraDiffusionBloomSize,
            "sourceCameraUVAmount":sourceCameraUVAmount,
            "sourceCameraUVCutoffNM":sourceCameraUVCutoffNM,
            "sourceCameraUVWidthNM":sourceCameraUVWidthNM,
            "sourceCameraIRAmount":sourceCameraIRAmount,
            "sourceCameraIRCutoffNM":sourceCameraIRCutoffNM,
            "sourceCameraIRWidthNM":sourceCameraIRWidthNM,
            "sourceFilmScatterAmount":sourceFilmScatterAmount,
            "sourceFilmScatterScale":sourceFilmScatterScale,
            "sourceFilmHalationAmount":sourceFilmHalationAmount,
            "sourceFilmHalationScale":sourceFilmHalationScale
            ],
            choices:[
            "printIlluminant":printIlluminant.rawValue,
            "printSourceDiffusionFamily":printSourceDiffusionFamily.rawValue,
            "sourceCameraMeteringMethod":sourceCameraMeteringMethod.rawValue,
            "sourceCameraDiffusionFamily":sourceCameraDiffusionFamily.rawValue,
            "sourceCameraRawMethod":sourceCameraRawMethod.rawValue
            ],
            embeddedLUT:originalLUT,coverJPEG:cover,
            inputContract:sourcePixelIOEnabled ? currentRecipeInputContract() : nil
        )
    }

    private func setRecipeValues(_ recipe:Build126Recipe) {
        // Called only with a complete, validated schema. No optional
        // defaults: missing/unknown keys must never silently use stale values.
        hanatosOriginalPrecisionEnabled=recipe.bools["hanatosOriginalPrecisionEnabled"]!
        scatterEnabled=recipe.bools["scatterEnabled"]!
        halationEnabled=recipe.bools["halationEnabled"]!
        grainEnabled=recipe.bools["grainEnabled"]!
        grainSublayersEnabled=recipe.bools["grainSublayersEnabled"]!
        grainDiscreteParticlesEnabled=recipe.bools["grainDiscreteParticlesEnabled"]!
        grainOriginalMetalEnabled=recipe.bools["grainOriginalMetalEnabled"]!
        grainOriginalSciPyEnabled=recipe.bools["grainOriginalSciPyEnabled"]!
        originalScannerEnabled=recipe.bools["originalScannerEnabled"]!
        scannerCAM16Enabled=recipe.bools["scannerCAM16Enabled"]!
        scannerBlackWhiteEnabled=recipe.bools["scannerBlackWhiteEnabled"]!
        scannerFinishingEnabled=recipe.bools["scannerFinishingEnabled"]!
        exposureReferenceEnabled=recipe.bools["exposureReferenceEnabled"]!
        printMorphEnabled=recipe.bools["printMorphEnabled"]!
        originalPrintOpticsEnabled=recipe.bools["originalPrintOpticsEnabled"]!
        neutralPrintFiltersFromDatabase=recipe.bools["neutralPrintFiltersFromDatabase"]!
        printSourceDiffusionEnabled=recipe.bools["printSourceDiffusionEnabled"]!
        normalizePrintExposure=recipe.bools["normalizePrintExposure"]!
        printExposureCompensation=recipe.bools["printExposureCompensation"]!
        preflashEnabled=recipe.bools["preflashEnabled"]!
        spatialDIREnabled=recipe.bools["spatialDIREnabled"]!
        spatialDIRSourceConvolutionEnabled=recipe.bools["spatialDIRSourceConvolutionEnabled"]!
        sourcePixelIOEnabled=recipe.bools["sourcePixelIOEnabled"]!
        sourcePhysicalDirectEnabled=recipe.bools["sourcePhysicalDirectEnabled"]!
        sourcePhysicalCAM16DefaultGamutEnabled=recipe.bools["sourcePhysicalCAM16DefaultGamutEnabled"]!
        sourcePhysicalInputOklchEnabled=recipe.bools["sourcePhysicalInputOklchEnabled"]!
        sourceScannerOpticalEnabled=recipe.bools["sourceScannerOpticalEnabled"]!
        sourceScannerGlareEnabled=recipe.bools["sourceScannerGlareEnabled"]!
        sourcePhysicalGrainEnabled=recipe.bools["sourcePhysicalGrainEnabled"]!
        sourceGrainUseUnseededParallel=recipe.bools["sourceGrainUseUnseededParallel"]!
        sourceGrainFastStatsEnabled=recipe.bools["sourceGrainFastStatsEnabled"]!
        sourceCameraPreFilmEnabled=recipe.bools["sourceCameraPreFilmEnabled"]!
        sourceCameraDiffusionEnabled=recipe.bools["sourceCameraDiffusionEnabled"]!
        sourceHanatosFullRecompute=recipe.bools["sourceHanatosFullRecompute"]!
        sourceCameraUVEnabled=recipe.bools["sourceCameraUVEnabled"]!
        sourceCameraIREnabled=recipe.bools["sourceCameraIREnabled"]!
        sourceFilmHalationEnabled=recipe.bools["sourceFilmHalationEnabled"]!
        strength=recipe.numbers["strength"]!
        filmExposureEV=recipe.numbers["filmExposureEV"]!
        printExposureEV=recipe.numbers["printExposureEV"]!
        halationAmount=recipe.numbers["halationAmount"]!
        grainAmount=recipe.numbers["grainAmount"]!
        scannerSharpenAmount=recipe.numbers["scannerSharpenAmount"]!
        printGamma=recipe.numbers["printGamma"]!
        printFastGamma=recipe.numbers["printFastGamma"]!
        printSlowGamma=recipe.numbers["printSlowGamma"]!
        printDeveloperExhaustion=recipe.numbers["printDeveloperExhaustion"]!
        printSourceDiffusionStrength=recipe.numbers["printSourceDiffusionStrength"]!
        printSourceDiffusionSpatialScale=recipe.numbers["printSourceDiffusionSpatialScale"]!
        printSourceDiffusionWarmth=recipe.numbers["printSourceDiffusionWarmth"]!
        printSourceDiffusionCoreIntensity=recipe.numbers["printSourceDiffusionCoreIntensity"]!
        printSourceDiffusionCoreSize=recipe.numbers["printSourceDiffusionCoreSize"]!
        printSourceDiffusionHaloIntensity=recipe.numbers["printSourceDiffusionHaloIntensity"]!
        printSourceDiffusionHaloSize=recipe.numbers["printSourceDiffusionHaloSize"]!
        printSourceDiffusionBloomIntensity=recipe.numbers["printSourceDiffusionBloomIntensity"]!
        printSourceDiffusionBloomSize=recipe.numbers["printSourceDiffusionBloomSize"]!
        printCyanShift=recipe.numbers["printCyanShift"]!
        printMagentaShift=recipe.numbers["printMagentaShift"]!
        printYellowShift=recipe.numbers["printYellowShift"]!
        preflashExposure=recipe.numbers["preflashExposure"]!
        preflashMagentaShift=recipe.numbers["preflashMagentaShift"]!
        preflashYellowShift=recipe.numbers["preflashYellowShift"]!
        spatialDIRRadiusScale=recipe.numbers["spatialDIRRadiusScale"]!
        sourceScannerLensBlurSigma=recipe.numbers["sourceScannerLensBlurSigma"]!
        sourceScannerUnsharpSigma=recipe.numbers["sourceScannerUnsharpSigma"]!
        sourceScannerUnsharpAmount=recipe.numbers["sourceScannerUnsharpAmount"]!
        sourceScannerGlarePercent=recipe.numbers["sourceScannerGlarePercent"]!
        sourceScannerGlareRoughness=recipe.numbers["sourceScannerGlareRoughness"]!
        sourceScannerGlareBlur=recipe.numbers["sourceScannerGlareBlur"]!
        sourcePhysicalGrainBlur=recipe.numbers["sourcePhysicalGrainBlur"]!
        sourcePhysicalGrainDyeCloudBlur=recipe.numbers["sourcePhysicalGrainDyeCloudBlur"]!
        sourcePhysicalGrainMicroUM=recipe.numbers["sourcePhysicalGrainMicroUM"]!
        sourcePhysicalGrainMicroNM=recipe.numbers["sourcePhysicalGrainMicroNM"]!
        sourceCameraHighlightBoostEV=recipe.numbers["sourceCameraHighlightBoostEV"]!
        sourceCameraHighlightBoostRange=recipe.numbers["sourceCameraHighlightBoostRange"]!
        sourceCameraHighlightProtectEV=recipe.numbers["sourceCameraHighlightProtectEV"]!
        sourceCameraLensBlurUM=recipe.numbers["sourceCameraLensBlurUM"]!
        sourceCameraDiffusionStrength=recipe.numbers["sourceCameraDiffusionStrength"]!
        sourceCameraDiffusionSpatialScale=recipe.numbers["sourceCameraDiffusionSpatialScale"]!
        sourceCameraDiffusionWarmth=recipe.numbers["sourceCameraDiffusionWarmth"]!
        sourceCameraDiffusionCoreIntensity=recipe.numbers["sourceCameraDiffusionCoreIntensity"]!
        sourceCameraDiffusionCoreSize=recipe.numbers["sourceCameraDiffusionCoreSize"]!
        sourceCameraDiffusionHaloIntensity=recipe.numbers["sourceCameraDiffusionHaloIntensity"]!
        sourceCameraDiffusionHaloSize=recipe.numbers["sourceCameraDiffusionHaloSize"]!
        sourceCameraDiffusionBloomIntensity=recipe.numbers["sourceCameraDiffusionBloomIntensity"]!
        sourceCameraDiffusionBloomSize=recipe.numbers["sourceCameraDiffusionBloomSize"]!
        sourceCameraUVAmount=recipe.numbers["sourceCameraUVAmount"]!
        sourceCameraUVCutoffNM=recipe.numbers["sourceCameraUVCutoffNM"]!
        sourceCameraUVWidthNM=recipe.numbers["sourceCameraUVWidthNM"]!
        sourceCameraIRAmount=recipe.numbers["sourceCameraIRAmount"]!
        sourceCameraIRCutoffNM=recipe.numbers["sourceCameraIRCutoffNM"]!
        sourceCameraIRWidthNM=recipe.numbers["sourceCameraIRWidthNM"]!
        sourceFilmScatterAmount=recipe.numbers["sourceFilmScatterAmount"]!
        sourceFilmScatterScale=recipe.numbers["sourceFilmScatterScale"]!
        sourceFilmHalationAmount=recipe.numbers["sourceFilmHalationAmount"]!
        sourceFilmHalationScale=recipe.numbers["sourceFilmHalationScale"]!
        printIlluminant=OriginalPrintOptics.Illuminant(rawValue:recipe.choices["printIlluminant"]!)!
        printSourceDiffusionFamily=OriginalSourceDiffusion.Family(rawValue:recipe.choices["printSourceDiffusionFamily"]!)!
        sourceCameraMeteringMethod=OriginalSourceCameraOptics.Metering(rawValue:recipe.choices["sourceCameraMeteringMethod"]!)!
        sourceCameraDiffusionFamily=OriginalSourceDiffusion.Family(rawValue:recipe.choices["sourceCameraDiffusionFamily"]!)!
        sourceCameraRawMethod=SpectralPhysics.CameraRawMethod(rawValue:recipe.choices["sourceCameraRawMethod"]!)!
    }

    private func saveRecipeLibrary(_ entries:[Build126Recipe]) throws {
        try Build126RecipeStorage.write(entries)
        savedRecipes=entries
    }

    func addSavedRecipe(name:String,includeCover:Bool) throws {
        guard hasPhoto,!busy,!simulationAwaitingCurrentSettings,
              !isRecipeApplying,processedPreview != nil,lut != nil else {
            throw ImageProcessingError.invalid(
                "当前效果尚未完整生成；请先完成冲印再保存配方"
            )
        }
        let recipe=recipeSnapshot(
            name:name.trimmingCharacters(in:.whitespacesAndNewlines),
            includeCover:includeCover
        )
        try recipe.validateStructure()
        try saveRecipeLibrary(savedRecipes+[recipe])
        status="已保存「" + recipe.name + "」的完整冲印参数；没有保存照片"
    }

    func renameSavedRecipe(_ recipe:Build126Recipe,to name:String) throws {
        guard let index=savedRecipes.firstIndex(where:{$0.id==recipe.id}) else {
            throw ImageProcessingError.invalid("配方已不存在")
        }
        var entries=savedRecipes
        entries[index].name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        entries[index].modifiedAt=Date()
        try saveRecipeLibrary(entries)
    }

    func duplicateSavedRecipe(_ recipe:Build126Recipe) throws {
        guard let origin=savedRecipes.first(where:{$0.id==recipe.id}) else {
            throw ImageProcessingError.invalid("配方已不存在")
        }
        var copy=origin
        copy.id=UUID()
        copy.name=String((origin.name + " 副本").prefix(40))
        copy.favorite=false
        copy.createdAt=Date()
        copy.modifiedAt=Date()
        try saveRecipeLibrary(savedRecipes+[copy])
    }

    func toggleRecipeFavorite(_ recipe:Build126Recipe) throws {
        guard let index=savedRecipes.firstIndex(where:{$0.id==recipe.id}) else {
            throw ImageProcessingError.invalid("配方已不存在")
        }
        var entries=savedRecipes
        entries[index].favorite.toggle()
        entries[index].modifiedAt=Date()
        try saveRecipeLibrary(entries)
    }

    func deleteSavedRecipe(_ recipe:Build126Recipe) throws {
        guard savedRecipes.contains(where:{$0.id==recipe.id}) else {
            throw ImageProcessingError.invalid("配方已不存在")
        }
        try saveRecipeLibrary(savedRecipes.filter{$0.id != recipe.id})
    }

    func importSavedRecipe(_ url:URL) throws {
        var recipe=try Build126RecipeStorage.imported(from:url)
        recipe.id=UUID()
        recipe.createdAt=Date()
        recipe.modifiedAt=Date()
        try saveRecipeLibrary(savedRecipes+[recipe])
        status="导入配方「" + recipe.name + "」完成；尚未应用，也未导入照片"
    }

    func exportSavedRecipe(_ recipe:Build126Recipe) throws -> URL {
        guard let found=savedRecipes.first(where:{$0.id==recipe.id}) else {
            throw ImageProcessingError.invalid("配方不存在")
        }
        return try Build126RecipeStorage.export(found)
    }

    /// Reject incompatible source-pixel recipes before touching ANY setting.
    /// Legacy nil input contract = Build126 8-bit; precision NEVER escalates
    /// or demotes to match a different source without explicit conversion.
    func preflightSavedRecipe(_ recipe:Build126Recipe) throws {
        try recipe.validateStructure()
        guard hasPhoto,!busy,!simulationAwaitingCurrentSettings,
              !isRecipeApplying,source != nil else {
            throw ImageProcessingError.invalid("请先打开照片并完成当前冲印")
        }
        guard SpectralPhysics.supportedFilmIDs.contains(recipe.filmID),
              SpectralPhysics.supportedPaperIDs.contains(recipe.paperID) else {
            throw ImageProcessingError.invalid(
                "配方的胶片或相纸不属于当前可模拟材料；未修改原编辑"
            )
        }
        let bs=recipe.bools
        let pixel=bs["sourcePixelIOEnabled"]==true
        let physical=bs["sourcePhysicalDirectEnabled"]==true
        if physical && !pixel {
            throw ImageProcessingError.invalid(
                "精细全光学依赖原版像素直连；配方前置条件相互冲突"
            )
        }
        if pixel {
            // Check the exact captured input precision, not merely
            // transport admission. Old Build126 recipes were STRICT 8-bit.
            let expected=recipe.inputContract ?? "uint8SRGB"
            guard let p=photoInputProfile,
                  originalPhotoData != nil,!rawFastModeActive,p.directCompatible else {
                throw ImageProcessingError.invalid(
                    "配方要求 " + expected +
                    "；当前 RAW／照片没有已认证的可直连像素副本。" +
                    "本次已放弃，原设置和预览不变。"
                )
            }
            let actual=currentRecipeInputContract()
            guard actual==expected else {
                throw ImageProcessingError.invalid(
                    "配方输入位深不兼容：要求 " + expected +
                    "，当前 " + (actual ?? p.summary) +
                    "。8-bit 绝不假装 Float32，Float32 也不暗降为 8-bit；" +
                    "本次拒绝应用，原设置和预览不变。"
                )
            }
            if expected=="uint8SRGB" {
                guard p.declaredDepth==8,p.decodedDepth==8,
                      p.color == .sRGB,!p.hasAlphaChannel,
                      !p.floatingComponents else {
                    throw ImageProcessingError.invalid(
                        "Build126 旧配方必须匹配 8-bit sRGB，不允许自动改变输入位深"
                    )
                }
            }
            guard bs["spatialDIREnabled"]==true,
                  bs["spatialDIRSourceConvolutionEnabled"]==true,
                  bs["grainEnabled"]==false,
                  bs["scannerFinishingEnabled"]==false,
                  abs((recipe.numbers["strength"] ?? 0)-1.0)<1e-9 else {
                throw ImageProcessingError.invalid(
                    "原版像素直连依赖 FIR/YVV、100% 强度，" +
                    "且不支持旧版随机颗粒或扫描后处理；配方拒绝应用"
                )
            }
            if physical {
                guard bs["hanatosOriginalPrecisionEnabled"]==true,
                      bs["originalScannerEnabled"]==true,
                      bs["scannerCAM16Enabled"]==false,
                      bs["scannerBlackWhiteEnabled"]==false,
                      bs["exposureReferenceEnabled"]==false else {
                    throw ImageProcessingError.invalid(
                        "精细全光学要求原版 Float64、ACES 扫描及独立工艺依赖；" +
                        "配置不满足前置条件，拒绝应用"
                    )
                }
            }
        }
        if recipe.embeddedLUT != nil &&
            (pixel || bs["grainEnabled"]==true ||
             bs["spatialDIREnabled"]==true) {
            throw ImageProcessingError.invalid(
                "自定义 .cube 不含原版胶片密度／DIR 阶段，" +
                "不能假装支持精确或密度颗粒模式；配置拒绝应用"
            )
        }
    }

    func applySavedRecipe(_ recipe:Build126Recipe) throws {
        try preflightSavedRecipe(recipe)
        let previous=recipeSnapshot(name:"回滚",includeCover:false)
        recipeUndo=RecipeUndo(
            settings:previous,lut:lut,density:densityGrainStage,
            dir:spatialDIRStage,preview:processedPreview,
            previousStatus:status,
            hadPendingSimulation:simulationAwaitingCurrentSettings,
            desiredName:recipe.name
        )
        isRecipeApplying=true
        setRecipeValues(recipe)
        recipeFilmSelectionToIgnore=recipe.filmID
        recipePaperSelectionToIgnore=recipe.paperID
        UserDefaults.standard.set(recipe.filmID,forKey:"compactFilmStock")
        UserDefaults.standard.set(recipe.paperID,forKey:"compactPaperStock")
        if let saved=recipe.embeddedLUT {
            // Imported LUT has no measured density/DIR tape. Validated above.
            invalidateSimulation()
            lut=FilmLUT(
                title:saved.title,dimension:saved.dimension,
                rgbaFloatData:saved.rgbaFloatData
            )
            densityGrainStage=nil
            spatialDIRStage=nil
            do {
                try refresh()
                if processedPreview != nil { finishRecipePreview() }
            } catch {
                rejectRecipePreview(error.localizedDescription)
            }
        } else {
            applyMeasuredSimulation()
        }
    }

    private func finishRecipePreview() {
        guard let undo=recipeUndo else {return}
        recipeUndo=nil
        isRecipeApplying=false
        busy=false
        status="配方「" + undo.desiredName +
            "」已完整应用至当前照片；原始照片未保存到配方库"
    }

    private func rejectRecipePreview(_ reason:String) {
        guard let undo=recipeUndo else {return}
        // Kill any previous or in-flight preview before replaying cached
        // state. This is a rollback, NOT a silent fast-mode fallback.
        invalidateSimulation()
        originalMetalPreviewVersion &+= 1
        setRecipeValues(undo.settings)
        recipeFilmSelectionToIgnore=undo.settings.filmID
        recipePaperSelectionToIgnore=undo.settings.paperID
        UserDefaults.standard.set(undo.settings.filmID,
                                  forKey:"compactFilmStock")
        UserDefaults.standard.set(undo.settings.paperID,
                                  forKey:"compactPaperStock")
        lut=undo.lut
        densityGrainStage=undo.density
        spatialDIRStage=undo.dir
        processedPreview=undo.preview
        simulationAwaitingCurrentSettings=undo.hadPendingSimulation
        recipeUndo=nil
        isRecipeApplying=false
        busy=false
        status="配方「" + undo.desiredName +
            "」应用失败并已完整回滚：" + reason
    }

    /// Original Bayer DNG file from the most recent RAW+JPEG capture.
    @Published var capturedRAWURL: URL?
    /// Build93: only an explicit user choice opens non-source Apple RAW.
    @Published var rawNeedsChoice = false
    @Published var rawFastModeActive = false
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
    @Published var neutralPrintFiltersFromDatabase = true
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
    // 47-item integration: opt-in ACTUAL original CAM16-UCS default
    // on the Float64 source physical path. Legacy CI/ACES stays unchanged.
    // Not full gamut or device/image certification.
    @Published var sourcePhysicalCAM16DefaultGamutEnabled = false
    // Independently tested upstream InputGamutCompressSpec(algorithm="oklch").
    // Explicit opt-in; never silently replace the original default xy.
    @Published var sourcePhysicalInputOklchEnabled = false
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
    // Batch v1.8.48: opt-in actual three-sublayer film grain BEFORE
    // the enlarger, not old mobile Gaussian/Metal post-density noise.
    // SciPy count RNG seeds remain original [ch+sl*10].
    // Numba microstructure defaults to controlled seed=8888 until the
    // separate explicitly selected Build115 parallel option is enabled.
    @Published var sourcePhysicalGrainEnabled = false
    // Build115 separate source-default unseeded Numba parallel candidate.
    // OFF preserves exact seeded single-thread parity fixtures.
    @Published var sourceGrainUseUnseededParallel = false
    // Actual Python grain.py defaults use_fast_stats=false (SciPy particles).
    // Explicit user selection enables original optional fast_stats prange.
    @Published var sourceGrainFastStatsEnabled = false
    @Published var sourcePhysicalGrainBlur = 0.65
    @Published var sourcePhysicalGrainDyeCloudBlur = 1.0
    @Published var sourcePhysicalGrainMicroUM = 0.2
    @Published var sourcePhysicalGrainMicroNM = 30.0
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
    @Published var sourceHanatosFullRecompute = false
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

    /// If a user has requested grain, a missing prepared density stage
    /// must never produce a plain LUT image and call it grain development.
    private func requireConfiguredGrain() throws {
        if !sourcePixelIOEnabled && grainEnabled && grainAmount > 0 {
            guard densityGrainStage != nil, lut != nil else {
                throw ImageProcessingError.invalid(
                    "密度颗粒已开启，但显影密度阶段尚未生成。" +
                    "请重新选择胶片或关闭颗粒；禁止静默输出无颗粒图像。"
                )
            }
        }
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
    private var rawPreviewTask: Task<Void, Never>?
    private var originalMetalPreviewVersion = 0
    // A stale simulation cannot release the busy state of a newer request.
    private var activeSimulationGeneration: Int?
    @Published private(set) var simulationAwaitingCurrentSettings = false
    /// Updated on every committed photo, including identical dimensions.
    @Published private(set) var photoSessionRevision: UInt64 = 0
    private var photoTransferToken: UInt64 = 0
    private var photoTransferActive = false
    private var photoTransferTask: Task<Void, Never>?

    /// Build141: crop applies to packed LibRaw ACES16 BEFORE the Float64
    /// frame, memory admission, DIR, grain and print. Coordinates are always
    /// the native LibRaw image, never the Apple/JPEG compatible thumbnail.
    func setRAWCrop(
        normalizedX:Double,normalizedY:Double,
        normalizedWidth:Double,normalizedHeight:Double
    ) throws {
        guard rawOriginalSourceActive && sourcePhysicalDirectEnabled,
              capturedRAWURL != nil,source != nil,
              !busy && !simulationAwaitingCurrentSettings,
              rawCropReferencePreview != nil,
              rawCropReferenceWidth>0,rawCropReferenceHeight>0 else {
            throw ImageProcessingError.invalid(
                "RAW 原片预览尚未生成或冲印正在运行，暂不能确认裁切"
            )
        }
        let selection=try Build141RAWPreCrop.selection(
            sourceWidth:rawCropReferenceWidth,
            sourceHeight:rawCropReferenceHeight,
            normalizedX:normalizedX,normalizedY:normalizedY,
            normalizedWidth:normalizedWidth,normalizedHeight:normalizedHeight
        )
        rawCropSelection=selection.isWholeSource ? nil : selection
        status="RAW 冲印前裁切：原始 \(rawCropReferenceWidth)×\(rawCropReferenceHeight) → " +
            "\(selection.width)×\(selection.height)，正在重新计算光学预览；原片不变"
        queueSpectralPreview()
    }

    func clearRAWCrop() {
        guard rawOriginalSourceActive && sourcePhysicalDirectEnabled,
              !busy && !simulationAwaitingCurrentSettings,
              rawCropSelection != nil else {return}
        rawCropSelection=nil
        status="已恢复 RAW 全图精细冲印；原片从未修改"
        queueSpectralPreview()
    }

    /// Build142: current-photo factory reset only. All defaults below are
    /// copied from this class's actual @Published declarations, NOT from an
    /// independently maintained recipe, migration or experimental profile.
    ///
    /// Keeps current image/RAW, crop coordinates, local RAW gallery, saved
    /// recipes and session; the selected film/paper reset to actual defaults.
    /// For a verified RAW, preserve mandatory direct original Float64
    /// prerequisites (not the old mobile/8-bit pipeline).
    func resetAllProcessingToDefaults() throws {
        guard hasPhoto,!busy,!isRecipeApplying else {
            throw ImageProcessingError.invalid(
                "冲印正在执行或没有照片；无法恢复默认配置"
            )
        }
        let rawMode=rawOriginalSourceActive
        if rawMode && capturedRAWURL == nil {
            throw ImageProcessingError.invalid(
                "当前 RAW 原片不存在；未修改任何处理配置"
            )
        }
        let defaultFilm="kodak_portra_400"
        let defaultPaper="kodak_portra_endura"
        guard SpectralPhysics.supportedFilmIDs.contains(defaultFilm),
              SpectralPhysics.supportedPaperIDs.contains(defaultPaper) else {
            throw ImageProcessingError.invalid(
                "原版默认胶片或相纸不可用；未更改当前参数"
            )
        }
        if rawMode {
            guard let url=capturedRAWURL,
                  try Build79RAWSignature.probeFile(url) != nil else {
                throw ImageProcessingError.invalid(
                    "当前 RAW 原片不可验证；拒绝重置为兼容模式"
                )
            }
        }
        // Refuse an in-progress render; invalidate any pending or failed
        // previous settings before mutating the 100 image adjustments.
        invalidateSimulation()
        recipeUndo=nil
        recipeFilmSelectionToIgnore=nil
        recipePaperSelectionToIgnore=nil
        originalMetalPreviewVersion &+= 1
        filmExposureEV=0.0
        printExposureEV=0.0
        hanatosOriginalPrecisionEnabled=true
        scatterEnabled=false
        halationEnabled=false
        halationAmount=1.0
        grainEnabled=false
        grainAmount=1.0
        grainSublayersEnabled=false
        grainDiscreteParticlesEnabled=false
        grainOriginalMetalEnabled=false
        grainOriginalSciPyEnabled=false
        originalScannerEnabled=false
        scannerCAM16Enabled=false
        scannerBlackWhiteEnabled=false
        scannerFinishingEnabled=false
        scannerSharpenAmount=0.7
        exposureReferenceEnabled=false
        printMorphEnabled=false
        printGamma=1.0
        printFastGamma=1.0
        printSlowGamma=1.0
        printDeveloperExhaustion=0.0
        originalPrintOpticsEnabled=false
        printIlluminant = .thKG3
        neutralPrintFiltersFromDatabase=true
        printSourceDiffusionEnabled=false
        printSourceDiffusionFamily = .blackProMist
        printSourceDiffusionStrength=0.5
        printSourceDiffusionSpatialScale=1.0
        printSourceDiffusionWarmth=0.0
        printSourceDiffusionCoreIntensity=1.0
        printSourceDiffusionCoreSize=1.0
        printSourceDiffusionHaloIntensity=1.0
        printSourceDiffusionHaloSize=1.0
        printSourceDiffusionBloomIntensity=1.0
        printSourceDiffusionBloomSize=1.0
        normalizePrintExposure=true
        printExposureCompensation=true
        printCyanShift=0.0
        printMagentaShift=0.0
        printYellowShift=0.0
        preflashEnabled=false
        preflashExposure=0.0
        preflashMagentaShift=0.0
        preflashYellowShift=0.0
        spatialDIREnabled=false
        spatialDIRRadiusScale=1.0
        spatialDIRSourceConvolutionEnabled=true
        sourcePixelIOEnabled=false
        sourcePhysicalDirectEnabled=false
        sourcePhysicalCAM16DefaultGamutEnabled=false
        sourcePhysicalInputOklchEnabled=false
        sourceScannerOpticalEnabled=false
        sourceScannerLensBlurSigma=0.0
        sourceScannerUnsharpSigma=1.0
        sourceScannerUnsharpAmount=0.7
        sourceScannerGlareEnabled=false
        sourceScannerGlarePercent=0.03
        sourceScannerGlareRoughness=0.7
        sourceScannerGlareBlur=0.5
        sourcePhysicalGrainEnabled=false
        sourceGrainUseUnseededParallel=false
        sourceGrainFastStatsEnabled=false
        sourcePhysicalGrainBlur=0.65
        sourcePhysicalGrainDyeCloudBlur=1.0
        sourcePhysicalGrainMicroUM=0.2
        sourcePhysicalGrainMicroNM=30.0
        sourceCameraPreFilmEnabled=false
        sourceCameraMeteringMethod = .centerWeighted
        sourceCameraHighlightBoostEV=0.0
        sourceCameraHighlightBoostRange=0.3
        sourceCameraHighlightProtectEV=4.0
        sourceCameraLensBlurUM=0.0
        sourceCameraDiffusionEnabled=false
        sourceCameraDiffusionFamily = .blackProMist
        sourceCameraDiffusionStrength=0.5
        sourceCameraDiffusionSpatialScale=1.0
        sourceCameraDiffusionWarmth=0.0
        sourceCameraDiffusionCoreIntensity=1.0
        sourceCameraDiffusionCoreSize=1.0
        sourceCameraDiffusionHaloIntensity=1.0
        sourceCameraDiffusionHaloSize=1.0
        sourceCameraDiffusionBloomIntensity=1.0
        sourceCameraDiffusionBloomSize=1.0
        sourceCameraRawMethod = .hanatos2025
        sourceHanatosFullRecompute=false
        sourceCameraUVEnabled=false
        sourceCameraUVAmount=1.0
        sourceCameraUVCutoffNM=410.0
        sourceCameraUVWidthNM=8.0
        sourceCameraIREnabled=false
        sourceCameraIRAmount=1.0
        sourceCameraIRCutoffNM=675.0
        sourceCameraIRWidthNM=15.0
        sourceFilmHalationEnabled=false
        sourceFilmScatterAmount=1.0
        sourceFilmScatterScale=1.0
        sourceFilmHalationAmount=1.0
        sourceFilmHalationScale=1.0

        // Camera/Photos/Files input and crop are NOT processing presets.
        // A RAW must remain in full optical mode after factory reset.
        if rawMode {
            strength=1.0
            hanatosOriginalPrecisionEnabled=true
            originalScannerEnabled=true
            originalPrintOpticsEnabled=true
            spatialDIREnabled=true
            spatialDIRSourceConvolutionEnabled=true
            sourcePixelIOEnabled=true
            sourcePhysicalDirectEnabled=true
            rawOriginalSourceActive=true
        }
        rawFullResolutionPreview=false
        // Source/raw transport is preserved but stale optical simulation
        // and imported compatibility LUT must not be presented as defaults.
        lut=nil
        densityGrainStage=nil
        spatialDIRStage=nil

        let previousFilm=UserDefaults.standard.string(
            forKey:"compactFilmStock") ?? defaultFilm
        let previousPaper=UserDefaults.standard.string(
            forKey:"compactPaperStock") ?? defaultPaper
        // The parent @AppStorage onChange must not queue another preview:
        // this reset transaction owns the single new optical generation.
        if previousFilm != defaultFilm {
            recipeFilmSelectionToIgnore=defaultFilm
            UserDefaults.standard.set(defaultFilm,forKey:"compactFilmStock")
        }
        if previousPaper != defaultPaper {
            recipePaperSelectionToIgnore=defaultPaper
            UserDefaults.standard.set(defaultPaper,forKey:"compactPaperStock")
        }
        status="已恢复默认冲印配置：胶片、相纸与全部调节归零；" +
            (rawMode ? "保留 RAW 原版 Float64 精细模式、" : "") +
            "照片及裁切不变，重新生成预览"
        queueSpectralPreview()
    }

    /// A display-only preference; unchanged source stock and full export.
    func selectRAWPreview(fullResolution:Bool) {
        guard rawOriginalSourceActive && sourcePhysicalDirectEnabled &&
              capturedRAWURL != nil else {return}
        guard !busy else {
            status="RAW 冲印尚未完成，无法更改预览尺寸"
            return
        }
        guard rawFullResolutionPreview != fullResolution else {return}
        rawFullResolutionPreview=fullResolution
        queueSpectralPreview()
    }

    func queueSpectralPreview() {
        pendingRender?.cancel()
        rawPreviewTask?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        guard hasPhoto else {
            simulationAwaitingCurrentSettings=false
            return
        }
        simulationAwaitingCurrentSettings=true
        originalMetalPreviewVersion &+= 1
        processedPreview=nil
        pendingRender = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled && generation == renderGeneration else { return }
            if rawOriginalSourceActive && sourcePhysicalDirectEnabled {
                // Build138: precision RAW renders straight from LibRaw + the
                // selected source film/paper. The 17^3 compatibility LUT and
                // mobile DIR stage are NOT consumed in this route; do not
                // generate them just to make the selected stock take effect.
                activeSimulationGeneration=generation
                busy=true
                do {
                    try refresh()
                } catch {
                    guard generation == renderGeneration else {return}
                    activeSimulationGeneration=nil
                    busy=false
                    processedPreview=nil
                    status="RAW 精细冲印无法执行（未降级）：" +
                        error.localizedDescription
                }
                return
            }
            applyMeasuredSimulation(generation: generation)
        }
    }

    private func invalidateSimulation() {
        pendingRender?.cancel()
        rawPreviewTask?.cancel()
        P1OriginalRawACESIngress.clearAllInputCaches()
        renderGeneration &+= 1
        simulationAwaitingCurrentSettings=false
        // When replacing a photo while an old non-cancellable source task
        // is still running, its stale completion exits before the normal
        // busy cleanup. Only release busy when THIS simulation owns it.
        if activeSimulationGeneration != nil {
            activeSimulationGeneration=nil
            busy=false
        }
    }

    private var source: CIImage?
    private var originalPhotoData: Data?
    /// Saved RAW waiting for a decoder. This is NOT the currently edited RAW.
    private var pendingImportedRAWURL: URL?

    private struct EditingSnapshot {
        let source: CIImage?
        let sourceData: Data?
        let rawURL: URL?
        let pendingRAWURL: URL?
        let needsRAWChoice: Bool
        let rawFastMode: Bool
        let rawOriginal: Bool
        let originalPreview: UIImage?
        let processedPreview: UIImage?
        let crop:Build141RAWPreCrop.Selection?
        let cropReference:UIImage?
        let cropReferenceWidth:Int
        let cropReferenceHeight:Int
        let fullRAWPreview:Bool
        let dimensions: String
        let sourcePixel: Bool
        let sourcePhysical: Bool
        let inputProfile:Build111PhotoInputProfile.Inspection?
        let convertedFromP3:Bool
        let unconvertedData:Data?
    }

    private func snapshotEditing() -> EditingSnapshot {
        EditingSnapshot(
            source:source, sourceData:originalPhotoData,
            rawURL:capturedRAWURL, pendingRAWURL:pendingImportedRAWURL,
            needsRAWChoice:rawNeedsChoice, rawFastMode:rawFastModeActive,
            rawOriginal:rawOriginalSourceActive,
            originalPreview:originalPreview, processedPreview:processedPreview,
            crop:rawCropSelection,cropReference:rawCropReferencePreview,
            cropReferenceWidth:rawCropReferenceWidth,
            cropReferenceHeight:rawCropReferenceHeight,
            fullRAWPreview:rawFullResolutionPreview,
            dimensions:photoDimensions,
            sourcePixel:sourcePixelIOEnabled,
            sourcePhysical:sourcePhysicalDirectEnabled,
            inputProfile:photoInputProfile,
            convertedFromP3:photoInputConvertedFromP3,
            unconvertedData:photoOriginalBeforeColorConversion
        )
    }

    private func restoreEditing(_ prior: EditingSnapshot) {
        invalidateSimulation()
        originalMetalPreviewVersion &+= 1
        source=prior.source
        originalPhotoData=prior.sourceData
        capturedRAWURL=prior.rawURL
        pendingImportedRAWURL=prior.pendingRAWURL
        rawNeedsChoice=prior.needsRAWChoice
        rawFastModeActive=prior.rawFastMode
        rawOriginalSourceActive=prior.rawOriginal
        originalPreview=prior.originalPreview
        processedPreview=prior.processedPreview
        rawCropSelection=prior.crop
        rawCropReferencePreview=prior.cropReference
        rawCropReferenceWidth=prior.cropReferenceWidth
        rawCropReferenceHeight=prior.cropReferenceHeight
        rawFullResolutionPreview=prior.fullRAWPreview
        photoDimensions=prior.dimensions
        sourcePixelIOEnabled=prior.sourcePixel
        sourcePhysicalDirectEnabled=prior.sourcePhysical
        photoInputProfile=prior.inputProfile
        photoInputConvertedFromP3=prior.convertedFromP3
        photoOriginalBeforeColorConversion=prior.unconvertedData
    }

    /// Commit source and UI state only after successful file decoding
    /// and initial preview. If the active film pipeline refuses the image,
    /// restore the previous photo, modes, and displayed preview atomically.
    private func commitDecodedPhoto(
        image:CIImage, preview:UIImage,
        data:Data?, rawURL:URL?, rawCompatible:Bool,
        dimensions:String,
        inputProfile:Build111PhotoInputProfile.Inspection? = nil
    ) throws {
        let prior=snapshotEditing()
        invalidateSimulation()
        // A newly imported P3/untagged/high-bit image must never inherit
        // the previous photo's active original Float64 pixel mode.
        if rawCompatible || inputProfile?.directCompatible != true {
            sourcePixelIOEnabled=false
            sourcePhysicalDirectEnabled=false
        }
        source=image
        originalPhotoData=data
        photoInputProfile=inputProfile
        photoInputConvertedFromP3=false
        photoOriginalBeforeColorConversion=nil
        originalPreview=preview
        processedPreview=preview
        photoDimensions=dimensions
        rawFastModeActive=rawCompatible
        rawOriginalSourceActive=false
        rawFullResolutionPreview=false
        rawCropSelection=nil
        rawCropReferencePreview=nil
        rawCropReferenceWidth=0
        rawCropReferenceHeight=0
        capturedRAWURL=rawURL
        do {
            try refresh()
            if rawCompatible { pendingImportedRAWURL=nil }
            rawNeedsChoice=false
            photoSessionRevision &+= 1
        } catch {
            restoreEditing(prior)
            throw error
        }
    }

    func dismissPendingRAWChoice() {
        guard pendingImportedRAWURL != nil else { return }
        pendingImportedRAWURL=nil
        rawNeedsChoice=false
        status="RAW 原片已保存，当前照片和编辑设置保持不变"
    }

    /// Deleting an active app-owned RAW must not leave a lazy CIImage
    /// pointing at a removed file or allow precision export on a ghost URI.
    func isCurrentSavedRAW(_ url:URL)->Bool {
        url.standardizedFileURL == capturedRAWURL?.standardizedFileURL
    }

    func didDeleteSavedRAW(_ url:URL) {
        let file=url.standardizedFileURL
        let active=capturedRAWURL?.standardizedFileURL == file
        let pending=pendingImportedRAWURL?.standardizedFileURL == file
        guard active || pending else {
            status="本机 RAW 副本已删除，其他编辑与原片不变"
            return
        }
        if pending {
            pendingImportedRAWURL=nil
            rawNeedsChoice=false
        }
        if active {
            invalidateSimulation()
            originalMetalPreviewVersion &+= 1
            source=nil
            originalPhotoData=nil
            photoOriginalBeforeColorConversion=nil
            photoInputProfile=nil
            photoInputConvertedFromP3=false
            originalPreview=nil
            processedPreview=nil
            capturedRAWURL=nil
            rawCropSelection=nil
            rawCropReferencePreview=nil
            rawCropReferenceWidth=0
            rawCropReferenceHeight=0
            rawFastModeActive=false
            rawOriginalSourceActive=false
            rawFullResolutionPreview=false
            sourcePixelIOEnabled=false
            sourcePhysicalDirectEnabled=false
            photoDimensions=""
            photoSessionRevision &+= 1
        }
        PhotoProcessor.clearTransientCaches()
        status=active
            ? "已删除当前本机 RAW 并退出编辑；胶片及相纸选择保留"
            : "已删除待导入 RAW 副本；当前编辑未改变"
    }

    var hasPhoto: Bool { source != nil }
    /// Read-only actual source geometry for independent Build133 RAW probes.
    /// The private CIImage and its backed pixels never leave the model.
    var rawMemorySourceExtent: CGRect? { source?.extent.integral }
    /// RAW-compatible CI images do NOT satisfy direct source pixel input.
    /// Full high-depth/ICC validation still runs inside the exact pipeline.
    var originalPixelInputAvailable: Bool {
        photoDirectInputReady
    }

    /// Explicitly reject all unported combinations in direct source mode.
    /// No silent switch back to Core Image when the user selected precision.
    private func validateSourcePixelIO() throws -> (Data,SpatialDIRStage) {
        guard photoDirectInputReady else {
            throw ImageProcessingError.invalid("照片输入预检未通过："+photoInputSummary+"。"+photoInputExplanation)
        }
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
            neutralPrintFiltersFromDatabase:neutralPrintFiltersFromDatabase,
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
        // Build82 Hanatos UV/IR rebuilds the original spectral TC LUT
        // from 81 wavelengths; any missing dataset reports a hard error.
        // Build77/03: source-physical mode must use the Python original
        // per-film antihalation/use metadata and source halation presets.
        // The familiar UI scatter/halation amount sliders remain multipliers;
        // the underlying physical baseline is now stock-specific.
        let stockHalation=try Build77StockHalation.originalPreset(filmID:filmID)
        var sourceHalation=OriginalSourceFilmHalation.routedSettings(
            combinedEnabled:sourceFilmHalationEnabled,
            scatterToggle:scatterEnabled,
            halationToggle:halationEnabled,
            legacyHalationAmount:halationAmount,
            sourceScatterAmount:sourceFilmScatterAmount,
            sourceScatterScale:sourceFilmScatterScale,
            sourceHalationAmount:sourceFilmHalationAmount,
            sourceHalationScale:sourceFilmHalationScale
        )
        sourceHalation.halationFirstSigmaUM=stockHalation.sigmaUM
        sourceHalation.halationStrength=stockHalation.strength
        // Build138 hotfix: a direct RAW has no mobile 17^3 DIR cache.
        // spatialDIRSettings intentionally disables mobile DIR until
        // spatialDIRStage exists. The Float64 RAW renderer does NOT consume
        // that cache: its source FIR/YVV is built from the actual switches.
        // Ordinary photo/compatibility input retains its old stage gate.
        let physicalDIR:SpatialDIRSettings = rawOriginalSourceActive
            ? SpatialDIRSettings(
                enabled:spatialDIREnabled,
                diffusionRadiusScale:spatialDIRRadiusScale,
                tailWeight:0.06,
                sourceConvolutionEnabled:spatialDIRSourceConvolutionEnabled
            )
            : spatialDIRSettings
        var p=OriginalSourcePhysicalImage.Parameters(
            filmID:filmID,paperID:paperID,
            cameraEV:filmExposureEV,paperEV:printExposureEV,
            dir:physicalDIR,print:print,morph:morph,
            scannerOptics:sourceScan,
            scannerGlare:OriginalSourceScannerGlare.Settings(
                active:sourceScannerGlareEnabled,
                percent:sourceScannerGlarePercent,
                roughness:sourceScannerGlareRoughness,
                blur:sourceScannerGlareBlur
            ),
            scannerGlareSeed:sourceScannerGlareEnabled ? 8888 : nil,
            sourceGrain:OriginalSourcePhysicalGrain.Settings(
                active:sourcePhysicalGrainEnabled,
                useFastStats:sourceGrainFastStatsEnabled,
                fastStatsSeed:sourcePhysicalGrainEnabled &&
                    sourceGrainFastStatsEnabled &&
                    !sourceGrainUseUnseededParallel ? 8888 : nil,
                useUnseededParallel:sourceGrainUseUnseededParallel,
                grainBlur:sourcePhysicalGrainBlur,
                dyeCloudBlurUM:sourcePhysicalGrainDyeCloudBlur,
                microstructureUM:sourcePhysicalGrainMicroUM,
                microstructureNM:sourcePhysicalGrainMicroNM,
                numbaSeed:sourcePhysicalGrainEnabled &&
                    !sourceGrainUseUnseededParallel ? 8888 : nil
            ),
            cameraOptics:preCamera,
            filmHalation:sourceHalation,
            cameraRawMethod:sourceCameraRawMethod,
            cameraBandpass:sourceBandpass,
            hanatosSourceRecompute:sourceHanatosFullRecompute,
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
        if sourcePhysicalInputOklchEnabled {
            // Bake source Oklch into Hanatos TC LUT. Engine enforces
            // actual Float64 recompute and rejects non-Hanatos input.
            p.sourceInputGamutAlgorithm = .oklch
        }
        if sourcePhysicalCAM16DefaultGamutEnabled {
            // Keep original ScannerStage: spectral paper XYZ → RAW linear
            // RGB → source OutputGamutCompressSpec() CAM16-UCS Double.
            // Legacy scannerCAM16Enabled is the separate 33³ LUT mode
            // and remains blocked by sourcePhysicalParameters() guard.
            p.sourceOutputGamut=Build89OriginalOutputGamut.Settings()
        }
        try p.validate()
        return p
    }

    /// A PhotosPicker Data representation is NOT necessarily the RAW master.
    /// Classify its real header, archive a verified original if supplied,
    /// and refuse a JPEG representation when the picker advertises RAW.
    /// This never relabels an Apple-rendered image as sensor data.
    private func preservePickerRAWIfPresent(
        _ data:Data
    ) throws -> Build79RAWStorage.Preserved? {
        let header=Data(data.prefix(512*1024))
        for kind in Build79RAWSignature.Kind.allCases {
            guard (try? Build79RAWSignature.classify(
                filename:"selected."+kind.rawValue,header:header
            )) == kind else {continue}
            let temp=FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString+"."+kind.rawValue)
            try data.write(to:temp,options:.atomic)
            defer {try? FileManager.default.removeItem(at:temp)}
            return try Build79RAWStorage.preserve(temp,kind:kind)
        }
        return nil
    }

    private func pickerAdvertisesRAW(_ selection:PhotosPickerItem)->Bool {
        let extensions:Set<String>=[
            "dng","raf","arw","nef","cr2","cr3","orf","rw2","pef",
            "srw","raw","rwl","3fr","iiq","k25","erf"
        ]
        return selection.supportedContentTypes.contains { type in
            let ext=type.preferredFilenameExtension?.lowercased() ?? ""
            let id=type.identifier.lowercased()
            return extensions.contains(ext) || id.contains("raw-image") ||
                   id.contains("digital-negative")
        }
    }

    func selectFromPhotos(_ selection: PhotosPickerItem?) {
        guard let selection else { return }
        // A new selection supersedes only an in-flight Photos transfer.
        // Never interrupt optical rendering, save, or RAW decoding.
        guard !busy || photoTransferActive else {
            status="正在执行其他处理；照片导入未开始，当前编辑保持不变"
            return
        }
        photoTransferTask?.cancel()
        photoTransferToken &+= 1
        let token=photoTransferToken
        photoTransferActive=true
        busy=true
        status="正在读取相册照片…"
        photoTransferTask=Task { @MainActor in
            defer {
                if token == photoTransferToken {
                    photoTransferActive=false
                    busy=false
                    photoTransferTask=nil
                }
            }
            do {
                guard let data=try await selection.loadTransferable(
                    type: Data.self
                ) else {
                    throw ImageProcessingError.invalid("相册未提供照片数据")
                }
                guard !Task.isCancelled && token == photoTransferToken else {
                    return
                }
                if let preserved=try preservePickerRAWIfPresent(data) {
                    pendingImportedRAWURL=preserved.url
                    rawNeedsChoice = !(preserved.format == .dng ||
                                       preserved.format == .raf)
                    status="已验证相册返回真实 RAW 原片，已无损归档；" +
                        (rawNeedsChoice
                         ? "该 RAW 格式暂不支持自动精细冲印，请手动选择解码。"
                         : "自动使用当前胶片／相纸进入精细冲印。")
                    if !rawNeedsChoice {
                        // Defer until this transfer task's busy cleanup has
                        // finished; otherwise RAW decoder would be refused.
                        Task { @MainActor in
                            guard token == self.photoTransferToken,
                                  self.pendingImportedRAWURL==preserved.url,
                                  !self.photoTransferActive else {return}
                            self.openPreservedRAWDirect()
                        }
                    }
                    return
                }
                if pickerAdvertisesRAW(selection) {
                    status="照片选择器没有提供可验证的 RAW 原始字节，" +
                        "不能把 JPEG/HEIC 兼容图当作 RAW 精细冲印。" +
                        "请从「文件」导入原始 DNG/RAF；当前编辑未改变。"
                    return
                }
                try loadPhoto(data)
            } catch {
                guard !Task.isCancelled && token == photoTransferToken else {
                    return
                }
                status="相册导入失败（原编辑已保留）：" + error.localizedDescription
            }
        }
    }

    /// Save first, edit later. Never run a full-resolution RAW decoder or
    /// mutate the current edit during a camera burst.
    func archiveCapturedRAWForLater(_ capture:NextLevelCapturedPhoto) throws {
        guard !busy,capture.format.contains("RAW"),
              let raw=capture.rawDNG,!raw.isEmpty else {
            throw ImageProcessingError.invalid(
                "当前拍摄不是有效 RAW，或 App 正在处理，未保存到素材库"
            )
        }
        let url=try Build134LocalRAWStorage.archiveCameraRAW(
            raw:raw,companion:capture.processed
        )
        status="RAW DNG 已保存至素材库（"+url.lastPathComponent+"）；"
            + "可继续拍摄，稍后从缩略图选择冲印。"
    }

    /// Reopen an app-owned source RAW from the catalog. The exact-source
    /// RAW contract and its memory gate are unchanged.
    func openSavedRAWFromLibrary(_ url:URL) {
        guard !busy,Build134LocalRAWStorage.isManaged(url) else {
            status="素材库原片不存在或当前正在冲印；拒绝打开"
            return
        }
        pendingImportedRAWURL=url
        rawNeedsChoice=false
        openPreservedRAWDirect()
    }

    /// RAW camera captures enter the editor through a real DNG decoder.
    /// The camera's companion JPEG is never used as the RAW source.
    /// Preserve DNG bytes before decoding; failure keeps the prior edit.
    func loadCapturedPhoto(_ capture: NextLevelCapturedPhoto) {
        guard !busy else {
            status="相机照片处理中，拒绝重复导入；原编辑保持不变"
            return
        }
        do {
            if capture.format.contains("RAW") && capture.rawDNG == nil {
                throw ImageProcessingError.invalid("RAW 模式没有返回 DNG；禁止把 JPEG 当作 RAW")
            }
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
                let rawFile = folder.appendingPathComponent(
                    "SF-RAW-" + UUID().uuidString + ".dng"
                )
                try raw.write(to: rawFile, options: .atomic)
                busy=true
                status="DNG 原片已无损保存，正在以 Apple RAW 解码传感器数据；不采用 JPEG 伴随片…"
                Task { @MainActor in
                    defer { busy=false }
                    do {
                        let decoded=try await Task.detached(priority:.userInitiated) {
                            let actual=try Build93AppleRAWImport.open(rawFile)
                            let preview=try PhotoProcessor.preview(
                                actual.image,lut:nil,strength:0
                            )
                            return (actual,preview)
                        }.value
                        try commitDecodedPhoto(
                            image:decoded.0.image,preview:decoded.1,
                            data:nil,rawURL:rawFile,rawCompatible:true,
                            dimensions:"\(decoded.0.width) × \(decoded.0.height) · 相机 DNG / Apple RAW"
                        )
                        try activateDirectRAWPrecision()
                        status="DNG 原片已保存，自动启用当前胶片／相纸的 Float64 精细冲印；" +
                            "Apple RAW 仅用于初始预览，JPEG 伴随片没有进入编辑器，也未进入光学计算。"
                    } catch {
                        pendingImportedRAWURL=rawFile
                        rawNeedsChoice=true
                        status="DNG 已无损保存，但 RAW 显影未成功：" +
                            error.localizedDescription +
                            "。原编辑保持不变，未回退 JPEG；可稍后重新选择 RAW 解码方式。"
                    }
                }
                return
            }
            try loadPhoto(capture.processed,entry:.camera)
            status="\(capture.format) 拍摄完成，照片已进入当前胶片／相纸冲印"
        } catch {
            status="相机照片处理失败：" + error.localizedDescription
        }
    }

    func loadPhotoFile(_ url: URL) {
        guard !busy else {
            status="当前正在处理，文件导入已拒绝；旧图保持不变"
            return
        }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            // Build79/09: identify real camera RAW *before* CIImage or
            // ImageIO can silently select the embedded JPEG preview.
            // This preserves original sensor container bytes and marks
            // development as unavailable until a certified RAW backend.
            if let kind=try Build79RAWSignature.probeFile(url) {
                let saved=try Build79RAWStorage.preserve(
                    url,kind:kind
                )
                // Do not clear the current edit before a chosen decoder
                // has both decoded the new RAW and produced a valid preview.
                pendingImportedRAWURL=saved.url
                rawNeedsChoice = !(kind == .raf || kind == .dng)
                status="已无损导入 ."+kind.rawValue.uppercased()
                    + " 原片，SHA256="+String(saved.sha256.prefix(12))
                    + "…，已保存至「文件」/ SpektraFilm RAW Imports。"
                    + (rawNeedsChoice
                        ? "尚未支持自动精细冲印，请选择其他解码方式；当前编辑不变。"
                        : "自动启用 RAW 原片直通精细冲印；当前编辑在解码成功后替换。")
                if !rawNeedsChoice {
                    openPreservedRAWDirect()
                }
                return
            }
            try loadPhoto(Data(contentsOf: url),entry:.file)
        } catch {
            status = "文件导入失败：" + error.localizedDescription
        }
    }

    /// Build93: selected explicitly by the RAW import dialog. The original
    /// sensor file always remains byte-for-byte in Documents; CIImage is a
    /// lazily evaluated Apple *fast compatibility* development, never source
    /// Python Float64 / X-Trans rawpy parity. Unsupported compression fails.
    /// Legacy public entry point stays byte-for-byte available to UI/tests.
    func openPreservedRAWWithApple() {
        openPreservedRAWWithApple(preferOriginalSource:false)
    }
    func openPreservedRAWWithApple(preferOriginalSource:Bool) {
        guard let url=pendingImportedRAWURL ?? capturedRAWURL else {
            status="没有可打开的原始 RAW 文件"
            return
        }
        guard !busy else { return }
        busy=true
        status="Apple RAW 兼容模式：正在验证真实传感器像素与生成预览…"
        Task { @MainActor in
            defer { busy=false }
            do {
                let decoded=try await Task.detached(priority:.userInitiated) {
                    let actual=try Build93AppleRAWImport.open(url)
                    let preview=try PhotoProcessor.preview(
                        actual.image,lut:nil,strength:0
                    )
                    return (actual,preview)
                }.value
                try commitDecodedPhoto(
                    image:decoded.0.image, preview:decoded.1,
                    data:nil, rawURL:url, rawCompatible:true,
                    dimensions:"\(decoded.0.width) × \(decoded.0.height) · RAW Apple 兼容模式"
                )
                if preferOriginalSource {
                    try activateDirectRAWPrecision()
                } else {
                    rawOriginalSourceActive=false
                }
                status=preferOriginalSource
                    ? "RAW 原片直通已自动进入 Float64 精细冲印，" +
                      "使用当前胶卷及相纸；Apple RAW 仅用于初始预览。"
                    : "已用 Apple RAW 真实解码 .\(decoded.0.format.rawValue.uppercased())；" +
                      "原片完整保存，编辑/输出走 Apple RAW 兼容模式，" +
                      "不是 Python rawpy 原版数值等价。"
            } catch {
                status="Apple RAW 兼容解码失败（原始 RAW 仍保留）：" +
                    error.localizedDescription
            }
        }
    }

    /// Build138: RAW-only default. This configures the SAME full-physical
    /// prerequisites as the explicit "精细冲印" switch, without touching
    /// optical algorithms, user-selected stocks, RAW bytes or ordinary photos.
    /// Always queue a new render even if the visible film ID has not changed.
    private func activateDirectRAWPrecision() throws {
        guard rawFastModeActive,source != nil,
              let url=capturedRAWURL,
              try Build79RAWSignature.probeFile(url) != nil else {
            throw ImageProcessingError.invalid(
                "RAW 精细冲印没有可验证原片；保持旧预览，不允许静默降级"
            )
        }
        let filmID=UserDefaults.standard.string(forKey:"compactFilmStock")
            ?? "kodak_portra_400"
        let paperID=UserDefaults.standard.string(forKey:"compactPaperStock")
            ?? "kodak_portra_endura"
        guard SpectralPhysics.supportedFilmIDs.contains(filmID),
              SpectralPhysics.supportedPaperIDs.contains(paperID) else {
            throw ImageProcessingError.invalid(
                "当前胶片或相纸材料不可用；RAW 原片保留，未启动错误的默认冲印"
            )
        }
        strength=1.0
        grainEnabled=false
        scannerFinishingEnabled=false
        spatialDIREnabled=true
        spatialDIRSourceConvolutionEnabled=true
        hanatosOriginalPrecisionEnabled=true
        originalScannerEnabled=true
        if !SpectralPhysics.isPositiveFilm(filmID) {
            originalPrintOpticsEnabled=true
        }
        scannerCAM16Enabled=false
        scannerBlackWhiteEnabled=false
        exposureReferenceEnabled=false
        rawOriginalSourceActive=true
        sourcePixelIOEnabled=true
        sourcePhysicalDirectEnabled=true
        rawFullResolutionPreview=false
        // Discard stale compatibility material nodes: source RAW uses the
        // selected film/paper directly, not a 17^3 preview cube.
        lut=nil
        densityGrainStage=nil
        spatialDIRStage=nil
        // Re-evaluate the ALREADY selected Portra 400 or other stock.
        // No manual switch away-and-back is necessary.
        queueSpectralPreview()
    }

    /// Import preview remains independent from source-original RAW pixels.
    func openPreservedRAWDirect() {
        guard let url=pendingImportedRAWURL ?? capturedRAWURL else {
            status="没有可用的 RAW 原片"
            return
        }
        guard !busy else {return}
        do {
            guard let kind=try Build79RAWSignature.probeFile(url) else {
                throw ImageProcessingError.invalid("禁止将内嵌 JPEG 冒充 RAW")
            }
            switch kind {
            case .raf: openPreservedRAW16Bit(preferOriginalSource:true)
            case .dng: openPreservedRAWWithApple(preferOriginalSource:true)
            default:
                throw ImageProcessingError.invalid(
                    "RAW 原版直通目前仅开放 RAF/DNG；其他机型等待 rawpy 数值验收"
                )
            }
        } catch {
            status="RAW 原版准备失败，原片保留：" + error.localizedDescription
        }
    }

    func enableDirectRAWSource() {
        guard !busy,rawFastModeActive,source != nil,
              let url=capturedRAWURL else {
            status="请先导入真正的 RAW 原片"
            return
        }
        do {
            guard try Build79RAWSignature.probeFile(url) != nil else {
                throw ImageProcessingError.invalid("RAW 原文件签名无效")
            }
            try activateDirectRAWPrecision()
            status="已自动启用 RAW 原片直通精细冲印；当前胶卷及相纸正在重新应用。" +
                "光学计算读取 RAW ACES16，失败不回退 Apple RAW 预览。"
        } catch {
            status="RAW 直通检查失败：" + error.localizedDescription
        }
    }

    /// Build94: explicit LibRaw 0.22 Fuji RAF compatibility path. The
    /// preserved RAW remains byte-identical and is never overwritten.
    /// This decodes sensor values through LibRaw's X-Trans engine to RGB8;
    /// it is not the Python source Float64/rawpy path.
    func openPreservedRAWWithLibRaw() {
        guard let url=pendingImportedRAWURL ?? capturedRAWURL else {
            status="请先选择并保存原始富士 RAF 文件"
            return
        }
        guard !busy else { return }
        busy=true
        status="LibRaw 0.22：正在解包富士 X-Trans RAW 并生成 RGB8 快速兼容图…"
        Task { @MainActor in
            defer { busy=false }
            do {
                let decoded=try await Task.detached(priority:.userInitiated) {
                    let actual=try Build94LibRawIngress.open(url)
                    let preview=try PhotoProcessor.preview(
                        actual.image,lut:nil,strength:0
                    )
                    return (actual,preview)
                }.value
                try commitDecodedPhoto(
                    image:decoded.0.image, preview:decoded.1,
                    data:nil, rawURL:url, rawCompatible:true,
                    dimensions:"\(decoded.0.width) × \(decoded.0.height) · LibRaw RGB8"
                )
                status="富士 RAF 已经由 LibRaw \(decoded.0.librawVersion) 去马赛克；" +
                    "当前为全尺寸 8-bit sRGB 兼容模式，原始 RAF 已无损保存；" +
                    "不代表 Python rawpy / Float64 数值等价。"
            } catch {
                status="LibRaw RAW 解码失败（保留原始 RAF，绝不退回 JPEG）：" +
                    error.localizedDescription
            }
        }
    }

    /// Build95: explicit high-depth LibRaw Fujifilm path. The existing
    /// Build93 Apple RAW and Build94 RGB8 routes remain unchanged.
    /// Legacy explicit high-depth RAF button remains independently selectable.
    func openPreservedRAW16Bit() {
        openPreservedRAW16Bit(preferOriginalSource:false)
    }
    func openPreservedRAW16Bit(preferOriginalSource:Bool) {
        guard let url = pendingImportedRAWURL ?? capturedRAWURL else {
            status = "请先导入并保存富士 RAF 原始文件"
            return
        }
        guard !busy else { return }
        busy = true
        status = "LibRaw 16-bit：正在解包真实 RAF、校验 UInt16 RGB 与内存预算…"
        Task { @MainActor in
            defer { busy = false }
            do {
                let decoded = try await Task.detached(priority: .userInitiated) {
                    let actual = try Build95LibRaw16Ingress.open(url)
                    let preview = try PhotoProcessor.preview(
                        actual.image, lut: nil, strength: 0
                    )
                    return (actual, preview)
                }.value
                try commitDecodedPhoto(
                    image:decoded.0.image, preview:decoded.1,
                    data:nil, rawURL:url, rawCompatible:true,
                    dimensions:"\(decoded.0.width) × \(decoded.0.height) · LibRaw RGB16"
                )
                if preferOriginalSource {
                    try activateDirectRAWPrecision()
                } else {
                    rawOriginalSourceActive=false
                }
                status = preferOriginalSource
                    ? "RAF 原片直通已自动进入 Float64 精细冲印，" +
                      "使用当前胶卷及相纸；16-bit RGB 仅用于初始预览。"
                    : "LibRaw \(decoded.0.librawVersion) 16-bit RGB 导入完成；" +
                      "输入为 16-bit sRGB 高位深兼容数据，最终 JPEG 仍为 8-bit；" +
                      "原始 RAF 不变，不代表 Python Float64 原版数值等价。"
            } catch {
                status = "LibRaw 16-bit 失败（未降级，原始 RAF 保留）：" +
                    error.localizedDescription
            }
        }
    }

    /// Build79/09: explicit user-requested TRUE Apple RAW decoder probe.
    /// Do not use an embedded JPEG as a substitute, and don't modify the
    /// source RGB preview or claim Python rawpy numerical equivalence.
    func probePreservedRAWBackend() {
        guard let url=capturedRAWURL else {
            status="请先导入真实 RAW 原片再检测原生解码器"
            return
        }
        guard !busy else { return }
        busy=true
        status="正在验证 Apple RAW 解码器是否实际能读取并渲染该文件…"
        Task { @MainActor in
            defer { busy=false }
            do {
                let result=try await Task.detached(priority:.userInitiated) {
                    try Build79NativeRAWBackend.probe(url)
                }.value
                status="Apple RAW 实测可解码 ."
                    + result.format.rawValue.uppercased()
                    + "，图像 \(result.dimensions.width)×\(result.dimensions.height)"
                    + "，1px Float32 实际渲染成功。"
                    + "但还没有与 Python rawpy/LibRaw 数值等价，"
                    + "未开启原版 RAW 显影。"
            } catch {
                status="原生 RAW 后端未通过："+error.localizedDescription
            }
        }
    }

    /// Build80/10-12: user-initiated Apple-only diagnostic processing.
    /// The preserved RAW remains unchanged and not fed to the film path.
    /// This does not claim parity with source rawpy/Lensfun/ACES.
    func probePreservedRAWDevelopment(_ options: Build80AppleRAWDevelopment.Options) {
        guard let url=capturedRAWURL else {
            status="请先导入真实 RAW 原片，再测试白平衡和镜头校正"
            return
        }
        guard !busy else { return }
        busy=true
        status="正在执行 Apple RAW 白平衡、曝光与镜头诊断（非 Python 原版显影）…"
        Task { @MainActor in
            defer { busy=false }
            do {
                let proof=try await Task.detached(priority:.userInitiated) {
                    try Build80AppleRAWDevelopment.probe(url,options:options)
                }.value
                let first=proof.measuredRGBA.prefix(4).map {
                    String(format:"%.6f",Double($0))
                }.joined(separator:",")
                let kelvin=String(format:"%.0f",Double(proof.actualTemperature))
                let tint=String(format:"%.1f",Double(proof.actualTintOffset))
                let exposure=String(format:"%.2f",Double(proof.actualExposureEV))
                let lens=proof.appleLensCorrectionEnabled ? "开" : "关"
                status=[
                    "Build80 Apple RAW .\(proof.format.rawValue.uppercased())",
                    "：真实 4×4 RGBA Float32 渲染通过。",
                    "样本 RGBA=\(first)；线性 sRGB。",
                    "Apple 色温=\(kelvin)K、Tint 偏移=\(tint)",
                    "；曝光=\(exposure) EV；Apple 镜头校正=\(lens)。",
                    "不代表 Python rawpy/ACES/Lensfun 数值等价。"
                ].joined()
            } catch {
                status = "Build80 RAW 实际解码或参数诊断失败：" + error.localizedDescription
            }
        }
    }

    /// Build81/13-15: opt-in real-file geometry/preview diagnostic.
    /// Decodes the actual original sRGB file at its original dimensions
    /// (max 2MP for bounded diagnosis), then executes the source CPU Double
    /// crop and skimage-style preview. It does NOT change the original photo,
    /// the regular preview, export or the spectral film processing path.
    func probeBuild81OriginalGeometry() {
        guard let data=originalPhotoData else {
            status="请先加载普通 sRGB 图片；RAW/未解码文件不能伪装为源像素"
            return
        }
        guard !busy else {return}
        busy=true
        status="Build81：正在检查原片 8-bit sRGB，执行 CPU Double 原版裁剪/预览…"
        Task { @MainActor in
            defer {busy=false}
            do {
                let proof=try await Task.detached(priority:.userInitiated) {
                    try OriginalSourcePixelIO.preflightExport(
                        data,maximumAllowedPixels:2_000_000
                    )
                    let frame=try OriginalSourcePixelIO.decode(
                        data,maximumAllowedPixels:2_000_000
                    )
                    let cropped=try OriginalSourcePixelIO.cropOriginal81(
                        frame,sizeX:0.6,sizeY:0.6
                    )
                    let scaled=try OriginalSourcePixelIO.previewOriginal81(
                        cropped,maxSide:600
                    )
                    return (
                        frame.width,frame.height,
                        cropped.width,cropped.height,
                        scaled.width,scaled.height,
                        scaled.rgb.first ?? 0
                    )
                }.value
                let label=[
                    "Build81 实际原片 Float64：",
                    "\(proof.0)×\(proof.1) → 源裁剪 ",
                    "\(proof.2)×\(proof.3) → 源预览 ",
                    "\(proof.4)×\(proof.5)；样本 ",
                    String(format:"%.9f",proof.6),
                    "。仅验证原版几何/预览数学，不代表 RAW、ICC 或整图等价。"
                ]
                status=label.joined()
            } catch {
                status="Build81 原版裁剪/预览诊断失败：" + error.localizedDescription
            }
        }
    }

    private func loadPhoto(
        _ data:Data,
        entry:Build111PhotoInputProfile.Entry = .album
    ) throws {
        let inspection=Build111PhotoInputProfile.inspect(data,entry:entry)
        let decoded = try PhotoProcessor.decode(data)
        let preview = try PhotoProcessor.preview(
            decoded, lut:nil, strength:0
        )
        try commitDecodedPhoto(
            image:decoded, preview:preview, data:data,
            rawURL:nil, rawCompatible:false,
            dimensions:"\(Int(decoded.extent.width)) × \(Int(decoded.extent.height))",
            inputProfile:inspection
        )
        status=inspection.summary+"。"+inspection.reason
        queueSpectralPreview()
    }

    func loadLUTFile(_ url: URL) {
        guard !busy else {
            status="当前正在处理，LUT 导入未开始；原编辑保持不变"
            return
        }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let importedLUT = try FilmLUT.read(text: text,
                filename: url.deletingPathExtension().lastPathComponent)
            // The old implementation changed six active processing toggles
            // before proving the imported LUT could preview correctly.
            // Treat the import as a transaction: all previous values recover
            // if refreshing the replacement fails.
            let previousLUT=lut
            let previousGrain=densityGrainStage
            let previousDIR=spatialDIRStage
            let previousDIREnabled=spatialDIREnabled
            let previousGrainEnabled=grainEnabled
            let previousSublayers=grainSublayersEnabled
            let previousDiscrete=grainDiscreteParticlesEnabled
            let previousMetal=grainOriginalMetalEnabled
            let previousSciPy=grainOriginalSciPyEnabled
            let previousPreview=processedPreview
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
            do {
                try refresh()
            } catch {
                invalidateSimulation()
                originalMetalPreviewVersion &+= 1
                lut=previousLUT
                densityGrainStage=previousGrain
                spatialDIRStage=previousDIR
                spatialDIREnabled=previousDIREnabled
                grainEnabled=previousGrainEnabled
                grainSublayersEnabled=previousSublayers
                grainDiscreteParticlesEnabled=previousDiscrete
                grainOriginalMetalEnabled=previousMetal
                grainOriginalSciPyEnabled=previousSciPy
                processedPreview=previousPreview
                throw error
            }
        } catch {
            status = "LUT 导入失败：" + error.localizedDescription
        }
    }

    /// Compute an internal optical LUT from measured wavelength data.
    /// Keep the proven photo importer and CoreImage renderer unchanged.
    func applyMeasuredSimulation() {
        pendingRender?.cancel()
        rawPreviewTask?.cancel()
        renderGeneration &+= 1
        simulationAwaitingCurrentSettings=hasPhoto
        if hasPhoto {
            originalMetalPreviewVersion &+= 1
            processedPreview=nil
        }
        applyMeasuredSimulation(generation: renderGeneration)
    }

    private func applyMeasuredSimulation(generation: Int) {
        guard hasPhoto else {
            status = "请先选择照片，再模拟真实胶片数据。"
            return
        }
        simulationAwaitingCurrentSettings=true
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
        activeSimulationGeneration=generation
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
            neutralPrintFiltersFromDatabase:neutralPrintFiltersFromDatabase,
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
                guard Build99InteractionRules.acceptsPreview(
                    generation:generation, current:renderGeneration
                ) else { return }
                // Atomic optical update; old grain and LUT must not be
                // mixed with a newly selected stock on a failed refresh.
                let oldLUT=lut
                let oldDensity=densityGrainStage
                let oldDIR=spatialDIRStage
                let oldStrength=strength
                let oldPreview=processedPreview
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
                // A saved recipe's explicit strength is authoritative.
                // Normal stock selection retains the original 100% default.
                if !isRecipeApplying { strength = 1.0 }
                do {
                    try refresh()
                } catch {
                    originalMetalPreviewVersion &+= 1
                    lut=oldLUT
                    densityGrainStage=oldDensity
                    spatialDIRStage=oldDIR
                    strength=oldStrength
                    processedPreview=oldPreview
                    throw error
                }
                simulationAwaitingCurrentSettings=false
                if isRecipeApplying {
                    // Exact/Metal/DIR previews finish asynchronously. Keep
                    // the undo snapshot until the real preview is available.
                    if processedPreview != nil { finishRecipePreview() }
                } else {
                    status = "已应用 \(selectionDescription)，胶片 \(String(format: "%+.2f", cameraExposure)) EV。" +
                        (requiresSpatialDIRStage
                            ? "DIR 空间抑制扩散 → 显影密度 → 光谱印相已启用。"
                            : (requiresGrainStage
                                ? "显影密度颗粒 → 原版印相链路已启用。"
                                : "原版光谱链路已启用。"))
                }
            } catch {
                guard Build99InteractionRules.acceptsPreview(
                    generation:generation, current:renderGeneration
                ) else { return }
                if isRecipeApplying {
                    rejectRecipePreview(error.localizedDescription)
                } else {
                    // A stale LUT must never export under the new stock.
                    processedPreview=nil
                    status = "当前胶片/相纸模拟失败，导出已锁定：" +
                        error.localizedDescription
                }
            }
            if activeSimulationGeneration == generation {
                activeSimulationGeneration=nil
                if !isRecipeApplying { busy=false }
            }
        }
    }

    func refresh() throws {
        rawPreviewTask?.cancel()
        guard let source else {
            status = lut == nil ? "请先导入照片。" : "LUT 已导入，请选择照片。"
            return
        }
        // Invalidate all previous in-flight previews BEFORE any guard
        // can fail. Otherwise a stale completed task might overwrite a
        // newer error or the previously restored editing session.
        originalMetalPreviewVersion &+= 1
        let revision = originalMetalPreviewVersion
        do {
            try requireConfiguredGrain()
            if grainOriginalMetalEnabled && grainEnabled && grainAmount > 0 {
                guard grainSublayersEnabled, densityGrainStage != nil,
                      lut != nil else {
                    throw ImageProcessingError.invalid(
                        "原版 Metal 显影缺少实测亚层或光谱输入，禁止降级为快速 LUT"
                    )
                }
            }
        } catch {
            processedPreview=nil
            throw error
        }
        if sourcePixelIOEnabled {
            // A refused precision request must never leave an earlier,
            // potentially half-quantized preview looking like its result.
            processedPreview=nil
            if rawOriginalSourceActive {
                guard sourcePhysicalDirectEnabled,
                      let rawURL=capturedRAWURL else {
                    throw ImageProcessingError.invalid(
                        "RAW 原片直通只支持全光学；不能回退到 8-bit DIR"
                    )
                }
                let physical=try sourcePhysicalParameters()
                let activeRAWGeneration=activeSimulationGeneration
                let fullSourcePreview=rawFullResolutionPreview
                let selectedCrop=rawCropSelection
                status=(fullSourcePreview
                    ? "RAW 完整精细预览：原始 ACES16 → Float64"
                    : "RAW 快速预览：ACES16 1280px → Float64") +
                    (selectedCrop != nil ? "（冲印前已裁切）" : "") +
                    " 光学计算中…"
                rawPreviewTask = Task.detached(priority:.userInitiated) {
                    do {
                        let rendered=try P1OriginalRawACESIngress.withExclusiveRAWWork(operation:fullSourcePreview ? "full_preview" : "quick_preview") {
                          try autoreleasepool { () throws -> (UIImage,Int,Int,Int,Int) in
                            let frame:OriginalSourcePixelIO.Frame
                            let rawWidth:Int,rawHeight:Int
                            if fullSourcePreview {
                                frame=try P1OriginalRawACESIngress.developSourceCandidate(
                                    rawURL,opticalSettings:physical,crop:selectedCrop,
                                    retainDecodedSource:true
                                )
                                rawWidth=selectedCrop?.sourceWidth ?? frame.width
                                rawHeight=selectedCrop?.sourceHeight ?? frame.height
                            } else {
                                let preview=try P1OriginalRawACESIngress.developPreviewWithGeometry(
                                    rawURL,opticalSettings:physical,
                                    maxLongEdge:1280,crop:selectedCrop
                                )
                                frame=preview.frame
                                rawWidth=preview.sourceWidth
                                rawHeight=preview.sourceHeight
                            }
                            // Build141: source and crop geometry match the
                            // decoder orientation; final UIImage is display only.
                            let image=try OriginalSourcePixelIO.displayPreviewImage(
                                frame,maxEdge:1600
                            )
                            return (UIImage(cgImage:image),frame.width,frame.height,
                                    rawWidth,rawHeight)
                          }
                        }
                        try Task.checkCancellation()
                        await MainActor.run {
                            guard !Task.isCancelled, revision==self.originalMetalPreviewVersion else {return}
                            self.processedPreview=rendered.0
                            if selectedCrop==nil {
                                self.rawCropReferencePreview=rendered.0
                                self.rawCropReferenceWidth=rendered.3
                                self.rawCropReferenceHeight=rendered.4
                            }
                            if let generation=activeRAWGeneration,
                               generation==self.activeSimulationGeneration {
                                self.simulationAwaitingCurrentSettings=false
                                self.activeSimulationGeneration=nil
                                self.busy=false
                            }
                            self.status=(fullSourcePreview
                                ? "完整精细预览"
                                : "快速预览（空间效果与原尺寸结果可能不同）") +
                                "｜光学计算 \(rendered.1)×\(rendered.2)｜" +
                                (selectedCrop != nil
                                    ? "仅裁切区域进入原版光学计算｜"
                                    : "原图区域进入光学计算｜") +
                                "导出仍为 Float64 精细冲印｜rawpy 实图未认证"
                            self.finishRecipePreview()
                        }
                    } catch {
                        await MainActor.run {
                            guard !Task.isCancelled, revision==self.originalMetalPreviewVersion else {return}
                            self.processedPreview=nil
                            if let generation=activeRAWGeneration,
                               generation==self.activeSimulationGeneration {
                                // Keep the selected material pending so a
                                // failed RAW render cannot export an old frame.
                                self.activeSimulationGeneration=nil
                                self.busy=false
                            }
                            self.status="RAW 原片精细冲印失败（禁止降级）：" +
                                error.localizedDescription
                        }
                    }
                }
                return
            }
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
                        self.finishRecipePreview()
                    }
                } catch {
                    await MainActor.run {
                        guard revision==self.originalMetalPreviewVersion else {return}
                        if self.isRecipeApplying {
                            self.rejectRecipePreview(error.localizedDescription)
                        } else {
                            self.processedPreview=nil
                            self.status = (physical == nil
                                ? "原版像素直连失败（禁止回退）："
                                : "逐像素全光学失败（禁止回退）：") +
                                error.localizedDescription
                        }
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
                        self.finishRecipePreview()
                    }
                } catch {
                    await MainActor.run {
                        guard revision == self.originalMetalPreviewVersion
                        else { return }
                        if self.isRecipeApplying {
                            self.rejectRecipePreview(error.localizedDescription)
                        } else {
                            self.processedPreview=nil
                            self.status = "原版 Metal 显影失败（未退回快速模式）：" +
                                error.localizedDescription
                        }
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
                        self.finishRecipePreview()
                    }
                } catch {
                    await MainActor.run {
                        guard revision==self.originalMetalPreviewVersion else {return}
                        if self.isRecipeApplying {
                            self.rejectRecipePreview(error.localizedDescription)
                        } else {
                            self.processedPreview=nil
                            self.status="原版空间 DIR 失败（没有降级 CI 近似）：" +
                                error.localizedDescription
                        }
                    }
                }
            }
            return
        }
        do {
            processedPreview = try PhotoProcessor.preview(
                source, lut: lut, strength: strength,
                spatial: spatialSettings,
                grain: grainSettings, scanner: scannerFinishSettings,
                dirStage: spatialDIRStage,
                dirSettings: spatialDIRSettings
            )
        } catch {
            // Fail closed even on the synchronous mobile route. Do not
            // leave yesterday's preview visible after changing sliders.
            processedPreview=nil
            throw error
        }
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
                // v1.8.46: actual source full-physical image production
                // sequence, with controlled scanner XYZ glare, is probed
                // on-device separately from 8/8 and the 1-worker formula.
                do {
                    let realFrame = try OriginalSourceScannerGlareProductionDiagnostic.evaluate()
                    checks.append("附录【v1.8.46 生产扫描 XYZ 眩光｜实机受控图像分段对照】\n" + realFrame)
                } catch {
                    checks.append("附录【v1.8.46 生产扫描 XYZ 眩光｜失败／未认证】\n" + error.localizedDescription)
                }
                // v1.8.49: actual iPhone production 3x3 source grain
                // into spectral optical paper/scanner. Independently
                // tracked as an appendix, NOT a ninth 8/8 Metal certificate.
                do {
                    let production = try OriginalSourceGrainProductionDiagnostic.evaluate()
                    checks.append(
                        "附录【Build74 真机源三亚层颗粒→原版相纸 RGB 生产链｜同链路自检通过】\n"
                        + production
                    )
                } catch {
                    checks.append(
                        "附录【Build74 真机源三亚层颗粒→原版相纸 RGB 生产链｜失败／未认证】\n"
                        + error.localizedDescription
                    )
                }
                // Build86: real production dynamic DIR + two original
                // grain paths, including a continuous Numba worker state.
                // Diagnostic appendix only, never counted in 8/8 Metal.
                do {
                    let bulk = try Build86BulkProductionPathDiagnostic.evaluate()
                    checks.append(
                        "附录【Build86 胶片 DIR／SciPy／Numba 真实冲印链自检】\n" + bulk
                    )
                } catch {
                    checks.append(
                        "附录【Build86 胶片 DIR／SciPy／Numba 自检失败／未认证】\n" +
                        error.localizedDescription
                    )
                }
                // Build87: true calibrated source film/print black/white
                // topology, separately scoped from the existing 8/8 Metal.
                do {
                    let printScan = try Build87PrintScanProductionDiagnostic.evaluate()
                    checks.append(
                        "附录【Build87 负片冲印及正片直扫黑白参考校准｜正式链路自检】\n" +
                        printScan
                    )
                } catch {
                    checks.append(
                        "附录【Build87 负片／正片原版校准｜未通过／未认证】\n" +
                        error.localizedDescription
                    )
                }
                // Build88 separate source scanner append-only diagnosis:
                // original reference→XYZ glare→ACES→FIR/YVV→CCTF,
                // including positive-film bypass and true linear RGB.
                // Never count in the existing 8/8 Metal certification.
                do {
                    let scan = try Build88ScannerCombinedProductionDiagnostic.evaluate()
                    checks.append(
                        "附录【Build88 原版扫描 XYZ／黑白参考／眩光／锐化｜生产链自检】\n" +
                        scan
                    )
                } catch {
                    checks.append(
                        "附录【Build88 原版扫描生产链｜失败／未认证】\n" +
                        error.localizedDescription
                    )
                }
                // Build89 native true per-pixel original CAM16-UCS:
                // source default 64x720 Cmax / 18 bisections, not 33³.
                // Production append-only diagnostic does NOT add to 8/8.
                do {
                    let gamut=try Build89OutputGamutProductionDiagnostic.evaluate()
                    checks.append(
                        "附录【Build89 原版 CAM16-UCS 全链路／输出线性及 CCTF｜生产自检】\n" +
                        gamut
                    )
                } catch {
                    checks.append(
                        "附录【Build89 原版逐像素色域输出｜失败／未认证】\n" +
                        error.localizedDescription
                    )
                }
                // Build91 (#42–44) app dry-run source memory matrix.
                // Never allocate a 13MP image for a diagnostic appendix.
                // The Metal cache COUNTER is not new GPU source parity.
                do {
                    let memory=try Build91MemoryProductionDiagnostic.evaluate()
                    checks.append(
                        "附录【Build91 CPU Double FFT／原版内存安全预算与 Metal 缓存｜预检未做真机大图】\n" +
                        memory
                    )
                } catch {
                    checks.append(
                        "附录【Build91 原版 FFT 内存／GPU 缓存检查｜失败／未认证】\n" +
                        error.localizedDescription
                    )
                }
                // Build92 #45 source tapes: bundled 4 real-Python whole
                // optical images and seeded Numba grain source stages,
                // evaluated by the production Swift pixel pipeline only
                // on the user's device. Never count as a 9th 8/8 item.
                // The result distinguishes iOS16.5.1 from other iOS.
                do {
                    let tape=try Build92DeviceSourceStageDiagnostic.evaluate()
                    checks.append(
                        "附录【Build92 Python 12 阶段整图数值对照｜本机执行，不计入 8/8】\n" +
                        tape
                    )
                } catch {
                    checks.append(
                        "附录【Build92 Python→Swift 原版整图对照｜失败／未认证】\n" +
                        error.localizedDescription
                    )
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

    func prepareExport(resolution: ExportResolutionMode,
                       tiff16: Bool = false) throws
        -> SafeExportResolution.Plan {
        // Build134: the editor may retain completed Core Image preview
        // kernels even though original RAW export uses the independent
        // source Float64 renderer. Discard only unowned CI intermediate
        // caches BEFORE the existing guarded headroom preflight.
        if rawOriginalSourceActive && sourcePhysicalDirectEnabled {
            P1OriginalRawACESIngress.clearPreviewInputCache()
            PhotoProcessor.clearTransientCaches()
        }
        guard let src = source else {
            throw ImageProcessingError.invalid("请先导入照片")
        }
        let bounds=src.extent.integral
        // Native LibRaw geometry (captured from the uncropped source render).
        // Output-only resolution choices do not affect these optical pixels.
        let inputCrop=rawOriginalSourceActive ? rawCropSelection : nil
        try inputCrop?.validate()
        let opticalWidth=inputCrop?.width ?? Int(bounds.width)
        let opticalHeight=inputCrop?.height ?? Int(bounds.height)
        guard Build99InteractionRules.canExport(
            pendingSelectedMaterial:simulationAwaitingCurrentSettings
        ) else {
            throw ImageProcessingError.invalid(
                "当前胶片/相纸仍在模拟或已失败；禁止使用旧 LUT 导出"
            )
        }
        if tiff16 && sourcePixelIOEnabled &&
            !sourcePhysicalDirectEnabled {
            throw ImageProcessingError.invalid(
                "普通像素 DIR 模式尚未接入源 Float64 TIFF16；" +
                "可明确切换逐像素全光学以使用 Build90 原版 TIFF16。" +
                "不允许静默转入 CI 或 8-bit JPEG。"
            )
        }
        if sourcePixelIOEnabled {
            // Before opening the confirmation sheet, validate the ORIGINAL
            // ImageIO dimensions and selected source algorithm budget.
            // Direct DIR-only still requires its unchanged original-size
            // contract. The full-physical route separately accepts explicit
            // safe/economy plans; all original optical stages are retained.
            guard resolution == .original || sourcePhysicalDirectEnabled else {
                throw ImageProcessingError.invalid(
                    "8-bit 原版 DIR 像素直连仅支持原尺寸；缩图请选逐像素全光学"
                )
            }
            if rawOriginalSourceActive {
                guard sourcePhysicalDirectEnabled,capturedRAWURL != nil,
                      resolution.permitsRAWFullOpticalExport else {
                    throw ImageProcessingError.invalid(
                        "RAW 精细冲印可选原尺寸或固定 720/800/900/1000/1200 万；" +
                        "禁止自动安全档静默降采样或兼容回退"
                    )
                }
                let settings=try sourcePhysicalParameters()
                try OriginalSourcePhysicalImage.validateMemoryBudget(
                    width:opticalWidth,height:opticalHeight,
                    parameters:settings
                )
            } else {
                let (data, _) = try validateSourcePixelIO()
                if sourcePhysicalDirectEnabled {
                    _ = try sourcePhysicalParameters()
                }
                try OriginalSourcePixelIO.preflightExport(
                    data, maximumAllowedPixels:
                        sourcePhysicalDirectEnabled && resolution == .original
                        ? OriginalSourcePhysicalImage.maximumPixels : 16_000_000
                )
            }
        }
        // Build140/141: one accounting envelope for ALL selected
        // source optics, evaluated over the CONFIRMED cropped RAW pixels.
        // The RAW export case uses precisely the runtime film/paper/film grain,
        // scanner, glare, camera, halation, output gamut and FFT settings.
        // No legacy fixed 224 B/px grain adder, no lowered Jetsam threshold.
        let rawPhysicalSettings:OriginalSourcePhysicalImage.Parameters? =
            rawOriginalSourceActive && sourcePixelIOEnabled &&
            sourcePhysicalDirectEnabled
            ? try sourcePhysicalParameters() : nil
        let rawOpticalPeakBPP:UInt64?=rawPhysicalSettings.map { settings in
            let footprint=OriginalSourcePhysicalImage.memoryEnvelope(
                width:opticalWidth,height:opticalHeight,
                parameters:settings
            )
            // Native LibRaw still decodes the ORIGINAL full sensor before
            // a packed ACES16 crop. Reserve this immutable RGB16 buffer
            // alongside the smaller optical frame: no false "free crop".
            let decoderOverhead:UInt64=inputCrop == nil ? 0 :
                (UInt64(inputCrop!.sourceWidth) *
                 UInt64(inputCrop!.sourceHeight) * 6 +
                 UInt64(opticalWidth*opticalHeight)-1) /
                 UInt64(opticalWidth*opticalHeight)
            return OriginalSourcePhysicalImage.estimatedPeakBytesPerPixel +
                footprint.additionalBytesPerPixel + decoderOverhead
        }
        let plan = try SafeExportResolution.capture(
            width: opticalWidth, height: opticalHeight,
            mode: resolution,
            estimatedBytesPerPixel:
                rawOpticalPeakBPP ??
                (sourcePixelIOEnabled && sourcePhysicalDirectEnabled
                ? (OriginalSourcePhysicalImage.estimatedPeakBytesPerPixel +
                   (tiff16 ? 24 : 0) +
                   (sourceScannerOpticalEnabled
                    ? OriginalSourcePhysicalImage.scannerFinishExtraBytesPerPixel
                    : 0) +
                   (sourceScannerGlareEnabled && sourceScannerGlarePercent>0
                    ? OriginalSourcePhysicalImage.scannerGlareExtraBytesPerPixel
                    : 0) +
                   (sourcePhysicalGrainEnabled
                    ? OriginalSourcePhysicalGrain.extraBytesPerPixel +
                      (sourceGrainUseUnseededParallel
                        ? OriginalSourcePhysicalGrain.unseededParallelExtraBytesPerPixel : 0)
                    : 0) +
                   (sourceCameraPreFilmEnabled && sourceCameraLensBlurUM > 0
                    ? OriginalSourcePhysicalImage.cameraLensExtraBytesPerPixel : 0) +
                   (sourcePhysicalHalationRequested
                    ? OriginalSourcePhysicalImage.filmHalationExtraBytesPerPixel : 0) +
                   (printSourceDiffusionEnabled
                    ? OriginalSourcePhysicalImage.printDiffusionExtraBytesPerPixel : 0))
                : (tiff16
                   ? Build96TIFF16Writer.estimatedBytesPerPixel
                   : SafeExportResolution.estimatedBytesPerPixel)),
            fullSourceProcessing:rawOriginalSourceActive &&
                sourcePixelIOEnabled && sourcePhysicalDirectEnabled
        )
        if let rawPhysicalSettings {
            // RAW develops its selected original-RAW crop, even if final
            // JPEG/TIFF16 output is explicitly downsampled further.
            try OriginalSourcePhysicalImage.validateMemoryBudget(
                width:opticalWidth,height:opticalHeight,
                parameters:rawPhysicalSettings
            )
        } else if sourcePixelIOEnabled && sourcePhysicalDirectEnabled {
            // Ordinary non-RAW full-physical handling remains unchanged.
            try OriginalSourcePhysicalImage.validateMemoryBudget(
                width:rawOriginalSourceActive ? Int(bounds.width) : plan.dimensions.width,
                height:rawOriginalSourceActive ? Int(bounds.height) : plan.dimensions.height,
                additionalBytesPerPixel:
                    (tiff16 ? 24 : 0) +
                    (sourceScannerOpticalEnabled
                        ? OriginalSourcePhysicalImage.scannerFinishExtraBytesPerPixel : 0) +
                    (sourceScannerGlareEnabled && sourceScannerGlarePercent>0
                        ? OriginalSourcePhysicalImage.scannerGlareExtraBytesPerPixel : 0) +
                    (sourcePhysicalGrainEnabled
                        ? OriginalSourcePhysicalGrain.extraBytesPerPixel +
                          (sourceGrainUseUnseededParallel
                            ? OriginalSourcePhysicalGrain.unseededParallelExtraBytesPerPixel : 0) : 0) +
                    (sourceCameraPreFilmEnabled && sourceCameraLensBlurUM > 0
                        ? OriginalSourcePhysicalImage.cameraLensExtraBytesPerPixel : 0) +
                    (sourcePhysicalHalationRequested
                        ? OriginalSourcePhysicalImage.filmHalationExtraBytesPerPixel : 0) +
                    (printSourceDiffusionEnabled
                        ? OriginalSourcePhysicalImage.printDiffusionExtraBytesPerPixel : 0)
            )
        }
        if tiff16 && !sourcePixelIOEnabled {
            // Compatibility CI TIFF16 has a separate renderer/budget.
            try Build96TIFF16Writer.validateBudget(
                width: plan.dimensions.width,height: plan.dimensions.height
            )
        }
        // Include original JPEG in the same early admission; the source
        // photo may be larger than a stable iPhone process can render.
        try SafeExportResolution.validateBeforeRender(plan)
        return plan
    }

    func exportJPEG(
        resolution: ExportResolutionMode = .original,
        confirmedPlan: SafeExportResolution.Plan? = nil
    ) async throws -> URL {
        guard let imageSource = source else {
            throw ImageProcessingError.invalid("请先导入照片")
        }
        guard Build99InteractionRules.canExport(
            pendingSelectedMaterial:simulationAwaitingCurrentSettings
        ) else {
            throw ImageProcessingError.invalid("胶片/相纸尚未匹配当前选项，无法导出旧效果")
        }
        try requireConfiguredGrain()
        // Recheck live memory before the background work begins. Original
        // source Float64 exports are protected here as well as CI JPEG.
        if let confirmedPlan {
            try SafeExportResolution.validateBeforeRender(confirmedPlan)
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
            if rawOriginalSourceActive {
                let crop=rawCropSelection
                guard sourcePhysicalDirectEnabled,
                      resolution.permitsRAWFullOpticalExport,
                      let rawURL=capturedRAWURL,
                      let plan=confirmedPlan,
                      plan.mode==resolution,
                      plan.sourceWidth==(crop?.width ?? Int(imageSource.extent.integral.width)),
                      plan.sourceHeight==(crop?.height ?? Int(imageSource.extent.integral.height)) else {
                    throw ImageProcessingError.invalid(
                        "RAW 精细 JPEG 必须选择当前原片、原尺寸或固定像素档位；禁止兼容回退"
                    )
                }
                try SafeExportResolution.validateBeforeRender(plan)
                let optical=try sourcePhysicalParameters()
                rawPreviewTask?.cancel()
                let url=try await Task.detached(priority:.userInitiated) {
                    try P1OriginalRawACESIngress.withExclusiveRAWWork(operation:"jpeg_export") {
                      try autoreleasepool { () throws -> URL in
                        var result=try P1OriginalRawACESIngress.developSourceCandidate(
                            rawURL,opticalSettings:optical,crop:crop
                        )
                        // Full source RAW optics are finished before
                        // user-requested output-only Double downsampling.
                        let output=try Build136RAWOutputResize.resample(
                            width:result.width,height:result.height,rgb:result.rgb,
                            targetWidth:plan.dimensions.width,
                            targetHeight:plan.dimensions.height
                        )
                        // The source Float64 frame is no longer needed after
                        // output-only resampling. Release its RGB storage
                        // before native packing and exact ICC verification.
                        // No-resize output keeps its own Array COW ownership.
                        result.rgb.removeAll(keepingCapacity:false)
                        return try Build90NativeOutputWriter.write(
                            width:output.width,height:output.height,rgb:output.rgb,
                            options:.init(
                                format:.jpeg,bitDepth:8,outputSpace:"sRGB",
                                cctfEncoded:optical.sourceOutputCCTFEncoding
                            )
                        )
                      }
                    }
                }.value
                status=(crop != nil
                    ? "RAW ACES16 先裁切 → Float64 全裁切区冲印 → "
                    : "RAW ACES16 全图 → Float64 冲印 → ") +
                    "\(plan.dimensions.width)×\(plan.dimensions.height) JPEG 已输出；" +
                    "原片 RAW 不变，rawpy 数值尚未认证"
                return url
            }
            let (data,stage)=try validateSourcePixelIO()
            guard sourcePhysicalDirectEnabled || resolution == .original else {
                throw ImageProcessingError.invalid(
                    "8-bit 原版 DIR 像素直连不支持缩图，禁止切换快速模式"
                )
            }
            let settings=spatialDIRSettings
            let physical=sourcePhysicalDirectEnabled
                ? try sourcePhysicalParameters() : nil
            var resizedTo:(width:Int,height:Int)? = nil
            if physical != nil {
                // Reduced processing is an explicit UI-confirmed choice.
                // Never recompute geometry in the detached render task.
                guard let plan=confirmedPlan,
                      plan.mode==resolution,
                      plan.sourceWidth==Int(imageSource.extent.integral.width),
                      plan.sourceHeight==Int(imageSource.extent.integral.height) else {
                    throw ImageProcessingError.invalid(
                        "逐像素全光学：导出确认尺寸失效，请重新选择分辨率"
                    )
                }
                try SafeExportResolution.validateBeforeRender(plan)
                if resolution != .original {
                    resizedTo=(plan.dimensions.width,plan.dimensions.height)
                }
            }
            let url=try await Task.detached(priority:.userInitiated) {
                if let physical {
                    return try OriginalSourcePixelIO.exportPhysicalJPEG(
                        data,parameters:physical,resizedTo:resizedTo
                    )
                }
                return try OriginalSourcePixelIO.exportJPEG(
                    data,stage:stage,settings:settings
                )
            }.value
            status=physical == nil
                ? "原版像素直连：原尺寸 JPEG 已输出（8-bit，不含 CI 中间量化）"
                : "逐像素原版全光学：\(resizedTo?.width ?? Int(imageSource.extent.integral.width)) × \(resizedTo?.height ?? Int(imageSource.extent.integral.height)) JPEG 已输出，原始光学算法未降级"
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

    /// Build128: compatibility CI remains Build96 TIFF16; source-exact
    /// physical mode now invokes the EXISTING Build90 original Float64
    /// TIFF16 writer. No 8-bit intermediary or CI fallback.
    func exportTIFF16(
        resolution: ExportResolutionMode,
        confirmedPlan: SafeExportResolution.Plan
    ) async throws -> URL {
        guard let imageSource = source else {
            throw ImageProcessingError.invalid("请先导入照片")
        }
        guard Build99InteractionRules.canExport(
            pendingSelectedMaterial:simulationAwaitingCurrentSettings
        ) else {
            throw ImageProcessingError.invalid("胶片/相纸尚未匹配当前选项，无法导出旧效果")
        }
        try requireConfiguredGrain()
        if sourcePixelIOEnabled {
            guard sourcePhysicalDirectEnabled else {
                throw ImageProcessingError.invalid(
                    "普通 DIR 直连不能冒充全光学 TIFF16；已放弃，无兼容 CI 回退"
                )
            }
            if rawOriginalSourceActive {
                let crop=rawCropSelection
                guard resolution.permitsRAWFullOpticalExport,
                      let rawURL=capturedRAWURL,
                      confirmedPlan.mode==resolution,
                      confirmedPlan.sourceWidth==(crop?.width ?? Int(imageSource.extent.integral.width)),
                      confirmedPlan.sourceHeight==(crop?.height ?? Int(imageSource.extent.integral.height)) else {
                    throw ImageProcessingError.invalid(
                        "RAW TIFF16 仅支持已确认原尺寸或固定像素档位；禁止静默缩图"
                    )
                }
                try SafeExportResolution.validateBeforeRender(confirmedPlan)
                let optical=try sourcePhysicalParameters()
                rawPreviewTask?.cancel()
                let url=try await Task.detached(priority:.userInitiated) {
                    try P1OriginalRawACESIngress.withExclusiveRAWWork(operation:"tiff16_export") {
                      try autoreleasepool { () throws -> URL in
                        var result=try P1OriginalRawACESIngress.developSourceCandidate(
                            rawURL,opticalSettings:optical,crop:crop
                        )
                        let output=try Build136RAWOutputResize.resample(
                            width:result.width,height:result.height,rgb:result.rgb,
                            targetWidth:confirmedPlan.dimensions.width,
                            targetHeight:confirmedPlan.dimensions.height
                        )
                        // The source Float64 frame is no longer needed after
                        // output-only resampling. Release its RGB storage
                        // before native packing and exact ICC verification.
                        // No-resize output keeps its own Array COW ownership.
                        result.rgb.removeAll(keepingCapacity:false)
                        return try Build90NativeOutputWriter.write(
                            width:output.width,height:output.height,rgb:output.rgb,
                            options:.init(
                                format:.tiff,bitDepth:16,outputSpace:"sRGB",
                                cctfEncoded:optical.sourceOutputCCTFEncoding
                            )
                        )
                      }
                    }
                }.value
                status=(crop != nil
                    ? "RAW ACES16 先裁切 → Float64 全裁切区冲印 → "
                    : "RAW ACES16 全图 → Float64 冲印 → ") +
                    "\(confirmedPlan.dimensions.width)×\(confirmedPlan.dimensions.height) TIFF16；" +
                    "原片 RAW 不变，rawpy 数值尚未认证"
                return url
            }
            let (bytes, _)=try validateSourcePixelIO()
            let physical=try sourcePhysicalParameters()
            guard confirmedPlan.mode==resolution,
                  confirmedPlan.sourceWidth==Int(imageSource.extent.integral.width),
                  confirmedPlan.sourceHeight==Int(imageSource.extent.integral.height) else {
                throw ImageProcessingError.invalid(
                    "原版 TIFF16 确认尺寸与当前图像不一致，必须重新确认"
                )
            }
            try SafeExportResolution.validateBeforeRender(confirmedPlan)
            let target=confirmedPlan.dimensions
            let reduced:(width:Int,height:Int)?=resolution == .original
                ? nil : (width:target.width,height:target.height)
            let result=try await Task.detached(priority:.userInitiated) {
                try OriginalSourcePixelIO.exportPhysicalOriginalFile(
                    bytes,parameters:physical,format:.tiff,
                    bitDepth:16,outputSpace:"sRGB",
                    cctfEncoded:physical.sourceOutputCCTFEncoding,
                    resizedTo:reduced
                )
            }.value
            status="原版 Float64 全光学→16-bit TIFF 成功，"
                + "源计算未经过 JPEG8/CI 降级；ICC 与位深经 Build90 文件验证。" +
                "Apple RAW 输入仍不是 Python rawpy 数值等价。"
            return result
        }
        if grainOriginalMetalEnabled && grainEnabled && grainAmount > 0 {
            guard grainSublayersEnabled, densityGrainStage != nil,
                  lut != nil else {
                throw ImageProcessingError.invalid(
                    "TIFF16 原版颗粒显影缺少实测亚层，禁止降级 LUT"
                )
            }
        }
        guard confirmedPlan.mode == resolution,
              confirmedPlan.sourceWidth == Int(imageSource.extent.integral.width),
              confirmedPlan.sourceHeight == Int(imageSource.extent.integral.height)
        else {
            throw ImageProcessingError.invalid(
                "TIFF16 已确认的输出尺寸与当前照片不匹配"
            )
        }
        try SafeExportResolution.validateBeforeRender(confirmedPlan)
        try Build96TIFF16Writer.validateBudget(
            width: confirmedPlan.dimensions.width,
            height: confirmedPlan.dimensions.height
        )
        let currentLUT = lut
        let currentStrength = strength
        let currentSpatial = spatialSettings
        let currentGrain = grainSettings
        let currentScanner = scannerFinishSettings
        let currentDIRStage = spatialDIRStage
        let currentDIRSettings = spatialDIRSettings
        let result = try await Task.detached(priority: .userInitiated) {
            try PhotoProcessor.exportTIFF16(
                imageSource, lut: currentLUT, strength: currentStrength,
                spatial: currentSpatial, grain: currentGrain,
                scanner: currentScanner,
                dirStage: currentDIRStage,
                dirSettings: currentDIRSettings,
                resolution: resolution,
                confirmedPlan: confirmedPlan
            )
        }.value
        status = "TIFF16 RGB16 · \(result.width)×\(result.height) 已验证实际位深并生成文件"
        return result.url
    }

    /// Build133: expose the currently chosen true-original settings to the
    /// diagnostic only; no independent approximate settings are fabricated.
    func rawMemoryDiagnosticParameters() throws
        -> OriginalSourcePhysicalImage.Parameters {
        try sourcePhysicalParameters()
    }

    /// Export a truthful MACHINE-READABLE checklist. Runtime metadata is
    /// observed here; all manual true-device/source parity gates remain
    /// not_run until verifiable signed evidence is supplied.
    func exportBuild100Readiness() throws -> URL {
        let bundle=Bundle.main
        let version=bundle.object(
            forInfoDictionaryKey:"CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build=bundle.object(
            forInfoDictionaryKey:"CFBundleVersion"
        ) as? String ?? "unknown"
        let report=Build100Readiness.capture(
            version:version, build:build, date:Date(),
            platform:UIDevice.current.model,
            osVersion:UIDevice.current.systemVersion,
            sourceLoaded:hasPhoto,
            processedPreviewAvailable:processedPreview != nil,
            selectedMaterialPending:simulationAwaitingCurrentSettings,
            runtimeDiagnosticReportExists:hardwareDiagnosticReport != nil,
            sourcePixelMode:sourcePixelIOEnabled,
            fullPhysicalMode:sourcePhysicalDirectEnabled &&
                             sourcePixelIOEnabled
        )
        guard let documents=FileManager.default.urls(
            for:.documentDirectory,in:.userDomainMask
        ).first else {
            throw ImageProcessingError.invalid(
                "无法定位本机文档目录，验收清单未写入"
            )
        }
        return try Build100Readiness.write(report,documents:documents)
    }

}

struct ContentView: View {
    @StateObject private var model = PhotoEditorModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var cameraPresented = false
    @State private var recipeLibraryPresented = false
    @State private var rawManagerPresented = false
    @State private var activeSheet: ImportSheet?
    @State private var message: String?
    @State private var pendingExport: ExportProposal?
    // A generated file is owned by this share operation until the system
    // activity sheet closes; source RAW from Documents is NEVER deleted.
    @State private var temporarySharedExport: URL?
    /// Sheet dismissal completion, not an arbitrary 350ms sleep, decides
    /// when a newly captured report/folder is safe to share.
    @State private var diagnosticDismissPending=false
    @State private var diagnosticPendingShare: URL?
    /// Build107: one feedback share with the matched human LOG and JSON.
    @State private var diagnosticPendingFeedback: (log:URL,json:URL)?

    private struct ExportProposal: Identifiable {
        let id = UUID()
        let toPhotos: Bool
        let tiff16: Bool
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
        case shareFeedback(URL,URL)

        var id: String {
            switch self {
            case .photo: return "photo-file"
            case .lut: return "lut-file"
            case .stocks: return "stock-catalog"
            case .share(let url): return "share-" + url.absoluteString
            case .shareFeedback(let log,let json):
                return "feedback-" + log.absoluteString + json.absoluteString
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
                    guard !model.busy else { return }
                    model.status = "请选择照片文件；已有编辑在新照片成功打开前保留"
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
                onManageLocalRAW: {
                    guard !model.busy else { return }
                    rawManagerPresented = true
                },
                onOpenLUT: {
                    guard !model.busy else { return }
                    model.status = "请选择 .cube 文件"
                    activeSheet = .lut
                },
                onOpenCatalog: {
                    activeSheet = .stocks
                },
                onOpenRecipes: {
                    recipeLibraryPresented=true
                },
                onExport: { resolution in
                    proposeExport(saveToPhotos: false, resolution: resolution)
                },
                onExportTIFF16: { resolution in
                    proposeExport(saveToPhotos: false, resolution: resolution,
                                  tiff16: true)
                },
                onSaveToPhotos: { resolution in
                    proposeExport(saveToPhotos: true, resolution: resolution)
                },
                onRefresh: { refresh() },
                onShareOptimizationFeedback: {
                    guard !model.busy else {return}
                    diagnosticDismissPending=true
                    do {
                        let url=try OPTDeviceFeedback.export()
                        model.status="性能反馈已保存，可直接分享 JSON"
                        enqueueDiagnosticShare(url)
                    } catch {
                        message="性能反馈导出失败："+error.localizedDescription
                    }
                },
                onShareBuild100Readiness: {
                    guard !model.busy else { return }
                    diagnosticDismissPending=true
                    do {
                        let url=try model.exportBuild100Readiness()
                        model.status="Build100 验收清单已存入文件；未测试项目保持 not_run"
                        enqueueDiagnosticShare(url)
                    } catch {
                        message="验收报告导出失败："+error.localizedDescription
                    }
                },
                onRunBuild101DeviceParity: {
                    guard !model.busy else { return }
                    diagnosticDismissPending=true
                    model.busy=true
                    model.status="正在真实运行受控 Python→Swift 原版阶段对照…"
                    let bundle=Bundle.main
                    let version=bundle.object(
                        forInfoDictionaryKey:"CFBundleShortVersionString"
                    ) as? String ?? "unknown"
                    let build=bundle.object(
                        forInfoDictionaryKey:"CFBundleVersion"
                    ) as? String ?? "unknown"
                    // Embedded at the exact tested CI git revision. Old
                    // unsigned/manual builds without a valid SHA cannot be
                    // promoted to a measured identity-bound device PASS.
                    let gitCommit=bundle.object(
                        forInfoDictionaryKey:"SFSourceCommit"
                    ) as? String ?? "missing"
                    let modelName=UIDevice.current.model
                    let os=UIDevice.current.systemVersion
                    #if targetEnvironment(simulator)
                    let hardware=false
                    #else
                    let hardware=true
                    #endif
                    let reference=bundle.url(
                        forResource:"manifest",withExtension:"json",
                        subdirectory:Build101DeviceParityEvidence.fixture
                    )
                    Task { @MainActor in
                        defer { model.busy=false }
                        let proof=await Task.detached(priority:.userInitiated) {
                            Build101DeviceParityEvidence.capture(
                                version:version,build:build,
                                binarySourceCommit:gitCommit,
                                deviceModel:modelName,osVersion:os,
                                physicalDevice:hardware,now:Date(),
                                referenceManifest:reference,
                                evaluate:{
                                    try Build92DeviceSourceStageDiagnostic.evaluate()
                                }
                            )
                        }.value
                        do {
                            guard let documents=FileManager.default.urls(
                                for:.documentDirectory,in:.userDomainMask
                            ).first else {
                                throw ImageProcessingError.invalid(
                                    "无法定位文档目录，阶段数值证据无法保存"
                                )
                            }
                            let file=try Build101DeviceParityEvidence.write(
                                proof,documents:documents
                            )
                            model.status=proof.controlledParityPassOnTargetDevice
                                ? "受控原版阶段数值对照通过；仅限本次参考样本，未完成全链认证"
                                : "受控阶段对照未达真机目标或失败；详细原因已存 JSON"
                            enqueueDiagnosticShare(file)
                        } catch {
                            model.status="Build101 阶段验证存档失败：" +
                                error.localizedDescription
                            message=error.localizedDescription
                        }
                    }
                },
                onRunBuild103Metrics: { runBuild103Metrics() },
                onRunBuild104Grain: { runBuild104Grain() },
                onRunBuild107CombinedFeedback: {
                    runBuild107CombinedFeedback()
                },
                onRunBuild108FullFrameFeedback: {
                    runBuild108FullFrameFeedback()
                },
                onRunBuild110GamutEvidence: {
                    runBuild110GamutEvidence()
                },
                onRunBuild114FourGates: { runBuild114FourGates() },
                onRunBuild115ParallelGrain: { runBuild115ParallelGrain() },
                onRunBuild116GrainMemory: { runBuild116GrainMemory() },
                onRunBuild118LargeMemory: { mp in runBuild118LargeMemory(mp) },
                onRunBuild133RAWMemory: { level in runBuild133RAWMemory(level) },
                onDiagnosticSheetDismissed: {
                    diagnosticDismissPending=false
                    if let pair=diagnosticPendingFeedback {
                        diagnosticPendingFeedback=nil
                        activeSheet = .shareFeedback(pair.log,pair.json)
                    } else if let file=diagnosticPendingShare {
                        diagnosticPendingShare=nil
                        activeSheet = .share(file)
                    }
                },
                onCaptureBuild77Evidence: {
                    guard !model.busy else { return }
                    diagnosticDismissPending=true
                    let hardwareName=UIDevice.current.model
                    let version=UIDevice.current.systemVersion
                    model.busy=true
                    model.status="正在一次性采集负片/正片/扩散三类原版阶段 Float64 证据…"
                    Task { @MainActor in
                        defer { model.busy=false }
                        do {
                            let folder=try await Task.detached(
                                priority:.userInitiated
                            ) {
                                try Build77OneShotEvidence.captureAll(
                                    deviceModel:hardwareName,
                                    systemVersion:version
                                )
                            }.value
                            model.status="真实 iPhone 阶段证据已生成。文件应用→我的 iPhone→SpektraFilm Port→" +
                                folder.lastPathComponent + "；仍未完成 Python 数值认证。"
                            enqueueDiagnosticShare(folder)
                        } catch {
                            model.status="Build77 一次性阶段采集失败："
                                + error.localizedDescription
                            message=error.localizedDescription
                        }
                    }
                }
            )
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: selectedPhoto) { item in
                model.selectFromPhotos(item)
            }
            .onChange(of: model.rawNeedsChoice) { showing in
                // Dismissing a pending RAW without choosing a decoder must
                // not bind its file to the currently displayed older photo.
                if !showing && !model.busy {
                    model.dismissPendingRAWChoice()
                }
            }
            .onChange(of: selectedFilmID) { id in
                if !model.consumeRecipeFilmSelection(id) &&
                    !model.isRecipeApplying {
                    model.queueSpectralPreview()
                }
            }
            .onChange(of: selectedPaperID) { id in
                if !model.consumeRecipePaperSelection(id) &&
                    !model.isRecipeApplying {
                    model.queueSpectralPreview()
                }
            }
            .fullScreenCover(isPresented: $cameraPresented) {
                NativeCameraScreen(
                    onCancel: { cameraPresented = false },
                    onCapture: { photo in
                        if photo.rawDNG != nil {
                            do {
                                try model.archiveCapturedRAWForLater(photo)
                                return nil
                            } catch {
                                return error.localizedDescription
                            }
                        }
                        cameraPresented = false
                        model.loadCapturedPhoto(photo)
                        return nil
                    }
                )
            }
            .sheet(isPresented:$rawManagerPresented) {
                Build134LocalRAWManagerView(model:model)
                    .presentationDetents([.medium,.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented:$recipeLibraryPresented) {
                Build126RecipeLibraryView(
                    model:model,
                    selectedFilmID:$selectedFilmID,
                    selectedPaperID:$selectedPaperID
                )
                .presentationDetents([.medium,.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $activeSheet, onDismiss: {
                if let output=temporarySharedExport {
                    _ = Build98ExportTemporaryFiles.removeAfterUse(output)
                    temporarySharedExport=nil
                }
            }) { selection in
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
                case .shareFeedback(let log,let json):
                    ActivitySheet(items: [log,json])
                }
            }
            .confirmationDialog(
                "相机 RAW 已无损保存",
                isPresented: $model.rawNeedsChoice,
                titleVisibility: .visible
            ) {
                Button("RAW 原片直通精细冲印（P1 真机测试）") {
                    model.openPreservedRAWDirect()
                }
                Button("使用 Apple RAW 兼容模式打开") {
                    model.openPreservedRAWWithApple()
                }
                Button("使用 LibRaw 0.22 富士 RAF 模式打开（8-bit）") {
                    model.openPreservedRAWWithLibRaw()
                }
                Button("使用 LibRaw 富士 RAF 16-bit 高位深兼容模式") {
                    model.openPreservedRAW16Bit()
                }
                Button("仅保留原始 RAW", role: .cancel) {
                    model.dismissPendingRAWChoice()
                }
            } message: {
                Text("Apple RAW 使用系统解码；富士 LibRaw 可选 8-bit 快速" +
                     "或 16-bit 高位深 sRGB 兼容模式。导入时保持原尺寸，" +
                     "最终 JPEG 是 8-bit，绝不宣称 Python Float64 等价。" +
                     "原片直通仅用兼容解码显示初始预览。" +
                     "精细冲印重新读取 RAW ACES16，不经过 TIFF/JPEG；" +
                     "rawpy 数值及真机尚未认证。失败不会切换为内嵌 JPEG。")
            }
            .sheet(item: $pendingExport) { proposal in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(proposal.plan.mode.title +
                                 (proposal.tiff16 ? " · TIFF 16-bit" : " · JPEG"))
                                .font(.headline)
                            Text(proposal.plan.summary)
                                .font(.system(size: 14, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text(proposal.plan.fullSourceProcessing
                                ? "RAW 精细冲印始终按 RAW 原尺寸完成 Float64 光学计算，" +
                                  "只在冲印完成后缩小成品；不会减少冲印内存峰值。" +
                                  "低内存时明确拒绝，不会降级算法或暗中缩图。"
                                : "实际内存会波动。按确认输出尺寸显影，" +
                                  "失败会提示，不会擅自缩图或切换算法。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Button {
                                pendingExport = nil
                                performExport(
                                    saveToPhotos: proposal.toPhotos,
                                    tiff16: proposal.tiff16,
                                    resolution: proposal.plan.mode,
                                    confirmedPlan: proposal.plan
                                )
                            } label: {
                                Text(proposal.toPhotos
                                    ? "确认尺寸并保存 JPEG 相册"
                                    : (proposal.tiff16
                                       ? "确认尺寸并分享真正 16-bit TIFF"
                                       : "确认尺寸并导出 JPEG"))
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
            .onReceive(NotificationCenter.default.publisher(
                for:UIApplication.didReceiveMemoryWarningNotification
            )) { _ in
                P1OriginalRawACESIngress.clearAllInputCaches(reason:"memory_warning")
                OriginalSourceDiffusion.clearPreparedPSFCache()
            }
            .onAppear {
                // Remove only our old, UUID-named outputs left by a crashed
                // prior session; never remove current/new files or RAW.
                _ = Build98ExportTemporaryFiles.removeStale()
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

    private func runBuild103Metrics() {
                    guard !model.busy else { return }
                    diagnosticDismissPending=true
                    model.busy=true
                    model.status="正在执行 28 核心阶段 Float64 数值、单线程颗粒及内存诊断…"
                    let bundle=Bundle.main
                    let ver=bundle.object(
                        forInfoDictionaryKey:"CFBundleShortVersionString"
                    ) as? String ?? "unknown"
                    let build=bundle.object(
                        forInfoDictionaryKey:"CFBundleVersion"
                    ) as? String ?? "unknown"
                    let revision=bundle.object(
                        forInfoDictionaryKey:"SFSourceCommit"
                    ) as? String ?? "missing"
                    let device=UIDevice.current.model
                    let system=UIDevice.current.systemVersion
                    #if targetEnvironment(simulator)
                    let physical=false
                    #else
                    let physical=true
                    #endif
                    let manifest=bundle.url(
                        forResource:"manifest",withExtension:"json",
                        subdirectory:Build101DeviceParityEvidence.fixture
                    )
                    Task { @MainActor in
                        defer { model.busy=false }
                        let report=await Task.detached(priority:.userInitiated) {
                            Build103VerificationEvidence.capture(
                                version:ver,build:build,commit:revision,
                                device:device,osVersion:system,
                                physicalDevice:physical,
                                manifestURL:manifest,
                                evaluate:{ observe in
                                    guard let manifest else {
                                        throw NSError(
                                            domain:"Build103",code:8,
                                            userInfo:[NSLocalizedDescriptionKey:
                                                "源清单缺失，禁止运行无参考路径"])
                                    }
                                    try SourcePhysicalImageParity.evaluate(
                                        fixtures:manifest.deletingLastPathComponent(),
                                        onBuild103StageMetric:observe
                                    )
                                },
                                rng:{
                                    try Build103VerificationEvidence.sampleSeededNumba()
                                },
                                memory:{
                                    Build103VerificationEvidence.sampleBoundedMemory(
                                        physicalBytes:ProcessInfo.processInfo.physicalMemory,
                                        available:{ UInt64(os_proc_available_memory()) }
                                    )
                                }
                            )
                        }.value
                        do {
                            guard let documents=FileManager.default.urls(
                                for:.documentDirectory,in:.userDomainMask
                            ).first else {
                                throw ImageProcessingError.invalid(
                                    "无法保存 Build103 报告：本机文档目录不可访问"
                                )
                            }
                            let file=try Build103VerificationEvidence.write(
                                report,documents:documents
                            )
                            model.status=report.controlledCoreStagesPassedOnTarget
                                ? "Build103 受控 28 核心阶段通过；默认整图、多线程及大图仍未认证"
                                : "Build103 阶段未全通过；已保留首错及实际误差 JSON"
                            enqueueDiagnosticShare(file)
                        } catch {
                            model.status="Build103 诊断保存失败："+error.localizedDescription
                            message=error.localizedDescription
                        }
                    }
    }

    private func runBuild104Grain() {
        guard !model.busy else { return }
        diagnosticDismissPending=true
        model.busy=true
        model.status="正在执行 Build104 五组原版 3×3 颗粒和单层 SciPy 真机数值验证…"
        let bundle=Bundle.main
        let ver=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString")
            as? String ?? "unknown"
        let build=bundle.object(forInfoDictionaryKey:"CFBundleVersion")
            as? String ?? "unknown"
        let revision=bundle.object(forInfoDictionaryKey:"SFSourceCommit")
            as? String ?? "missing"
        let device=UIDevice.current.model
        let system=UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        let physical=false
        #else
        let physical=true
        #endif
        let directory=bundle.url(
            forResource:"manifest",withExtension:"json",
            subdirectory:"generated-source-grain-v1.8.48"
        )?.deletingLastPathComponent()
        Task { @MainActor in
            defer { model.busy=false }
            let report=await Task.detached(priority:.userInitiated) {
                Build104DeviceGrainEvidence.capture(
                    version:ver,build:build,commit:revision,
                    device:device,osVersion:system,
                    physicalDevice:physical,directory:directory
                )
            }.value
            do {
                guard let documents=FileManager.default.urls(
                    for:.documentDirectory,in:.userDomainMask
                ).first else {
                    throw ImageProcessingError.invalid(
                        "无法保存 Build104 颗粒真机报告：文档目录不可访问")
                }
                let file=try Build104DeviceGrainEvidence.write(
                    report,documents:documents
                )
                model.status=report.passedOnTarget
                    ? "Build104 五组颗粒、20 阶段与单层双状态真机通过；整图大尺寸/并行仍未认证"
                    : "Build104 真机未完全通过；首错已保留到 JSON"
                enqueueDiagnosticShare(file)
            } catch {
                model.status="Build104 诊断保存失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }

    /// Build106/107: do not ask user to perform 4 separate exports.
    /// Both actual stage reports and both memory subsets live in one
    /// SHA-bound readable LOG and JSON, shared in a single activity sheet.
    /// Build108 opt-in full-size source optical stress, separate from the
    /// original 16MiB bounded-memory diagnostic. Never run on app launch.

    /// Build110: capture the live UI source mode BEFORE setting model.busy.
    /// Four separate real Float64 executions prove each new option actually
    /// changed output, unlike the older fixed-parameter Build108 diagnostic.
    private func runBuild110GamutEvidence() {
        guard !model.busy else {return}
        let switches=Build110SourceGamutDeviceEvidence.SwitchSnapshot(
            hasPhoto:model.hasPhoto,
            pixelIOEnabled:model.sourcePixelIOEnabled,
            fullPhysicalEnabled:model.sourcePhysicalDirectEnabled,
            originalHanatosDoubleEnabled:model.hanatosOriginalPrecisionEnabled,
            originalScannerEnabled:model.originalScannerEnabled,
            cameraRawMethod:model.sourceCameraRawMethod.rawValue,
            inputOklchToggle:model.sourcePhysicalInputOklchEnabled,
            outputCAM16Toggle:model.sourcePhysicalCAM16DefaultGamutEnabled,
            selectedPhotoInputSummary:model.photoInputSummary,
            selectedPhotoDirectCompatible:model.photoDirectInputReady,
            selectedPhotoP3ColorSyncConverted:model.photoInputConvertedFromP3
        )
        diagnosticDismissPending=true
        model.busy=true
        model.status="Build110：正在验证 Oklch / CAM16 四组原版 Float64 真机输出…"
        let bundle=Bundle.main
        let version=bundle.object(
            forInfoDictionaryKey:"CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build=bundle.object(
            forInfoDictionaryKey:"CFBundleVersion"
        ) as? String ?? "unknown"
        let sha=bundle.object(
            forInfoDictionaryKey:"SFSourceCommit"
        ) as? String ?? "missing"
        let device=UIDevice.current.model
        let osVersion=UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        let physicalDevice=false
        #else
        let physicalDevice=true
        #endif
        let manifest=bundle.url(
            forResource:"manifest",withExtension:"json",
            subdirectory:Build101DeviceParityEvidence.fixture
        )
        let grain=bundle.url(
            forResource:"manifest",withExtension:"json",
            subdirectory:"generated-source-grain-v1.8.48"
        )?.deletingLastPathComponent()
        Task { @MainActor in
            defer {model.busy=false}
            let report=await Task.detached(priority:.userInitiated) {
                Build110SourceGamutDeviceEvidence.capture(
                    version:version,build:build,commit:sha,
                    device:device,osVersion:osVersion,
                    physicalDevice:physicalDevice,
                    coreManifest:manifest,grainDirectory:grain,
                    switches:switches
                )
            }.value
            do {
                guard let documents=FileManager.default.urls(
                    for:.documentDirectory,in:.userDomainMask
                ).first else {
                    throw ImageProcessingError.invalid(
                        "Build110：无法访问文档目录"
                    )
                }
                let pair=try Build110SourceGamutDeviceEvidence.write(
                    report,documents:documents
                )
                model.status=report.status ==
                    "build110_legacy_and_four_gamut_cases_pass_ios1651"
                    ? "Build110 真机四模式 PASS；LOG＋JSON 已保存"
                    : "Build110 部分未通过：首错与四模式证据已保存"
                if diagnosticDismissPending {
                    diagnosticPendingFeedback=pair
                } else {
                    activeSheet = .shareFeedback(pair.log,pair.json)
                }
            } catch {
                model.status="Build110 报告写入失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }


    /// Build114 high-memory test is explicitly user-triggered. Write an
    /// atomic checkpoint before allocating 13MP. If iOS Jetsam terminates
    /// the process, the incomplete checkpoint remains for investigation.
    private func runBuild114FourGates() {
        guard !model.busy else {return}
        let bundle=Bundle.main
        let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString")
            as? String ?? "unknown"
        let build=bundle.object(forInfoDictionaryKey:"CFBundleVersion")
            as? String ?? "unknown"
        let sha=bundle.object(forInfoDictionaryKey:"SFSourceCommit")
            as? String ?? "missing"
        let system=UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        let physical=false
        #else
        let physical=true
        #endif
        guard let docs=FileManager.default.urls(
            for:.documentDirectory,in:.userDomainMask
        ).first else {
            model.status="Build114 无法访问本机文档目录"
            return
        }
        let folder=docs.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        let checkpoint=folder.appendingPathComponent(
            "Build114-last-13MP-run-checkpoint.txt"
        )
        do {
            try FileManager.default.createDirectory(
                at:folder,withIntermediateDirectories:true
            )
            let initial="status=INCOMPLETE_OR_NOT_RUN\napp=\(version) build=\(build) sha=\(sha)\n13MP 仍无成功报告；如果闪退或 Jetsam，此文件保留。\n"
            try initial.write(to:checkpoint,atomically:true,encoding:.utf8)
        } catch {
            model.status="Build114 无法保存 Jetsam 前检查点："+error.localizedDescription
            return
        }
        diagnosticDismissPending=true
        model.busy=true
        model.status="Build114 正在执行 13MP Float64 真机内存测试；不可视为 Python 原版整图认证…"
        Task { @MainActor in
            defer {model.busy=false}
            let report=await Task.detached(priority:.userInitiated) {
                Build108SourceOpticalDeviceStress.captureBuild114FourGates(
                    version:version,build:build,commit:sha,
                    osVersion:system,physicalDevice:physical
                )
            }.value
            do {
                let pair=try Build108SourceOpticalDeviceStress.writeBuild114FourGates(
                    report,documents:docs
                )
                let measured=report.thirteenMegapixelMemoryMeasured
                let finished="status=\(measured ? "13MP_BASELINE_MEASURED" : "FAILED_OR_INCOMPLETE")\napp=\(version) build=\(build) sha=\(sha)\n"
                try finished.write(to:checkpoint,atomically:true,encoding:.utf8)
                model.status=measured
                    ? "Build114 13MP 基础全光学真实执行完成；其他三项仍未完整认证"
                    : "Build114 13MP 未通过：失败证据及其他三项边界已保存"
                if diagnosticDismissPending {
                    diagnosticPendingFeedback=pair
                } else {
                    activeSheet = .shareFeedback(pair.log,pair.json)
                }
            } catch {
                model.status="Build114 真机报告写入失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }

    /// Build115: actual source multi-worker stochastic implementation,
    /// measured on the real device and written with the true compiled SHA.
    private func runBuild115ParallelGrain() {
        guard !model.busy else {return}
        let bundle=Bundle.main
        let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString")
            as? String ?? "unknown"
        let build=bundle.object(forInfoDictionaryKey:"CFBundleVersion")
            as? String ?? "unknown"
        let sha=bundle.object(forInfoDictionaryKey:"SFSourceCommit")
            as? String ?? "missing"
        let system=UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        let physical=false
        #else
        let physical=true
        #endif
        let grain=model.sourcePhysicalGrainEnabled
        let parallel=model.sourceGrainUseUnseededParallel
        let fast=model.sourceGrainFastStatsEnabled
        diagnosticDismissPending=true
        model.busy=true
        model.status="Build115：执行原版 Numba 多线程粒子／微结构统计及真实三亚层集成…"
        Task { @MainActor in
            defer {model.busy=false}
            let proof=await Task.detached(priority:.userInitiated) {
                Build115ParallelNumbaEvidence.capture(
                    version:version,build:build,commit:sha,
                    osVersion:system,physical:physical,
                    grain:grain,parallel:parallel,fast:fast
                )
            }.value
            do {
                guard let documents=FileManager.default.urls(
                    for:.documentDirectory,in:.userDomainMask
                ).first else {
                    throw ImageProcessingError.invalid(
                        "Build115 无法访问诊断保存目录"
                    )
                }
                let pair=try Build115ParallelNumbaEvidence.write(
                    proof,documents:documents
                )
                model.status=proof.sourceStatisticalChecksPassedOnTarget
                    ? "Build115 四线程颗粒统计及两条三亚层真机入口 PASS；并行随机逐位等价未认证"
                    : "Build115 多线程颗粒未全通过：首错已写入 LOG＋JSON"
                if diagnosticDismissPending {
                    diagnosticPendingFeedback=pair
                } else {
                    activeSheet = .shareFeedback(pair.log,pair.json)
                }
            } catch {
                model.status="Build115 保存真机随机报告失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }


    /// Build116: one-tap 1/2/3/4/6/8/10/13MP x SciPy/Numba4 grain matrix.
    /// Preserve a checkpoint before the high-memory first allocation.
    /// Every geometry uses the existing source memory gate before allocation.
    private func runBuild116GrainMemory() {
        guard !model.busy else {return}
        let bundle=Bundle.main
        let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString")
            as? String ?? "unknown"
        let build=bundle.object(forInfoDictionaryKey:"CFBundleVersion")
            as? String ?? "unknown"
        let sha=bundle.object(forInfoDictionaryKey:"SFSourceCommit")
            as? String ?? "missing"
        let system=UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        let physical=false
        #else
        let physical=true
        #endif
        guard let docs=FileManager.default.urls(
            for:.documentDirectory,in:.userDomainMask
        ).first else {
            model.status="Build116 无法访问本机文档目录"
            return
        }
        let folder=docs.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        let checkpoint=folder.appendingPathComponent(
            "Build116-last-grain-memory-checkpoint.txt"
        )
        do {
            try FileManager.default.createDirectory(
                at:folder,withIntermediateDirectories:true
            )
            let initial="status=INCOMPLETE_OR_NOT_RUN\napp=\(version) build=\(build) sha=\(sha)\n八档尺寸 × 双颗粒路线矩阵未完成；如闪退请保留本文件。\n"
            try initial.write(to:checkpoint,atomically:true,encoding:.utf8)
        } catch {
            model.status="Build116 无法保存颗粒内存测试检查点："+error.localizedDescription
            return
        }
        diagnosticDismissPending=true
        model.busy=true
        model.status="Build116：一次验证 1／2／3／4／6／8／10／13MP 的 SciPy／Numba 三亚层颗粒（逐项内存预检）…"
        Task { @MainActor in
            defer {model.busy=false}
            let proof=await Task.detached(priority:.userInitiated) {
                Build108SourceOpticalDeviceStress.captureBuild116GrainMemory(
                    version:version,build:build,commit:sha,
                    osVersion:system,physicalDevice:physical,
                    checkpointURL:checkpoint
                )
            }.value
            do {
                let pair=try Build108SourceOpticalDeviceStress.writeBuild116GrainMemory(
                    proof,documents:docs
                )
                let passed=proof.allAdmittedCasesPassed
                let finished="status=\(passed ? "GRAIN_MATRIX_ADMITTED_PASS" : "FAILED_OR_INCOMPLETE")\napp=\(version) build=\(build) sha=\(sha)\n"
                try finished.write(to:checkpoint,atomically:true,encoding:.utf8)
                model.status=passed
                    ? "Build116 矩阵完成：实测通过 \(proof.measuredCaseCount) 项、内存拒绝 \(proof.refusedCaseCount) 项；不代表被拒绝尺寸通过"
                    : "Build116 颗粒矩阵未全部完成；失败／拒绝／未执行均已记录"
                if diagnosticDismissPending {
                    diagnosticPendingFeedback=pair
                } else {
                    activeSheet = .shareFeedback(pair.log,pair.json)
                }
            } catch {
                model.status="Build116 保存真实 RSS 报告失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }


    /// Build118: one selected 8 / 10 / 13MP route pair per user action.
    private func runBuild118LargeMemory(_ megapixels:Int) {
        guard !model.busy,[8,10,13].contains(megapixels) else {return}
        let bundle=Bundle.main
        let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString")
            as? String ?? "unknown"
        let build=bundle.object(forInfoDictionaryKey:"CFBundleVersion")
            as? String ?? "unknown"
        let sha=bundle.object(forInfoDictionaryKey:"SFSourceCommit")
            as? String ?? "missing"
        let system=UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        let physical=false
        #else
        let physical=true
        #endif
        guard let docs=FileManager.default.urls(
            for:.documentDirectory,in:.userDomainMask
        ).first else {
            model.status="Build119 无法访问文件目录"
            return
        }
        let folder=docs.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        let checkpoint=folder.appendingPathComponent(
            "Build119-last-\(megapixels)MP-checkpoint.txt"
        )
        do {
            try FileManager.default.createDirectory(
                at:folder,withIntermediateDirectories:true
            )
            let initial="status=INCOMPLETE_OR_NOT_RUN\napp=\(version) build=\(build) sha=\(sha)\nselected=\(megapixels)MP\n高风险内存测试未完成；系统闪退请保留本文件。\n"
            try initial.write(to:checkpoint,atomically:true,encoding:.utf8)
        } catch {
            model.status="Build119 检查点保存失败："+error.localizedDescription
            return
        }
        diagnosticDismissPending=true
        model.busy=true
        model.status="Build119：单独执行 \(megapixels)MP SciPy／Numba Float64 真实颗粒测试…"
        Task { @MainActor in
            defer {model.busy=false}
            let proof=await Task.detached(priority:.userInitiated) {
                Build108SourceOpticalDeviceStress.captureBuild118Large(
                    megapixels:megapixels,version:version,build:build,
                    commit:sha,osVersion:system,physicalDevice:physical,
                    checkpointURL:checkpoint
                )
            }.value
            do {
                let pair=try Build108SourceOpticalDeviceStress.writeBuild118Large(
                    proof,documents:docs
                )
                let state=proof.bothRoutesRendered
                    ? "BOTH_ROUTES_RENDERED" : "REFUSED_FAILED_OR_INCOMPLETE"
                let summary="status=\(state)\napp=\(version) build=\(build) sha=\(sha)\nsize=\(megapixels)MP\npassed=\(proof.measuredCaseCount)/2 refused=\(proof.refusedCaseCount)\n"
                try summary.write(to:checkpoint,atomically:true,encoding:.utf8)
                model.status=proof.bothRoutesRendered
                    ? "Build119 \(megapixels)MP 双路线实渲染 PASS；非 Python 整图认证"
                    : "Build119 \(megapixels)MP：实渲染 \(proof.measuredCaseCount)/2，拒绝 \(proof.refusedCaseCount)，失败 \(proof.failedCaseCount)"
                if diagnosticDismissPending {
                    diagnosticPendingFeedback=pair
                } else {
                    activeSheet = .shareFeedback(pair.log,pair.json)
                }
            } catch {
                model.status="Build119 报告保存失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }

    /// Each level is opt-in and independent. Persist a checkpoint before
    /// LibRaw/Float64 allocation so a Jetsam leaves inspectable evidence.
    private func runBuild133RAWMemory(_ level:Int) {
        guard !model.busy,(0...4).contains(level),
              let rawURL=model.capturedRAWURL,
              model.rawOriginalSourceActive else {
            model.status="Build133 需要先选择 RAW 原片直通精细冲印"
            return
        }
        let parameters:OriginalSourcePhysicalImage.Parameters
        do {
            parameters=try model.rawMemoryDiagnosticParameters()
        } catch {
            model.status="Build133 原版光学参数不完整："+error.localizedDescription
            return
        }
        guard let dims=model.rawMemorySourceExtent,
              dims.width>0,dims.height>0,
              let docs=FileManager.default.urls(
                for:.documentDirectory,in:.userDomainMask).first else {
            model.status="Build133 RAW 原图尺寸或文件目录无效"
            return
        }
        let folder=docs.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true)
        let checkpoint=folder.appendingPathComponent(
            "Build133-RAW-level\(level)-last-checkpoint.txt")
        let bundle=Bundle.main
        let version=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString")
            as? String ?? "unknown"
        let build=bundle.object(forInfoDictionaryKey:"CFBundleVersion")
            as? String ?? "unknown"
        let commit=bundle.object(forInfoDictionaryKey:"SFSourceCommit")
            as? String ?? "missing"
        do {
            try FileManager.default.createDirectory(
                at:folder,withIntermediateDirectories:true)
            try "Build133 level=\(level) status=INCOMPLETE_OR_NOT_RUN\n"
                .write(to:checkpoint,atomically:true,encoding:.utf8)
        } catch {
            model.status="Build133 无法建立闪退检查点："+error.localizedDescription
            return
        }
        diagnosticDismissPending=true
        model.busy=true
        model.status="Build133 RAW 档位 \(level) 真实内存分级测试运行中"
        let w=Int(dims.width),h=Int(dims.height)
        let os=UIDevice.current.systemVersion
        let device=UIDevice.current.model
        Task { @MainActor in
            defer {model.busy=false}
            let report=await Task.detached(priority:.userInitiated) {
                Build133RAWMemoryLadder.capture(
                    level:level,rawURL:rawURL,sourceWidth:w,sourceHeight:h,
                    parameters:parameters,version:version,build:build,
                    commit:commit,osVersion:os,deviceModel:device,
                    checkpointURL:checkpoint)
            }.value
            do {
                let pair=try Build133RAWMemoryLadder.write(report,documents:docs)
                model.status = "Build133 RAW 档位 \(level)：" + report.status +
                    (report.firstFailure.map { "｜" + $0 } ?? "")
                if diagnosticDismissPending {
                    diagnosticPendingFeedback=pair
                } else {
                    activeSheet = .shareFeedback(pair.log,pair.json)
                }
            } catch {
                model.status="Build133 RAW 报告保存失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }

    private func runBuild108FullFrameFeedback() {
        guard !model.busy else {return}
        diagnosticDismissPending=true
        model.busy=true
        model.status="Build108：正在运行真实 100/200 万像素 Float64 光学 + 106/107 回归…"
        let bundle=Bundle.main
        let version=bundle.object(
            forInfoDictionaryKey:"CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build=bundle.object(
            forInfoDictionaryKey:"CFBundleVersion"
        ) as? String ?? "unknown"
        let sha=bundle.object(
            forInfoDictionaryKey:"SFSourceCommit"
        ) as? String ?? "missing"
        let device=UIDevice.current.model
        let osVersion=UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        let physicalDevice=false
        #else
        let physicalDevice=true
        #endif
        let manifest=bundle.url(
            forResource:"manifest",withExtension:"json",
            subdirectory:Build101DeviceParityEvidence.fixture
        )
        let grain=bundle.url(
            forResource:"manifest",withExtension:"json",
            subdirectory:"generated-source-grain-v1.8.48"
        )?.deletingLastPathComponent()
        Task { @MainActor in
            defer {model.busy=false}
            let report=await Task.detached(priority:.userInitiated) {
                Build108SourceOpticalDeviceStress.capture(
                    version:version,build:build,commit:sha,
                    device:device,osVersion:osVersion,
                    physicalDevice:physicalDevice,
                    coreManifest:manifest,grainDirectory:grain
                )
            }.value
            do {
                guard let documents=FileManager.default.urls(
                    for:.documentDirectory,in:.userDomainMask
                ).first else {
                    throw ImageProcessingError.invalid(
                        "Build108 真实光学反馈：文档目录不可访问"
                    )
                }
                let pair=try Build108SourceOpticalDeviceStress.write(
                    report,documents:documents
                )
                model.status=report.allControlledChecksPassedOnTarget
                    ? "Build108 1/2MP 原版完整光学与 106/107 回归通过；LOG＋JSON 已保存"
                    : "Build108 尚未全部通过：首错和真实 RSS 已保存到 LOG＋JSON"
                if diagnosticDismissPending {
                    diagnosticPendingFeedback=pair
                } else {
                    activeSheet = .shareFeedback(pair.log,pair.json)
                }
            } catch {
                model.status="Build108 反馈保存失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }

    private func runBuild107CombinedFeedback() {
        guard !model.busy else { return }
        diagnosticDismissPending=true
        model.busy=true
        model.status="正在运行 Build106+107 真机反馈：28+20 原版阶段、内存预算、16MiB RSS…"
        let bundle=Bundle.main
        let ver=bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString")
            as? String ?? "unknown"
        let build=bundle.object(forInfoDictionaryKey:"CFBundleVersion")
            as? String ?? "unknown"
        let revision=bundle.object(forInfoDictionaryKey:"SFSourceCommit")
            as? String ?? "missing"
        let device=UIDevice.current.model
        let system=UIDevice.current.systemVersion
        #if targetEnvironment(simulator)
        let physical=false
        #else
        let physical=true
        #endif
        let coreManifest=bundle.url(
            forResource:"manifest",withExtension:"json",
            subdirectory:Build101DeviceParityEvidence.fixture
        )
        let grainDirectory=bundle.url(
            forResource:"manifest",withExtension:"json",
            subdirectory:"generated-source-grain-v1.8.48"
        )?.deletingLastPathComponent()
        Task { @MainActor in
            defer {model.busy=false}
            let report=await Task.detached(priority:.userInitiated) {
                Build107CombinedDeviceFeedback.capture(
                    version:ver,build:build,commit:revision,
                    device:device,osVersion:system,
                    physicalDevice:physical,
                    coreManifest:coreManifest,grainDirectory:grainDirectory
                )
            }.value
            do {
                guard let documents=FileManager.default.urls(
                    for:.documentDirectory,in:.userDomainMask
                ).first else {
                    throw ImageProcessingError.invalid(
                        "Build106+107 LOG：文档目录不可访问")
                }
                let pair=try Build107CombinedDeviceFeedback.write(
                    report,documents:documents
                )
                model.status=report.allControlledChecksPassedOnTarget
                    ? "Build106+107 受控反馈 PASS：已生成 LOG + JSON（非 13MP 整图认证）"
                    : "Build106+107 检查未全部通过；首错和阶段结果已保存在 LOG + JSON"
                if diagnosticDismissPending {
                    diagnosticPendingFeedback=pair
                } else {
                    activeSheet = .shareFeedback(pair.log,pair.json)
                }
            } catch {
                model.status="Build106+107 反馈保存失败："+error.localizedDescription
                message=error.localizedDescription
            }
        }
    }

    private func enqueueDiagnosticShare(_ url: URL) {
        if diagnosticDismissPending {
            diagnosticPendingShare=url
        } else {
            activeSheet = .share(url)
        }
    }

    private func refresh() {
        do { try model.refresh() }
        catch { message = error.localizedDescription }
    }

    private func proposeExport(
        saveToPhotos: Bool, resolution: ExportResolutionMode,
        tiff16: Bool = false
    ) {
        guard model.hasPhoto && !model.busy else { return }
        do {
            guard !saveToPhotos || !tiff16 else {
                throw ImageProcessingError.invalid(
                    "TIFF16 当前仅从文件导出菜单分享，系统相册仍为 JPEG"
                )
            }
            let plan = try model.prepareExport(
                resolution: resolution, tiff16: tiff16
            )
            pendingExport = ExportProposal(
                toPhotos: saveToPhotos, tiff16: tiff16, plan: plan
            )
        } catch {
            message = error.localizedDescription
        }
    }

    private func performExport(
        saveToPhotos: Bool, tiff16: Bool = false,
        resolution: ExportResolutionMode,
        confirmedPlan: SafeExportResolution.Plan
    ) {
        guard model.hasPhoto && !model.busy else { return }
        model.busy = true
        let mode = resolution.title
        model.status = tiff16
            ? "正在制作\(mode) 的真实 16-bit TIFF 文件…"
            : (saveToPhotos
                ? "正在制作\(mode) JPEG 并写入系统相册…"
                : "正在制作\(mode) JPEG…")
        Task { @MainActor in
            defer { model.busy = false }
            do {
                if tiff16 {
                    // TIFF only: explicit file share, not Photos JPEG saver.
                    let file = try await model.exportTIFF16(
                        resolution: resolution, confirmedPlan: confirmedPlan
                    )
                    temporarySharedExport=Build98ExportTemporaryFiles.isOwnedExport(file)
                        ? file : nil
                    activeSheet = .share(file)
                } else {
                    let file = try await model.exportJPEG(
                        resolution: resolution, confirmedPlan: confirmedPlan
                    )
                    if saveToPhotos {
                        // The Photos operation has consumed the file only
                        // after await returns (also clean on thrown error).
                        defer {
                            _ = Build98ExportTemporaryFiles.removeAfterUse(file)
                        }
                        try await PhotoLibrarySaver.saveJPEG(at: file)
                        model.status = "\(mode)照片已保存到系统相册"
                    } else {
                        temporarySharedExport=Build98ExportTemporaryFiles.isOwnedExport(file)
                            ? file : nil
                        activeSheet = .share(file)
                    }
                }
            } catch {
                message = error.localizedDescription
                model.status = (tiff16 ? "TIFF16 " : "JPEG ") +
                    "高清导出失败：" + error.localizedDescription
            }
        }
    }
}

