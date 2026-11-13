import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum ImageProcessingError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let description) = self { return description }
        return nil
    }
}

enum PhotoProcessor {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: srgb, .cacheIntermediates: false
    ])

    static func decode(_ data: Data) throws -> CIImage {
        guard let image = CIImage(data: data, options: [
            .applyOrientationProperty: true
        ]), !image.extent.isEmpty,
              image.extent.width > 0, image.extent.height > 0 else {
            throw ImageProcessingError.invalid("无法解码。首版支持 JPEG、HEIC、PNG、TIFF；不支持 RAW。")
        }
        return image
    }

    static func apply(
        to source: CIImage, lut: FilmLUT?, strength: Double,
        spatial: SpatialOpticsSettings = SpatialOpticsSettings(),
        grain: DensityGrainSettings? = nil,
        scanner: ScannerFinishSettings = ScannerFinishSettings(),
        dirStage: SpatialDIRStage? = nil,
        dirSettings: SpatialDIRSettings = SpatialDIRSettings()
    ) throws -> CIImage {
        // Spatial optical propagation precedes spectral film colour response.
        // Operate at requested output resolution, not full source resolution,
        // so the effective micrometers/pixel remains consistent.
        let optical = SpatialOptics.apply(to: source, settings: spatial)
        guard let lut = lut, strength > 0 else { return optical }
        // The source-order Metal path is STRICT: never silently replace
        // it with a fast CoreImage approximation or drop an enabled DIR.
        let sourceMetal = grain?.originalMetalEnabled == true
        var spatialOutput: CIImage?
        if dirSettings.enabled {
            // Source DIR is a requested processing stage. An unavailable
            // source stage or failed filter must NEVER silently replace
            // it with the regular nonspatial RGB colour cube.
            guard let dirStage else {
                throw ImageProcessingError.invalid(
                    "原版 DIR 已启用但缺少真实胶片曝光/密度阶段，禁止跳过"
                )
            }
            spatialOutput = try SpatialDIR.apply(
                to: optical,stage:dirStage,
                settings:dirSettings,grain:grain
            )
            guard spatialOutput != nil else {
                throw ImageProcessingError.invalid(
                    sourceMetal
                    ? "原版 Metal 颗粒：DIR 中间光学密度不可用，禁止退回快速模式"
                    : "原版空间 DIR 内核未生成结果，禁止退回普通 LUT"
                )
            }
        }
        let film: CIImage
        if let spatialOutput {
            film = spatialOutput
        } else if let grain {
            if let output = try DensityGrain.apply(
                to: optical, settings: grain
            ) {
                // The original source grain is in film optical density,
                // preceding physical paper print and scanner output.
                film = output
            } else {
                if sourceMetal {
                    throw ImageProcessingError.invalid(
                        "原版 Metal 颗粒：胶片显影失败，禁止退回快速模式"
                    )
                }
                let cube = CIFilter.colorCube()
                cube.inputImage = optical
                cube.cubeDimension = Float(lut.dimension)
                cube.cubeData = lut.rgbaFloatData
                guard let output = cube.outputImage else { return optical }
                film = output
            }
        } else {
            let cube = CIFilter.colorCube()
            cube.inputImage = optical
            cube.cubeDimension = Float(lut.dimension)
            cube.cubeData = lut.rgbaFloatData
            guard let output = cube.outputImage else { return optical }
            film = output
        }
        let amount = max(0, min(1, strength))
        if amount >= 1 {
            return ScannerFinishing.apply(
                to: film.cropped(to: optical.extent), settings: scanner
            )
        }

        let alpha = CIFilter.colorMatrix()
        alpha.inputImage = film
        alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))
        let blend = CIFilter.sourceOverCompositing()
        blend.inputImage = alpha.outputImage
        blend.backgroundImage = optical
        let blended = (blend.outputImage ?? optical).cropped(to: optical.extent)
        return ScannerFinishing.apply(to: blended, settings: scanner)
    }

    static func preview(
        _ source: CIImage, lut: FilmLUT?, strength: Double,
        spatial: SpatialOpticsSettings = SpatialOpticsSettings(),
        grain: DensityGrainSettings? = nil,
        scanner: ScannerFinishSettings = ScannerFinishSettings(),
        dirStage: SpatialDIRStage? = nil,
        dirSettings: SpatialDIRSettings = SpatialDIRSettings()
    ) throws -> UIImage {
        let factor = min(1.0, 1500 / max(source.extent.width, source.extent.height))
        let resized = source.transformed(by:
            CGAffineTransform(scaleX: factor, y: factor))
        let image = try apply(
            to: resized, lut: lut, strength: strength,
            spatial: spatial, grain: grain, scanner: scanner,
            dirStage: dirStage, dirSettings: dirSettings
        )
        guard let cg = context.createCGImage(image, from: image.extent) else {
            throw ImageProcessingError.invalid("预览渲染失败")
        }
        return UIImage(cgImage: cg)
    }

    struct ExportResult {
        let url: URL
        let width: Int
        let height: Int
        let downsampled: Bool
    }

    static func exportJPEG(
        _ source: CIImage, lut: FilmLUT?, strength: Double,
        spatial: SpatialOpticsSettings = SpatialOpticsSettings(),
        grain: DensityGrainSettings? = nil,
        scanner: ScannerFinishSettings = ScannerFinishSettings(),
        dirStage: SpatialDIRStage? = nil,
        dirSettings: SpatialDIRSettings = SpatialDIRSettings(),
        resolution: ExportResolutionMode = .original,
        confirmedPlan: SafeExportResolution.Plan? = nil
    ) throws -> ExportResult {
        // Full-resolution output: NEVER silently shrink high-resolution
        // images to 12.5 MP. The preview remains 1500 px for performance.
        // On-memory CI filters evaluate lazily until JPEG encoding.
        guard source.extent.width.isFinite, source.extent.height.isFinite,
              source.extent.width > 0, source.extent.height > 0 else {
            throw ImageProcessingError.invalid("源照片尺寸无效")
        }
        // Explicit choice only: ORIGINAL always evaluates at source pixel
        // dimensions. SAFE first reduces the entire input to a conservative
        // budget, then executes the exact same optical density/SciPy/Metal
        // chain on that whole output image (no per-tile random stream reset).
        var workingSource = source
        var downsampled = false
        if resolution != .original {
            let bounds = source.extent.integral
            let plan = try confirmedPlan ??
                SafeExportResolution.capture(
                    width: Int(bounds.width),
                    height: Int(bounds.height), mode: resolution
                )
            guard plan.sourceWidth == Int(bounds.width),
                  plan.sourceHeight == Int(bounds.height),
                  plan.mode == resolution else {
                throw ImageProcessingError.invalid(
                    "安全输出：已确认的尺寸与当前照片不匹配，请重新选择"
                )
            }
            try SafeExportResolution.validateBeforeRender(plan)
            let target = plan.dimensions
            if target.reduced {
                // Normalize image coordinates to zero before filtering.
                // Fractional dimensions are cropped to an exact integer
                // output rectangle; never upscale or stretch the aspect.
                let normalized = source.transformed(
                    by: CGAffineTransform(
                        translationX: -bounds.minX, y: -bounds.minY
                    )
                ).cropped(to: CGRect(origin: .zero, size: bounds.size))
                let ratio = max(
                    Double(target.width) / Double(bounds.width),
                    Double(target.height) / Double(bounds.height)
                )
                let shrink = CIFilter.lanczosScaleTransform()
                shrink.inputImage = normalized
                shrink.scale = Float(ratio)
                shrink.aspectRatio = 1
                guard let scaled = shrink.outputImage else {
                    throw ImageProcessingError.invalid(
                        "安全输出：无法创建 Lanczos 等比例缩小图像"
                    )
                }
                workingSource = scaled.cropped(
                    to: CGRect(
                        x: 0, y: 0,
                        width: CGFloat(target.width),
                        height: CGFloat(target.height)
                    )
                )
                downsampled = true
            }
        }
        let image = try apply(
            to: workingSource, lut: lut, strength: strength,
            spatial: spatial, grain: grain, scanner: scanner,
            dirStage: dirStage, dirSettings: dirSettings
        )
        // Core Image's CIImageRepresentationOption has no JPEG quality key
        // on iOS 16.5. Use ImageIO CGImageDestination for a real 0.98
        // compression setting and write straight to disk (not a giant Data
        // allocation on the main actor).
        guard let rendered = context.createCGImage(image, from: image.extent) else {
            throw ImageProcessingError.invalid(
                resolution == .original
                    ? "原尺寸高清渲染失败，请检查可用内存"
                    : "安全分辨率渲染失败：设备仍可能内存不足，请检查可用内存"
            )
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraFilmPort-" + UUID().uuidString)
            .appendingPathExtension("jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ImageProcessingError.invalid("无法创建高清 JPEG 文件")
        }
        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: 0.98
        ]
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.invalid("原尺寸高清 JPEG 写入失败，请检查储存空间")
        }
        return ExportResult(url: url, width: rendered.width,
                            height: rendered.height,
                            downsampled: downsampled)
    }
}
