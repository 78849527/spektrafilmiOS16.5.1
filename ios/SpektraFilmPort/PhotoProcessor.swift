import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
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
        scanner: ScannerFinishSettings = ScannerFinishSettings()
    ) -> CIImage {
        // Spatial optical propagation precedes spectral film colour response.
        // Operate at requested output resolution, not full source resolution,
        // so the effective micrometers/pixel remains consistent.
        let optical = SpatialOptics.apply(to: source, settings: spatial)
        guard let lut = lut, strength > 0 else { return optical }
        let film: CIImage
        if let grain = grain, let output = DensityGrain.apply(to: optical, settings: grain) {
            // Grain is inserted after measured negative/positive development,
            // before the original measured paper/scan optics. Not RGB overlay.
            film = output
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
        scanner: ScannerFinishSettings = ScannerFinishSettings()
    ) throws -> UIImage {
        let factor = min(1.0, 1500 / max(source.extent.width, source.extent.height))
        let resized = source.transformed(by:
            CGAffineTransform(scaleX: factor, y: factor))
        let image = apply(
            to: resized, lut: lut, strength: strength,
            spatial: spatial, grain: grain, scanner: scanner
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
        scanner: ScannerFinishSettings = ScannerFinishSettings()
    ) throws -> ExportResult {
        // Full-resolution output: NEVER silently shrink high-resolution
        // images to 12.5 MP. The preview remains 1500 px for performance.
        // On-memory CI filters evaluate lazily until JPEG encoding.
        guard source.extent.width.isFinite, source.extent.height.isFinite,
              source.extent.width > 0, source.extent.height > 0 else {
            throw ImageProcessingError.invalid("源照片尺寸无效")
        }
        let image = apply(
            to: source, lut: lut, strength: strength,
            spatial: spatial, grain: grain, scanner: scanner
        )
        guard let data = context.jpegRepresentation(
            of: image, colorSpace: srgb,
            options: [.lossyCompressionQuality: 0.98]
        ) else {
            throw ImageProcessingError.invalid("原尺寸高清 JPEG 导出失败，请检查可用内存与储存空间")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraFilmPort-" + UUID().uuidString)
            .appendingPathExtension("jpg")
        try data.write(to: url, options: .atomic)
        return ExportResult(url: url, width: Int(image.extent.width.rounded()),
                            height: Int(image.extent.height.rounded()),
                            downsampled: false)
    }
}
