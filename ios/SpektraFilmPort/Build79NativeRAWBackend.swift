import Foundation
import CoreImage
import CoreGraphics

/// Build79/09: native Apple RAW decoder *capability probe*, never a
/// replacement for rawpy/LibRaw numeric equivalence.
///
/// An actual RAW filter is mandatory: CIImage(contentsOf:) and
/// CIImage(data:) may use the camera's embedded JPEG preview.
/// The output is rendered once at an interior pixel to prevent lazy
/// filter construction from masquerading as a working RAW backend.
/// This does NOT make the image available to original physical mode:
/// iOS RAW demosaic / profile / WB / lens / source ACES comparison is
/// scheduled for Build80/10-12.
enum Build79NativeRAWBackend {
    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription:String? {
            if case .unsupported(let message)=self { return message }
            return nil
        }
    }
    struct Assessment {
        let format:Build79RAWSignature.Kind
        let dimensions:(width:Int,height:Int)
        let firstRenderedPixel:[Float]
        let decoder:String
        let exactSourceParity:Bool
    }

    static func probe(_ url:URL) throws -> Assessment {
        guard let kind=try Build79RAWSignature.probeFile(url) else {
            throw Failure.unsupported("此文件没有受支持的相机 RAW 容器签名")
        }
        guard let raw=CIRAWFilter(imageURL:url),
              let output=raw.outputImage,
              !output.extent.isEmpty,
              output.extent.width.isFinite,
              output.extent.height.isFinite,
              output.extent.width>0,output.extent.height>0 else {
            throw Failure.unsupported(
                "Apple CIRAWFilter 无法解析当前 ." + kind.rawValue.uppercased()
                + " 或该机型/压缩方式；禁止使用内嵌 JPEG 预览冒充 RAW"
            )
        }
        // A small actual floating-point render verifies the RAW decode path.
        // It does not mean sensor data, color conversion or whole-frame
        // pixel values match Python's rawpy/LibRaw original.
        let extent=output.extent
        let center=CGRect(
            x:floor(extent.midX),y:floor(extent.midY),
            width:1,height:1
        )
        var pixel=[Float](repeating:0,count:4)
        let ci=CIContext(options:[.cacheIntermediates:false])
        pixel.withUnsafeMutableBytes { buffer in
            ci.render(
                output,
                toBitmap:buffer.baseAddress!,
                rowBytes:4*MemoryLayout<Float>.size,
                bounds:center,
                format:.RGBAf,
                colorSpace:nil
            )
        }
        guard pixel.allSatisfy({$0.isFinite}) else {
            throw Failure.unsupported(
                "Apple RAW 像素渲染产生 NaN/Inf，不能标记解码成功"
            )
        }
        return Assessment(
            format:kind,
            dimensions:(Int(extent.width),Int(extent.height)),
            firstRenderedPixel:pixel,
            decoder:"Apple Core Image CIRAWFilter (NOT Python rawpy)",
            exactSourceParity:false
        )
    }
}
