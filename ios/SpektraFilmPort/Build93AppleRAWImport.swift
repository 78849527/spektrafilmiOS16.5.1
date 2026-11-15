import Foundation
import CoreGraphics
import CoreImage

/// Build93: explicit Apple RAW compatibility ingress for iOS 16.5+.
/// This is a separately selected *fast* camera-RAW path, NOT source
/// rawpy/LibRaw X-Trans numeric equivalence or the CPU Float64 path.
/// NEVER use CIImage(contentsOf:) / an embedded RAF JPEG as a fallback.
enum Build93AppleRAWImport {
    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            if case .unsupported(let text) = self { return text }
            return nil
        }
    }

    struct Decoded {
        let image: CIImage
        let format: Build79RAWSignature.Kind
        let width: Int
        let height: Int
        let decoderVersion: String
        let evidenceRGBA: [Float]
    }

    static func open(_ url: URL) throws -> Decoded {
        guard let kind = try Build79RAWSignature.probeFile(url) else {
            throw Failure.unsupported("未识别到有效相机 RAW；不会采用容器里的 JPEG 缩略图")
        }
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw Failure.unsupported(
                "iOS 16.5.1 原生 RAW 不支持当前 ." +
                kind.rawValue.uppercased() +
                " 的机型或压缩方式。富士 X-T5 请先试「无压缩 RAF」；" +
                "无损/有损压缩需要后续 LibRaw 原生解码，原始文件已完整保存。"
            )
        }
        // Configure a defined Apple pipeline. Its white balance / X-Trans
        // demosaic are NOT source rawpy defaults and may vary by iOS version.
        raw.isDraftModeEnabled = false
        raw.isGamutMappingEnabled = false
        raw.isLensCorrectionEnabled = false
        raw.boostAmount = 0
        raw.localToneMapAmount = 0
        guard let output = raw.outputImage else {
            throw Failure.unsupported("Apple CIRAWFilter 没有输出实际 RAW 像素")
        }
        let area = output.extent
        guard !area.isEmpty,
              area.width.isFinite, area.height.isFinite,
              area.width >= 4, area.height >= 4,
              area.width <= 100_000, area.height <= 100_000 else {
            throw Failure.unsupported("Apple RAW 全像素区域无效")
        }
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        else {
            throw Failure.unsupported("设备没有 extended-linear-sRGB 色彩空间")
        }
        // Force an ACTUAL RAW render before accepting the image. The 4x4
        // Float32 proof is bounded even for 40 MP X-T5 source files.
        let bounds = CGRect(
            x: floor(area.midX) - 2,
            y: floor(area.midY) - 2,
            width: 4, height: 4
        )
        var values = [Float](repeating: .nan, count: 4 * 4 * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        values.withUnsafeMutableBytes { bytes in
            context.render(
                output, toBitmap: bytes.baseAddress!,
                rowBytes: 4 * 4 * MemoryLayout<Float>.size,
                bounds: bounds, format: .RGBAf, colorSpace: linear
            )
        }
        guard values.allSatisfy({ $0.isFinite }) else {
            throw Failure.unsupported(
                "Apple RAW 真实像素解码失败/出现 NaN 或 Inf；不回退 JPEG"
            )
        }
        return Decoded(
            image: output,
            format: kind,
            width: Int(area.width),
            height: Int(area.height),
            decoderVersion: String(describing: raw.decoderVersion),
            evidenceRGBA: values
        )
    }
}
