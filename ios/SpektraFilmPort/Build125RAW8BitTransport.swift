import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Explicit transport ONLY: developed Apple RAW pixels -> tagged 8-bit sRGB JPEG.
/// This is not sensor RAW, rawpy parity, or an unannounced precision fallback.
/// The original DNG stays in Documents and is never replaced.
enum Build125RAW8BitTransport {
    private static let srgb=CGColorSpace(name:CGColorSpace.sRGB)!

    static func makeCertifiedCopy(_ rawImage:CIImage) throws -> Data {
        let bounds=rawImage.extent.integral
        guard !bounds.isEmpty,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width>=1, bounds.height>=1,
              bounds.width<=8192, bounds.height<=8192,
              bounds.width*bounds.height<=16_000_000 else {
            throw ImageProcessingError.invalid(
                "RAW 副本超出 8-bit 原版像素输入的 1600 万像素／8192 边长限制；" +
                "不允许静默缩小或冒充原始 RAW"
            )
        }

        let context=CIContext(options:[
            .workingColorSpace:srgb,.cacheIntermediates:false
        ])
        guard let cg=context.createCGImage(
            rawImage,from:bounds,format:.RGBA8,colorSpace:srgb
        ) else {
            throw ImageProcessingError.invalid(
                "Apple RAW → sRGB 8-bit 真正色彩转换失败；DNG 原片未修改"
            )
        }
        guard cg.width==Int(bounds.width),
              cg.height==Int(bounds.height) else {
            throw ImageProcessingError.invalid(
                "RAW 色彩转换产生的像素尺寸与源图不一致，拒绝输入"
            )
        }

        let bytes=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(
            bytes,UTType.jpeg.identifier as CFString,1,nil
        ) else {
            throw ImageProcessingError.invalid("不能生成独立 sRGB JPEG 副本")
        }
        CGImageDestinationAddImage(
            dest,cg,[kCGImageDestinationLossyCompressionQuality:0.98]
                as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else {
            throw ImageProcessingError.invalid(
                "sRGB 8-bit 副本编码失败；DNG 原片未修改"
            )
        }
        let result=bytes as Data
        let check=Build111PhotoInputProfile.inspect(
            result,entry:.converted
        )
        guard check.directCompatible && check.width==cg.width &&
              check.height==cg.height && check.declaredDepth==8 &&
              check.decodedDepth==8 &&
              check.color == .sRGB else {
            throw ImageProcessingError.invalid(
                "8-bit 副本未通过现有色彩/位深/像素输入认证：" +
                check.summary + "。" + check.reason
            )
        }
        return result
    }
}
