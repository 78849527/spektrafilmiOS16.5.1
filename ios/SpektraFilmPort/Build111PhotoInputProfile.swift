import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Build111: one file-level admission policy shared by Camera, Photos and
/// Files. No source film/print/scanner algorithm changes. Never infer sRGB
/// merely because a photo is 8-bit or JPEG.
enum Build111PhotoInputProfile {
    enum Entry:String {
        case camera = "App 拍摄"
        case album = "系统相册"
        case file = "文件导入"
        case converted = "用户明确转换"
    }
    enum ColorKind:String {
        case sRGB = "sRGB"
        case displayP3 = "Display P3"
        case extendedSRGB = "扩展 sRGB"
        case other = "其他 ICC 色彩空间"
        case untagged = "未标记色彩空间"
        case gray = "灰度/非 RGB"
    }
    struct Inspection {
        let entry:Entry
        let format:String
        let width:Int
        let height:Int
        let declaredDepth:Int
        let decodedDepth:Int
        let color:ColorKind
        let exactColorName:String?
        let hasAlphaChannel:Bool
        let floatingComponents:Bool
        let imageIOUsable:Bool
        let failureReason:String?

        var dimensions:String {"\(width)×\(height)"}
        var summary:String {
            let depth=declaredDepth>0 ? "\(declaredDepth)-bit" : "位深未知"
            return "\(entry.rawValue)｜\(format)｜\(depth)｜\(color.rawValue)｜\(dimensions)"
        }
        private var validDimensions:Bool {
            width>0 && height>0 && width<=8192 && height<=8192 &&
            Double(width)*Double(height)<=16_000_000
        }
        var directCompatible:Bool {
            guard failureReason == nil && imageIOUsable &&
                  validDimensions else {return false}
            // Preserve Build78 certified *transport* paths. This feature
            // must not regress previously available 16-bit sRGB PNG/TIFF
            // integer ingress or Float16/32 extended-sRGB TIFF ingress.
            if !floatingComponents && declaredDepth==8 &&
                decodedDepth==8 && color == .sRGB {
                return !hasAlphaChannel
            }
            if !floatingComponents && declaredDepth==16 &&
                decodedDepth==16 && color == .sRGB {
                return format == "PNG" || format == "TIFF"
            }
            if floatingComponents && (decodedDepth==16 ||
                decodedDepth==32) && color == .extendedSRGB {
                return format == "TIFF"
            }
            // Build129: iOS 16.5.1 ImageIO may report standard sRGB
            // for a genuine RGBAf TIFF produced with extended sRGB.
            // Accept ONLY TIFF with verified Float32 components and
            // a genuine decoded sRGB profile; never relabel P3 or RAW,
            // or treat integer 32-bit as floating-point RGB.
            if floatingComponents && declaredDepth==32 &&
                decodedDepth==32 && color == .sRGB {
                return format == "TIFF"
            }
            return false
        }
        var convertibleP3:Bool {
            failureReason==nil && imageIOUsable &&
            declaredDepth==8 && decodedDepth==8 &&
            color == .displayP3 && !hasAlphaChannel &&
            width>0 && height>0 &&
            width<=8192 && height<=8192 &&
            Double(width)*Double(height)<=16_000_000
        }
        var reason:String {
            if let failureReason {return failureReason}
            if !imageIOUsable {return "ImageIO 无法读取此照片"}
            if directCompatible {
                return "原版输入格式预检通过；高位深／Float32 仍按 Build78 原版通道校验，所有图像继续接受内存和处理参数检验。"
            }
            if declaredDepth != 8 || decodedDepth != 8 {
                return "该位深/色彩空间组合未通过已认证的原版输入路径；支持 16-bit sRGB PNG/TIFF、Float32 sRGB TIFF 和 extended-sRGB 浮点 TIFF。"
            }
            if width<=0 || height<=0 || width>8192 ||
                height>8192 || Double(width)*Double(height)>16_000_000 {
                return "原版像素直连只支持每边不超过 8192、总计最多 1600 万像素；全光学还有独立内存预算"
            }
            if hasAlphaChannel {return "检测到 Alpha 通道：无法预先保证全部像素不透明；此版原版入口暂禁用"}
            switch color {
            case .sRGB: return "已符合 8-bit sRGB 原版像素输入范围；后续仍须通过内存及光学参数校验"
            case .displayP3:
                return "这是一张 8-bit Display P3 照片。原版输入只接受 sRGB；可选择明确的 Apple ColorSync P3→sRGB 转换副本，原文件不修改。部分超出 sRGB 的颜色会压缩到 sRGB 范围；不是 Python 原版转换数值认证。"
            case .extendedSRGB:
                return "仅 Float16/Float32 TIFF 的原版浮点输入路径接受扩展 sRGB，其他情况不支持。"
            case .other:
                return "识别到其他 ICC 色彩空间；不允许悄悄改标签为 sRGB。此版不自动转换未知配置文件"
            case .untagged:
                return "缺少可验证的 ICC/sRGB 色彩标记，不能猜测为 sRGB"
            case .gray:
                return "原版像素直连仅接受 RGB 图像，不接受灰度或其他模型"
            }
        }
    }

    private static let srgb=CGColorSpace(name:CGColorSpace.sRGB)!
    private static let p3=CGColorSpace(name:CGColorSpace.displayP3)!
    private static let extended=CGColorSpace(name:CGColorSpace.extendedSRGB)!

    private static func kind(_ space:CGColorSpace?)->(ColorKind,String?) {
        guard let space else {return (.untagged,nil)}
        let name=space.name.map{String($0)}
        guard space.model == .rgb else {return (.gray,name)}
        if CFEqual(space,srgb) {return (.sRGB,name)}
        if CFEqual(space,p3) {return (.displayP3,name)}
        if CFEqual(space,extended) {return (.extendedSRGB,name)}
        // Never silently relax source CFEqual(sRGB) acceptance.
        return (.other,name)
    }
    private static func codec(_ type:CFString?)->String {
        guard let type else {return "UNKNOWN"}
        let value=(type as String).lowercased()
        if value.contains("heic") || value.contains("heif") {return "HEIC"}
        if value.contains("jpeg") || value.contains("jpg") {return "JPEG"}
        if value.contains("png") {return "PNG"}
        if value.contains("tiff") {return "TIFF"}
        return type as String
    }
    static func inspect(_ data:Data,entry:Entry)->Inspection {
        guard let imageSource=CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache:false] as CFDictionary
        ) else {
            return Inspection(entry:entry,format:"UNKNOWN",width:0,height:0,
                declaredDepth:0,decodedDepth:0,color:.untagged,
                exactColorName:nil,hasAlphaChannel:false,
                floatingComponents:false,imageIOUsable:false,
                failureReason:"ImageIO 无法识别文件")
        }
        let format=codec(CGImageSourceGetType(imageSource))
        let props=CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil)
            as NSDictionary?
        guard let image=CGImageSourceCreateImageAtIndex(
            imageSource,0,
            [kCGImageSourceShouldCacheImmediately:false] as CFDictionary
        ) else {
            let w=(props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let h=(props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            return Inspection(entry:entry,format:format,width:w,height:h,
                declaredDepth:(props?[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 0,
                decodedDepth:0,color:.untagged,exactColorName:nil,
                hasAlphaChannel:false,floatingComponents:false,
                imageIOUsable:false,
                failureReason:"ImageIO 无法解码原始图像")
        }
        let (color,name)=kind(image.colorSpace)
        let depth=(props?[kCGImagePropertyDepth] as? NSNumber)?.intValue
            ?? image.bitsPerComponent
        let alpha=image.alphaInfo
        let alphaChannel=alpha == .premultipliedFirst ||
            alpha == .premultipliedLast ||
            alpha == .first || alpha == .last ||
            alpha == .alphaOnly
        return Inspection(entry:entry,format:format,
            width:image.width,height:image.height,
            declaredDepth:depth,decodedDepth:image.bitsPerComponent,
            color:color,exactColorName:name,
            hasAlphaChannel:alphaChannel,
            floatingComponents:image.bitmapInfo.contains(.floatComponents),
            imageIOUsable:true,
            failureReason:nil)
    }

    /// Explicit user permission required. Copies Display-P3 source into
    /// an independently encoded sRGB JPEG. Original bytes are never edited.
    /// Quartz ColorSync converts actual channel values, not an ICC relabel.
    /// This colour-managed transport is NOT yet Python source full parity.
    static func convertP3ToSRGB(_ data:Data)throws->Data {
        let check=inspect(data,entry:.file)
        guard check.convertibleP3 else {
            throw NSError(domain:"Build111Input",code:1,userInfo:[
                NSLocalizedDescriptionKey:"不允许转换：\(check.summary)；\(check.reason)"
            ])
        }
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {
            throw NSError(domain:"Build111Input",code:2,userInfo:[
                NSLocalizedDescriptionKey:"无法读取 P3 原始文件"
            ])
        }
        // Check again after decode; never recast unrelated ICC data.
        guard kind(image.colorSpace).0 == .displayP3 else {
            throw NSError(domain:"Build111Input",code:3,userInfo:[
                NSLocalizedDescriptionKey:"P3 色彩标签与实际 ImageIO 图像不匹配"
            ])
        }
        let w=image.width,h=image.height
        guard w==check.width,h==check.height,
              Double(w)*Double(h)<=16_000_000 else {
            throw NSError(domain:"Build111Input",code:4,userInfo:[
                NSLocalizedDescriptionKey:"色彩转换尺寸验证失败"
            ])
        }
        let targetBytes=w*h*4
        var bytes=[UInt8](repeating:0,count:targetBytes)
        let output:CGImage?=bytes.withUnsafeMutableBytes { buffer in
            guard let ctx=CGContext(
                data:buffer.baseAddress,
                width:w,height:h,bitsPerComponent:8,
                bytesPerRow:w*4,space:srgb,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            ) else {return nil}
            ctx.setRenderingIntent(.relativeColorimetric)
            ctx.interpolationQuality = .none
            ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            return ctx.makeImage()
        }
        guard let output else {
            throw NSError(domain:"Build111Input",code:5,userInfo:[
                NSLocalizedDescriptionKey:"ColorSync sRGB 色彩转换缓冲区失败"
            ])
        }
        let rawProperties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)
            as NSDictionary?
        let orientation=(rawProperties?[kCGImagePropertyOrientation] as? NSNumber)?
            .intValue ?? 1
        guard (1...8).contains(orientation) else {
            throw NSError(domain:"Build111Input",code:6,userInfo:[
                NSLocalizedDescriptionKey:"不支持的原图 EXIF 方向"
            ])
        }
        let mutable=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(
            mutable,UTType.jpeg.identifier as CFString,1,nil
        ) else {
            throw NSError(domain:"Build111Input",code:7,userInfo:[
                NSLocalizedDescriptionKey:"无法生成独立 sRGB JPEG"
            ])
        }
        let options=[
            kCGImagePropertyOrientation:NSNumber(value:orientation),
            kCGImageDestinationLossyCompressionQuality:0.98
        ] as CFDictionary
        CGImageDestinationAddImage(dest,output,options)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain:"Build111Input",code:8,userInfo:[
                NSLocalizedDescriptionKey:"sRGB JPEG 编码失败，原图未修改"
            ])
        }
        let dataCopy=mutable as Data
        let after=inspect(dataCopy,entry:.converted)
        guard after.directCompatible && after.width==w &&
            after.height==h else {
            throw NSError(domain:"Build111Input",code:9,userInfo:[
                NSLocalizedDescriptionKey:"转换后 sRGB/8-bit 校验未通过，原图未修改：\(after.reason)"
            ])
        }
        return dataCopy
    }
}
