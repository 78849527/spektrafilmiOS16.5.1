import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Build128, explicitly user-selected precision bridge:
/// actual Apple CIRAWFilter developed pixels -> IEEE Float32 TIFF.
/// Request extended-sRGB rendering, then inspect the REAL file profile:
/// iOS may report sRGB or extended-sRGB. Both have separately validated
/// float-only admission; no fabricated extended label or implicit JPEG8.
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
        let headroom=SafeExportResolution.currentProcessHeadroom()
            ?? ProcessInfo.processInfo.physicalMemory/3
        guard headroom>0,estimate<=headroom/100*70 else {
            throw Failure.invalid(
                "RAW Float32 预计使用 " + String(estimate/1_000_000) +
                "MB，当前可分配 " + String(headroom/1_000_000) +
                "MB；需要 30% 安全余量，DNG 不变，不转 JPEG"
            )
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
            // The renderer requests encoded extended-sRGB. ImageIO on
            // iOS16.5.1 may expose its actual TIFF profile as sRGB.
            // Build129 admits both ONLY if real IEEE Float32 + ICC
            // verification passes; it never rewrites TIFF profile tags.
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
                  (profile.color == .extendedSRGB ||
                   profile.color == .sRGB) else {
                throw Failure.invalid(
                    "Apple RAW 浮点 TIFF 没有通过 Build78/111 真实位深、" +
                    "色彩空间和图像尺寸检查：" +
                    profile.summary+"；"+profile.reason +
                    "；Float32标志="+String(profile.floatingComponents) +
                    "；实际ICC="+(profile.exactColorName ?? "无") +
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
