import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Build78/07: IEEE754 binary16/binary32 TIFF ingress from the ORIGINAL
/// ImageIO bitmap provider into the physical Float64 RGB pipeline.
///
/// Reads the file's *decoded* floating component bits. Never runs CIImage, Quartz
/// RGBA8, gamut mapping, CCTF, clipping or tonemapping.
/// Values < 0 and > 1 are deliberately preserved. Only finite RGB is
/// accepted; alpha, orientation, source profile and layout are checked.
/// The original Python default ProPhoto RGB contract is a SEPARATE stage.
enum Build78FloatTIFFIngress {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let reason)=self { return reason }
            return nil
        }
    }

    static func decode(
        source:CGImageSource,image:CGImage,
        previewMaxSide:Int?,
        resizedTo:(width:Int,height:Int)?,
        maximumAllowedPixels:Int
    ) throws -> OriginalSourcePixelIO.Frame {
        guard let uti=CGImageSourceGetType(source),
              UTType(uti as String)?.conforms(to:.tiff)==true else {
            throw Failure.invalid(
                "Build78 浮点精确读取目前仅接受 TIFF，不会把 EXR/RAW 冒充 TIFF"
            )
        }
        guard resizedTo == nil else {
            throw Failure.invalid(
                "Build78 Float32 TIFF 原版三次插值缩放尚未完成数值验证；禁止自动插值"
            )
        }
        guard (image.bitsPerComponent==16 || image.bitsPerComponent==32),
              image.bitmapInfo.contains(.floatComponents) else {
            throw Failure.invalid(
                "Build78 TIFF 不是可验证的 IEEE754 Float16/Float32 通道"
            )
        }
        // Build129: iOS 16.5.1 sometimes exposes an explicitly
        // color-managed RGBAf TIFF as *standard* sRGB after ImageIO.
        // The proof is its real TIFF container, IEEE Float32 bitmap
        // samples, and CFEqual-decoded ICC profile. Accept standard sRGB
        // ONLY for Float32; Float16 remains extended sRGB only.
        // Neither path re-tags bytes, clips out-of-range values, converts
        // ICC, or treats P3/untagged/extended-linear as encoded sRGB.
        guard let colour=image.colorSpace,colour.model == .rgb,
              let extended=CGColorSpace(name:CGColorSpace.extendedSRGB),
              let srgb=CGColorSpace(name:CGColorSpace.sRGB),
              (CFEqual(colour,extended) ||
               (image.bitsPerComponent==32 && CFEqual(colour,srgb))) else {
            throw Failure.invalid(
                "Build78 Float32 TIFF 必须真实标注 sRGB 或 extended sRGB；"
                + "Float16 只接受 extended sRGB，未标记/P3/extended-linear 拒绝"
            )
        }
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:image.width,height:image.height,
            maximumAllowedPixels:maximumAllowedPixels
        )
        let exif=OriginalSourcePixelIO.orientation(source)
        guard (1...8).contains(exif) else {
            throw Failure.invalid("Build78 TIFF 浮点 EXIF 方向非法")
        }
        let channels:Int
        let alphaIndex:Int?
        switch image.alphaInfo {
        case .none:
            channels=3
            alphaIndex=nil
        case .noneSkipLast, .last, .premultipliedLast:
            channels=4
            alphaIndex=3
        case .noneSkipFirst, .first, .premultipliedFirst:
            channels=4
            alphaIndex=0
        default:
            throw Failure.invalid("Build78 Float32 TIFF Alpha 排列未被支持")
        }
        let sampleBytes=image.bitsPerComponent/8
        guard image.bitsPerPixel==channels*image.bitsPerComponent,
              image.bytesPerRow>=image.width*channels*sampleBytes else {
            throw Failure.invalid("Build78 Float32 TIFF 位宽与行跨距不一致")
        }
        let byteOrder=image.bitmapInfo.rawValue &
            CGBitmapInfo.byteOrderMask.rawValue
        let little=byteOrder == (sampleBytes==2
            ? CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder32Little.rawValue)
        let big=byteOrder == (sampleBytes==2
            ? CGBitmapInfo.byteOrder16Big.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue)
        guard little || big else {
            throw Failure.invalid("Build78 Float32 TIFF 字节序未指定")
        }
        guard let provider=image.dataProvider,
              let data=provider.data as Data? else {
            throw Failure.invalid("Build78 Float32 TIFF 原始位图 provider 不存在")
        }
        let lastRow=(image.height-1)*image.bytesPerRow
        guard data.count>=lastRow+image.width*channels*sampleBytes else {
            throw Failure.invalid("Build78 Float32 TIFF 原始像素字节不足")
        }
        let side=max(image.width,image.height)
        let maxSide=previewMaxSide ?? side
        guard maxSide>0 else {
            throw Failure.invalid("Build78 Float32 TIFF 预览长度必须为正")
        }
        let scale=min(1.0,Double(maxSide)/Double(side))
        let w=max(1,Int((Double(image.width)*scale).rounded()))
        let h=max(1,Int((Double(image.height)*scale).rounded()))
        let swap=exif>=5
        let outW=swap ? h : w
        let outH=swap ? w : h
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:outW,height:outH,
            maximumAllowedPixels:maximumAllowedPixels
        )
        var rgb=[Double](repeating:0,count:outW*outH*3)
        try data.withUnsafeBytes { bytes in
            guard let p=bytes.baseAddress?.assumingMemoryBound(to:UInt8.self)
            else { throw Failure.invalid("Build78 Float32 TIFF 没有可读取数据") }
            func readFloat(_ off:Int) -> Double {
                if sampleBytes==2 {
                    let raw:UInt16 = little
                        ? (UInt16(p[off]) | (UInt16(p[off+1]) << 8))
                        : ((UInt16(p[off]) << 8) | UInt16(p[off+1]))
                    return Double(Float16(bitPattern:raw))
                }
                var raw:UInt32=0
                if little {
                    for i in 0..<4 { raw |= UInt32(p[off+i]) << (8*i) }
                } else {
                    for i in 0..<4 { raw=(raw<<8)|UInt32(p[off+i]) }
                }
                return Double(Float(bitPattern:raw))
            }
            for y in 0..<h {
                let sy=min(image.height-1,
                           Int((Double(y)+0.5)*Double(image.height)/Double(h)))
                for x in 0..<w {
                    let sx=min(image.width-1,
                               Int((Double(x)+0.5)*Double(image.width)/Double(w)))
                    let off=sy*image.bytesPerRow+sx*channels*sampleBytes
                    if let alphaIndex {
                        let alpha=readFloat(off+alphaIndex*sampleBytes)
                        guard alpha.isFinite,alpha==1.0 else {
                            throw Failure.invalid(
                                "Build78 Float32 TIFF 存在透明／非有限 Alpha；禁止预乘混色"
                            )
                        }
                    }
                    let dx:Int,dy:Int
                    switch exif {
                    case 2: dx=w-1-x; dy=y
                    case 3: dx=w-1-x; dy=h-1-y
                    case 4: dx=x; dy=h-1-y
                    case 5: dx=y; dy=x
                    case 6: dx=h-1-y; dy=x
                    case 7: dx=h-1-y; dy=w-1-x
                    case 8: dx=y; dy=w-1-x
                    default: dx=x; dy=y
                    }
                    let result=(dy*outW+dx)*3
                    let first=alphaIndex==0 ? 1 : 0
                    for c in 0..<3 {
                        let value=readFloat(off+(first+c)*sampleBytes)
                        guard value.isFinite else {
                            throw Failure.invalid(
                                "Build78 浮点 TIFF RGB 中存在 NaN/Inf；保留源数据但拒绝不确定显影"
                            )
                        }
                        rgb[result+c]=value
                    }
                }
            }
        }
        return OriginalSourcePixelIO.Frame(width:outW,height:outH,rgb:rgb)
    }
}
