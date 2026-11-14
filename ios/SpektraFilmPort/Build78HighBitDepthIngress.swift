import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Build78/07: strict 16-bit *integer* sRGB PNG/TIFF ingress into the
/// production OriginalSourcePixelIO.Frame (RGB Float64).
///
/// No Core Image, RGBA8 CGContext, Float16 or RGB LUT between ImageIO's
/// decoded 16-bit bitmap provider and the source physical renderer.
/// Source 16-bit integer values are retained as Double(x)/65535.0.
/// Float TIFF, untagged/P3 ICC, RAW, transparent pixels and unsupported
/// bitmap packing are explicitly rejected; never quietly demote to 8-bit.
enum Build78HighBitDepthIngress {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    static func decode(
        source: CGImageSource,
        image: CGImage,
        previewMaxSide: Int?,
        resizedTo: (width:Int,height:Int)?,
        maximumAllowedPixels: Int
    ) throws -> OriginalSourcePixelIO.Frame {
        guard let sourceType=CGImageSourceGetType(source),
              let uti=UTType(sourceType as String),
              uti.conforms(to:.png) || uti.conforms(to:.tiff) else {
            throw Failure.invalid(
                "Build78 16-bit 原版像素入口目前只接受 PNG/TIFF，其他格式禁止自动降位深"
            )
        }
        guard resizedTo == nil else {
            throw Failure.invalid(
                "Build78 16-bit 精确输入尚不支持导出缩放："
                + "必须先完成原版 skimage resize 数值等价，不能替换成 Quartz 插值"
            )
        }
        guard image.bitsPerComponent == 16,
              !image.bitmapInfo.contains(.floatComponents) else {
            throw Failure.invalid(
                "Build78 输入必须为整数 RGB 16-bit；Float16/Float32 "
                + "TIFF 需单独实现浮点读取，不允许转为 UInt16"
            )
        }
        try OriginalSourcePixelIO.requireExplicitSRGB(image)
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:image.width,height:image.height,
            maximumAllowedPixels:maximumAllowedPixels
        )
        let orientation=OriginalSourcePixelIO.orientation(source)
        guard (1...8).contains(orientation) else {
            throw Failure.invalid("Build78 16-bit 输入 EXIF 方向无效")
        }
        let channels:Int
        let alphaOffset:Int?
        switch image.alphaInfo {
        case .none:
            channels=3
            alphaOffset=nil
        case .noneSkipLast, .last, .premultipliedLast:
            channels=4
            alphaOffset=3
        case .noneSkipFirst, .first, .premultipliedFirst:
            channels=4
            alphaOffset=0
        default:
            throw Failure.invalid(
                "Build78 16-bit 不支持此 Alpha 布局，禁止混合像素"
            )
        }
        guard image.bitsPerPixel == channels*16,
              image.bytesPerRow >= image.width*channels*2 else {
            throw Failure.invalid(
                "Build78 16-bit ImageIO RGB 通道布局不明确，禁止解释为 8-bit"
            )
        }
        let mode=image.bitmapInfo.rawValue &
            CGBitmapInfo.byteOrderMask.rawValue
        let little=mode==CGBitmapInfo.byteOrder16Little.rawValue
        let big=mode==CGBitmapInfo.byteOrder16Big.rawValue
        guard little || big else {
            throw Failure.invalid(
                "Build78 16-bit 像素字节序没有明确声明，拒绝猜测 PNG/TIFF 端序"
            )
        }
        guard let provider=image.dataProvider,
              let data=provider.data as Data? else {
            throw Failure.invalid("Build78 ImageIO 16-bit bitmap provider 缺失")
        }
        let required=(image.height-1)*image.bytesPerRow +
            image.width*channels*2
        guard data.count>=required else {
            throw Failure.invalid("Build78 16-bit provider 字节数不足")
        }

        // Preview is an explicitly display-only nearest-neighbor sample
        // of the same 16-bit bitmap, never a replacement for full-res
        // original physical export or the original cubic resize contract.
        let maxSide=previewMaxSide ?? max(image.width,image.height)
        guard maxSide>0 else {
            throw Failure.invalid("Build78 16-bit 预览尺寸必须为正数")
        }
        let shrink=min(1.0,Double(maxSide)/Double(max(image.width,image.height)))
        let w=max(1,Int((Double(image.width)*shrink).rounded()))
        let h=max(1,Int((Double(image.height)*shrink).rounded()))
        let swapAxes=orientation>=5
        let outW=swapAxes ? h : w
        let outH=swapAxes ? w : h
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:outW,height:outH,
            maximumAllowedPixels:maximumAllowedPixels
        )
        var result=[Double](repeating:0,count:outW*outH*3)
        try data.withUnsafeBytes { bytes in
            guard let pointer=bytes.baseAddress?
                .assumingMemoryBound(to:UInt8.self) else {
                throw Failure.invalid("Build78 16-bit 解码缓冲区为空")
            }
            func read16(_ offset:Int) -> UInt16 {
                let one=UInt16(pointer[offset])
                let two=UInt16(pointer[offset+1])
                return little ? (one | (two << 8)) : ((one << 8) | two)
            }
            for y in 0..<h {
                // Center-aligned nearest input sample; no spatial
                // interpolation, gamma conversion or float quantization.
                let sy=min(image.height-1,
                           Int((Double(y)+0.5)*Double(image.height)/Double(h)))
                for x in 0..<w {
                    let sx=min(image.width-1,
                               Int((Double(x)+0.5)*Double(image.width)/Double(w)))
                    let offset=sy*image.bytesPerRow+sx*channels*2
                    if let alphaOffset {
                        guard read16(offset+alphaOffset*2)==65535 else {
                            throw Failure.invalid(
                                "Build78 16-bit Alpha 不透明性验证失败；禁止合成与丢弃 Alpha"
                            )
                        }
                    }
                    let channel0=alphaOffset == 0 ? 1 : 0
                    let dx:Int
                    let dy:Int
                    switch orientation {
                    case 2: dx=w-1-x; dy=y
                    case 3: dx=w-1-x; dy=h-1-y
                    case 4: dx=x; dy=h-1-y
                    case 5: dx=y; dy=x
                    case 6: dx=h-1-y; dy=x
                    case 7: dx=h-1-y; dy=w-1-x
                    case 8: dx=y; dy=w-1-x
                    default: dx=x; dy=y
                    }
                    let index=(dy*outW+dx)*3
                    for c in 0..<3 {
                        result[index+c]=
                            Double(read16(offset+(channel0+c)*2))/65535.0
                    }
                }
            }
        }
        return OriginalSourcePixelIO.Frame(
            width:outW,height:outH,rgb:result
        )
    }
}
