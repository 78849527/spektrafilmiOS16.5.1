import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Build128, explicitly user-selected precision bridge:
/// actual Apple CIRAWFilter developed pixels -> 32-bit floating extended-sRGB
/// TIFF -> existing Build78 Float TIFF ImageIO-to-Double admission.
/// This is not sensor Bayer samples, rawpy parity or a lossless round trip
/// to camera DNG. No UInt8/JPEG, clipping, hidden resizing or mode fallback.
enum Build128RAWFloat32Transport {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let reason)=self{return reason}
            return nil
        }
    }
    struct Result {
        let bytes:Data
        let admission:Build111PhotoInputProfile.Inspection
    }

    static func makeVerifiedCopy(_ rawImage:CIImage)throws->Result {
        let bounds=rawImage.extent.integral
        guard !bounds.isEmpty,bounds.width.isFinite,bounds.height.isFinite,
              bounds.width>=4,bounds.height>=4,
              bounds.width<=8192,bounds.height<=8192 else {
            throw Failure.invalid(
                "RAW Float32 精确入口要求有效原尺寸，单边最多 8192；DNG 原片未修改"
            )
        }
        let w=Int(bounds.width),h=Int(bounds.height)
        // Existing Build78/PixelIO gate is 16MP, full-source physical may
        // impose a further original memory limit. Never silently resample.
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:w,height:h,maximumAllowedPixels:16_000_000
        )
        // Conservative actual memory admission: RAW CI working sets,
        // Float32 TIFF, decoding, and later CPU Double buffers. This is an
        // admission estimate, not a claim that jetsam is impossible.
        let estimate=UInt64(w)*UInt64(h)*96+96_000_000
        let limit=min(1_500_000_000,ProcessInfo.processInfo.physicalMemory/3)
        guard estimate<=limit else {
            throw Failure.invalid(
                "RAW Float32 原尺寸转换预估 " +
                String(estimate/1_000_000) + "MB，设备预算 " +
                String(limit/1_000_000) +
                "MB；已取消，不截断像素、不降低位深，也不转 JPEG"
            )
        }
        if let headroom=SafeExportResolution.currentProcessHeadroom() {
            guard headroom>0,estimate<=headroom/100*70 else {
                throw Failure.invalid(
                    "RAW Float32 当前可用进程内存不足，保留原 DNG 及 Apple RAW 冲印"
                )
            }
        }
        guard let extended=CGColorSpace(name:CGColorSpace.extendedSRGB)
        else {
            throw Failure.invalid("设备没有扩展 sRGB 色彩空间")
        }
        let normalized=rawImage
            .transformed(by:CGAffineTransform(
                translationX:-bounds.minX,y:-bounds.minY
            ))
            .cropped(to:CGRect(x:0,y:0,width:w,height:h))
        let context=CIContext(options:[.cacheIntermediates:false])
        let file=FileManager.default.temporaryDirectory
            .appendingPathComponent("SF-AppleRAW-Float32-"+UUID().uuidString)
            .appendingPathExtension("tiff")
        defer {try? FileManager.default.removeItem(at:file)}
        do {
            // RGBAf = IEEE754 Float32 PER component, not RGBA8/16.
            // The color-managed conversion targets explicit extended sRGB
            // because Build78 refuses extended-LINEAR TIFF as encoded RGB.
            try context.writeTIFFRepresentation(
                of:normalized,to:file,format:.RGBAf,
                colorSpace:extended,options:[:]
            )
            let bytes=try Data(contentsOf:file)
            guard bytes.count>0,
                  bytes.count <= 16_000_000*4*4+8_000_000 else {
                throw Failure.invalid(
                    "RAW Float32 TIFF 大小异常或超过认证容量，拒绝输入"
                )
            }
            let profile=Build111PhotoInputProfile.inspect(
                bytes,entry:.converted
            )
            guard profile.directCompatible,
                  profile.format=="TIFF",profile.width==w,
                  profile.height==h,profile.declaredDepth==32,
                  profile.decodedDepth==32,profile.floatingComponents,
                  profile.color == .extendedSRGB else {
                throw Failure.invalid(
                    "Apple RAW 浮点 TIFF 没有通过 Build78/111 真实位深、" +
                    "色彩空间和图像尺寸检查：" +
                    profile.summary+"；"+profile.reason+
                    "。拒绝冒充 Float32 或自动改为 8-bit"
                )
            }
            return Result(bytes:bytes,admission:profile)
        } catch {
            throw Failure.invalid(
                "Apple RAW→Float32 TIFF 失败（无 JPEG 降级）：" +
                error.localizedDescription
            )
        }
    }
}
