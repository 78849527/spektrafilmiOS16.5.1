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
        grain: DensityGrainSettings? = nil
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
        if amount >= 1 { return film.cropped(to: optical.extent) }

        let alpha = CIFilter.colorMatrix()
        alpha.inputImage = film
        alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))
        let blend = CIFilter.sourceOverCompositing()
        blend.inputImage = alpha.outputImage
        blend.backgroundImage = optical
        return (blend.outputImage ?? optical).cropped(to: optical.extent)
    }

    static func preview(
        _ source: CIImage, lut: FilmLUT?, strength: Double,
        spatial: SpatialOpticsSettings = SpatialOpticsSettings(),
        grain: DensityGrainSettings? = nil
    ) throws -> UIImage {
        let factor = min(1.0, 1500 / max(source.extent.width, source.extent.height))
        let resized = source.transformed(by:
            CGAffineTransform(scaleX: factor, y: factor))
        let image = apply(
            to: resized, lut: lut, strength: strength,
            spatial: spatial, grain: grain
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
        grain: DensityGrainSettings? = nil
    ) throws -> ExportResult {
        let pixels = max(1, source.extent.width * source.extent.height)
        let factor = min(1, sqrt(12_500_000 / pixels))
        let resized = source.transformed(by:
            CGAffineTransform(scaleX: factor, y: factor))
        let image = apply(
            to: resized, lut: lut, strength: strength,
            spatial: spatial, grain: grain
        )
        guard let data = context.jpegRepresentation(
            of: image, colorSpace: srgb, options: [:]
        ) else {
            throw ImageProcessingError.invalid("JPEG 导出失败")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraFilmPort-" + UUID().uuidString)
            .appendingPathExtension("jpg")
        try data.write(to: url, options: .atomic)
        return ExportResult(url: url, width: Int(image.extent.width.rounded()),
                            height: Int(image.extent.height.rounded()),
                            downsampled: factor < 0.9999)
    }
}
