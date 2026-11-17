import Foundation
import CoreGraphics
import CoreImage

/// Build95: independently selected 16-bit LibRaw camera processing.
/// 16-bit is post-LibRaw sRGB precision, NOT the 14-bit sensor CFA,
/// Python rawpy/LibRaw ACES2065-1, or Float64 original exact pipeline.
enum Build95LibRaw16Ingress {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    struct Frame {
        let image: CIImage
        let width: Int
        let height: Int
        let bitsPerComponent: Int
        let librawVersion: String
    }

    /// Pure, overflow-safe budget used before creating a full-size CGImage.
    /// Approximation is an admission guard, NOT proof of live iPhone RSS.
    static func memoryPlan(width: Int, height: Int, bits: Int) throws -> UInt64 {
        guard bits == 8 || bits == 16, width > 0, height > 0,
              width <= 10_000, height <= 10_000,
              width <= 45_000_000 / height else {
            throw Failure.invalid("LibRaw 高位深输入尺寸或位深超出 Build95 上限")
        }
        let pixels = UInt64(width) * UInt64(height)
        // Sensor unpack, original 4-channel image, LibRaw processed output,
        // copied NSData and CoreGraphics transport, plus fixed decoder scratch.
        let estimate = pixels * UInt64(bits == 16 ? 28 : 18) + 96_000_000
        // LibRaw native pre-unpack already checked live headroom.
        // Avoid charging already allocated source bytes a second time.
        return estimate
    }

    static func open(_ url: URL) throws -> Frame {
        guard let kind = try Build79RAWSignature.probeFile(url), kind == .raf else {
            throw Failure.invalid(
                "16-bit LibRaw 目前仅允许实际富士 RAF；其他 RAW 不做格式伪装"
            )
        }
        let decoded = try SFBuild94LibRaw.decode(url, bitsPerComponent: 16)
        let w = decoded.width, h = decoded.height
        let actual = decoded.bitsPerComponent
        _ = try memoryPlan(width: w, height: h, bits: actual)
        guard actual == 16 else {
            throw Failure.invalid(
                "LibRaw 没有返回请求的 16-bit 输出；拒绝冒用 8-bit"
            )
        }
        let bytes = decoded.rgb8 as Data
        guard bytes.count == w * h * 3 * 2,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: bytes as CFData) else {
            throw Failure.invalid("16-bit RGB 缓冲区长度/色彩空间不合法")
        }
        // LibRaw mem_image.cpp writes native-endian UInt16 to memory. On
        // iPhoneOS arm64 this is little-endian; no hidden RGBA8 conversion.
        let bitmap = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.none.rawValue |
            CGBitmapInfo.byteOrder16Little.rawValue
        )
        guard let cg = CGImage(
            width: w, height: h, bitsPerComponent: 16,
            bitsPerPixel: 48, bytesPerRow: w * 6,
            space: space, bitmapInfo: bitmap, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ), cg.bitsPerComponent == 16 else {
            throw Failure.invalid(
                "iOS CoreGraphics 不接受 48-bit RGB，已拒绝 8-bit 静默转换；" +
                "请明确改选 Build94 8-bit 快速模式"
            )
        }
        let image = CIImage(cgImage: cg, options: [
            .colorSpace: space,
            .applyOrientationProperty: false
        ])
        return Frame(
            image: image, width: w, height: h,
            bitsPerComponent: 16, librawVersion: decoded.decoder
        )
    }
}
