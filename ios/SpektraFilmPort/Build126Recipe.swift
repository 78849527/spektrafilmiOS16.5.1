import Foundation

/// Build126: metadata-only saved recipes. NO full photographs or sensor RAW.
struct Build126Recipe: Codable, Identifiable {
    static let schema=1
    static let booleanKeys:Set<String> = [
        "hanatosOriginalPrecisionEnabled",
        "scatterEnabled",
        "halationEnabled",
        "grainEnabled",
        "grainSublayersEnabled",
        "grainDiscreteParticlesEnabled",
        "grainOriginalMetalEnabled",
        "grainOriginalSciPyEnabled",
        "originalScannerEnabled",
        "scannerCAM16Enabled",
        "scannerBlackWhiteEnabled",
        "scannerFinishingEnabled",
        "exposureReferenceEnabled",
        "printMorphEnabled",
        "originalPrintOpticsEnabled",
        "neutralPrintFiltersFromDatabase",
        "printSourceDiffusionEnabled",
        "normalizePrintExposure",
        "printExposureCompensation",
        "preflashEnabled",
        "spatialDIREnabled",
        "spatialDIRSourceConvolutionEnabled",
        "sourcePixelIOEnabled",
        "sourcePhysicalDirectEnabled",
        "sourcePhysicalCAM16DefaultGamutEnabled",
        "sourcePhysicalInputOklchEnabled",
        "sourceScannerOpticalEnabled",
        "sourceScannerGlareEnabled",
        "sourcePhysicalGrainEnabled",
        "sourceGrainUseUnseededParallel",
        "sourceGrainFastStatsEnabled",
        "sourceCameraPreFilmEnabled",
        "sourceCameraDiffusionEnabled",
        "sourceHanatosFullRecompute",
        "sourceCameraUVEnabled",
        "sourceCameraIREnabled",
        "sourceFilmHalationEnabled"
    ]
    static let numberKeys:Set<String> = [
        "strength",
        "filmExposureEV",
        "printExposureEV",
        "halationAmount",
        "grainAmount",
        "scannerSharpenAmount",
        "printGamma",
        "printFastGamma",
        "printSlowGamma",
        "printDeveloperExhaustion",
        "printSourceDiffusionStrength",
        "printSourceDiffusionSpatialScale",
        "printSourceDiffusionWarmth",
        "printSourceDiffusionCoreIntensity",
        "printSourceDiffusionCoreSize",
        "printSourceDiffusionHaloIntensity",
        "printSourceDiffusionHaloSize",
        "printSourceDiffusionBloomIntensity",
        "printSourceDiffusionBloomSize",
        "printCyanShift",
        "printMagentaShift",
        "printYellowShift",
        "preflashExposure",
        "preflashMagentaShift",
        "preflashYellowShift",
        "spatialDIRRadiusScale",
        "sourceScannerLensBlurSigma",
        "sourceScannerUnsharpSigma",
        "sourceScannerUnsharpAmount",
        "sourceScannerGlarePercent",
        "sourceScannerGlareRoughness",
        "sourceScannerGlareBlur",
        "sourcePhysicalGrainBlur",
        "sourcePhysicalGrainDyeCloudBlur",
        "sourcePhysicalGrainMicroUM",
        "sourcePhysicalGrainMicroNM",
        "sourceCameraHighlightBoostEV",
        "sourceCameraHighlightBoostRange",
        "sourceCameraHighlightProtectEV",
        "sourceCameraLensBlurUM",
        "sourceCameraDiffusionStrength",
        "sourceCameraDiffusionSpatialScale",
        "sourceCameraDiffusionWarmth",
        "sourceCameraDiffusionCoreIntensity",
        "sourceCameraDiffusionCoreSize",
        "sourceCameraDiffusionHaloIntensity",
        "sourceCameraDiffusionHaloSize",
        "sourceCameraDiffusionBloomIntensity",
        "sourceCameraDiffusionBloomSize",
        "sourceCameraUVAmount",
        "sourceCameraUVCutoffNM",
        "sourceCameraUVWidthNM",
        "sourceCameraIRAmount",
        "sourceCameraIRCutoffNM",
        "sourceCameraIRWidthNM",
        "sourceFilmScatterAmount",
        "sourceFilmScatterScale",
        "sourceFilmHalationAmount",
        "sourceFilmHalationScale"
    ]
    static let enumKeys:Set<String> = [
        "printIlluminant",
        "printSourceDiffusionFamily",
        "sourceCameraMeteringMethod",
        "sourceCameraDiffusionFamily",
        "sourceCameraRawMethod"
    ]

    var schemaVersion:Int
    var id:UUID
    var name:String
    var createdAt:Date
    var modifiedAt:Date
    var favorite:Bool
    var filmID:String
    var paperID:String
    var bools:[String:Bool]
    var numbers:[String:Double]
    var choices:[String:String]
    var embeddedLUT:Build126RecipeLUT?
    /// Optional deliberately tiny cover (~240px). No full-size photo.
    var coverJPEG:Data?
    /// Build128 additive optional field. Missing means Build126 8-bit
    /// source mode; old on-device and exported recipes remain decodable.
    var inputContract:String?

    func validateStructure() throws {
        guard schemaVersion==Self.schema else {
            throw ImageProcessingError.invalid("配方格式版本不兼容；未应用任何参数")
        }
        let clean=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !clean.isEmpty,clean.count<=40 else {
            throw ImageProcessingError.invalid("配方名称必须为 1–40 个字符")
        }
        guard Set(bools.keys)==Self.booleanKeys,
              Set(numbers.keys)==Self.numberKeys,
              Set(choices.keys)==Self.enumKeys,
              numbers.values.allSatisfy({ $0.isFinite && abs($0)<100_000 }) else {
            throw ImageProcessingError.invalid(
                "配方缺少字段、含未知字段或异常数值；拒绝部分应用"
            )
        }
        guard choices["printIlluminant"].flatMap(OriginalPrintOptics.Illuminant.init(rawValue:)) != nil,
              choices["printSourceDiffusionFamily"].flatMap(OriginalSourceDiffusion.Family.init(rawValue:)) != nil,
              choices["sourceCameraDiffusionFamily"].flatMap(OriginalSourceDiffusion.Family.init(rawValue:)) != nil,
              choices["sourceCameraMeteringMethod"].flatMap(OriginalSourceCameraOptics.Metering.init(rawValue:)) != nil,
              choices["sourceCameraRawMethod"].flatMap(SpectralPhysics.CameraRawMethod.init(rawValue:)) != nil else {
            throw ImageProcessingError.invalid("配方包含不支持的原版枚举值")
        }
        guard inputContract == nil ||
              ["uint8SRGB","uint16SRGB","float16ExtendedSRGB",
               "float32ExtendedSRGB"].contains(inputContract!) else {
            throw ImageProcessingError.invalid(
                "配方输入格式契约未知，拒绝不兼容模式或静默降级"
            )
        }
        guard coverJPEG == nil || coverJPEG!.count <= 120_000 else {
            throw ImageProcessingError.invalid("封面缩略图不能超过 120KB")
        }
        try embeddedLUT?.validate()
    }
}

struct Build126RecipeLUT: Codable {
    let title:String
    let dimension:Int
    let rgbaFloatData:Data
    func validate() throws {
        guard (2...65).contains(dimension),
              rgbaFloatData.count == dimension * dimension * dimension * 4 * MemoryLayout<Float>.size,
              rgbaFloatData.count <= 5_000_000 else {
            throw ImageProcessingError.invalid("自定义 LUT 文件尺寸无效；拒绝部分应用")
        }
        let finite=rgbaFloatData.withUnsafeBytes { p -> Bool in
            for i in 0..<(rgbaFloatData.count/4) {
                let bits=p.loadUnaligned(fromByteOffset:i*4,as:UInt32.self)
                if !Float(bitPattern:bits).isFinite { return false }
            }
            return true
        }
        guard finite else {
            throw ImageProcessingError.invalid("自定义 LUT 包含 NaN 或无限大")
        }
    }
}

enum Build126RecipeStorage {
    static func folder() throws -> URL {
        guard let docs=FileManager.default.urls(
            for:.documentDirectory,in:.userDomainMask
        ).first else {
            throw ImageProcessingError.invalid("找不到配方存储目录")
        }
        let dir=docs.appendingPathComponent(
            "SpektraFilm Recipes",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:dir,withIntermediateDirectories:true
        )
        return dir
    }
    static func libraryURL() throws -> URL {
        try folder().appendingPathComponent("recipes.json")
    }
    static func load() throws -> [Build126Recipe] {
        let url=try libraryURL()
        guard FileManager.default.fileExists(atPath:url.path) else {return []}
        let bytes=try Data(contentsOf:url)
        guard bytes.count<=40_000_000 else {
            throw ImageProcessingError.invalid("配方库过大，拒绝加载")
        }
        let entries=try JSONDecoder().decode([Build126Recipe].self,from:bytes)
        guard entries.count<=300 && Set(entries.map(\.id)).count==entries.count else {
            throw ImageProcessingError.invalid("配方库编号重复或超过 300 项")
        }
        for r in entries { try r.validateStructure() }
        return entries
    }
    static func write(_ entries:[Build126Recipe]) throws {
        guard entries.count<=300 && Set(entries.map(\.id)).count==entries.count else {
            throw ImageProcessingError.invalid("配方超过 300 项或编号重复")
        }
        for r in entries { try r.validateStructure() }
        let bytes=try JSONEncoder().encode(entries)
        guard bytes.count<=40_000_000 else {
            throw ImageProcessingError.invalid("配方库超过 40MB，未保存更改")
        }
        try bytes.write(to:libraryURL(),options:.atomic)
    }
    static func export(_ recipe:Build126Recipe) throws -> URL {
        try recipe.validateStructure()
        let out=try folder().appendingPathComponent(
            "Recipe-" + recipe.id.uuidString + ".sfrecept.json"
        )
        try JSONEncoder().encode(recipe).write(to:out,options:.atomic)
        return out
    }
    static func imported(from url:URL) throws -> Build126Recipe {
        let granted=url.startAccessingSecurityScopedResource()
        defer { if granted {url.stopAccessingSecurityScopedResource()} }
        let bytes=try Data(contentsOf:url)
        guard bytes.count<6_000_000 else {
            throw ImageProcessingError.invalid("配方导入文件超过安全容量")
        }
        let recipe=try JSONDecoder().decode(Build126Recipe.self,from:bytes)
        try recipe.validateStructure()
        return recipe
    }
}
