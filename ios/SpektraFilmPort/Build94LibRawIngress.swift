import Foundation
import CoreGraphics
import CoreImage

/// Build94 Fujifilm X-T5 compressed RAF compatibility.
/// Explicitly chosen LibRaw 0.22 fast-mode path; NEVER Python source Float64.
/// RGB8 is deliberate user-facing quick preview/export quantization.
enum Build94LibRawIngress {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }
    struct Decoded {
        let image: CIImage
        let width: Int
        let height: Int
        let librawVersion: String
        let bitDepth: Int
    }
    static func open(_ url: URL) throws -> Decoded {
        guard let kind = try Build79RAWSignature.probeFile(url),
              kind == .raf else {
            throw Failure.invalid(
                "Build94 LibRaw 兼容模式当前仅对富士 RAF 开放；" +
                "DNG/CR3/NEF/ARW 仍按 Build93 Apple RAW 路径处理"
            )
        }
        // Actual native C++ library performs the full unpack and X-Trans
        // process; never calls an embedded JPEG thumbnail decoder.
        let raw = try SFBuild94LibRaw.decode(url)
        let width = raw.width, height = raw.height
        guard width > 0, height > 0,
              width <= 10000, height <= 10000,
              width <= 45_000_000 / height,
              raw.rgb8.length == width * height * 3,
              let provider = CGDataProvider(data: raw.rgb8 as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.invalid(
                "LibRaw 输出尺寸/通道无效或超出 4500 万像素；不回退内嵌 JPEG"
            )
        }
        // LibRaw dcraw_process has already converted sensor data to sRGB
        // RGB8. CGImage/CIImage merely transport these decoded pixels.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: width * 3, space: space,
            bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else {
            throw Failure.invalid(
                "LibRaw 已成功解包，但无法创建 RGB8 图像；禁止伪装为支持"
            )
        }
        return Decoded(
            image: CIImage(cgImage: cg, options: [.colorSpace: space]),
            width: width, height: height,
            librawVersion: raw.decoder, bitDepth: 8
        )
    }
}
