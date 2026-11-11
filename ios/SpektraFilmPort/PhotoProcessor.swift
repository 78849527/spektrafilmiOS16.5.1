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

    static func apply(to source: CIImage, lut: FilmLUT?, strength: Double) -> CIImage {
        guard let lut = lut, strength > 0 else { return source }
        let cube = CIFilter.colorCube()
        cube.inputImage = source
        cube.cubeDimension = lut.dimension
        cube.cubeData = lut.rgbaFloatData
        guard let film = cube.outputImage else { return source }
        let amount = max(0, min(1, strength))
        if amount >= 1 { return film.cropped(to: source.extent) }

        let alpha = CIFilter.colorMatrix()
        alpha.inputImage = film
        alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount))
        let blend = CIFilter.sourceOverCompositing()
        blend.inputImage = alpha.outputImage
        blend.backgroundImage = source
        return (blend.outputImage ?? source).cropped(to: source.extent)
    }

    static func preview(_ source: CIImage, lut: FilmLUT?, strength: Double) throws -> UIImage {
        let image = apply(to: source, lut: lut, strength: strength)
        let factor = min(1, 1500 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
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

    static func exportJPEG(_ source: CIImage, lut: FilmLUT?,
                           strength: Double) throws -> ExportResult {
        let pixels = max(1, source.extent.width * source.extent.height)
        let factor = min(1, sqrt(12_500_000 / pixels))
        let image = apply(to: source, lut: lut, strength: strength)
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
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
