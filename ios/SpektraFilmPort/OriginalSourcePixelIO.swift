import Foundation
import CoreGraphics
import CoreFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Experimental, explicitly selected 8-bit sRGB photo ingress -> original
/// source Double spatial DIR -> direct 8-bit JPEG/UIImage output. This path
/// does NOT execute a Core Image working buffer to read or encode pixels.
/// Supported scope deliberately excludes optical scatter, scanner post-FX,
/// density grain and RAW. Such requests must throw, never silently fall back.
enum OriginalSourcePixelIO {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    struct Frame {
        let width: Int
        let height: Int
        let rgb: [Double]
    }

    private static let srgb: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.sRGB)!
    }()

    private static func orientation(_ source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        let number = (properties as NSDictionary?)?[kCGImagePropertyOrientation]
            as? NSNumber
        return number?.intValue ?? 1
    }

    private static func requireExplicitSRGB(_ image: CGImage) throws {
        guard let colorSpace = image.colorSpace,
              colorSpace.model == .rgb,
              CFEqual(colorSpace, srgb) else {
            throw Failure.invalid(
                "原版像素直连只接受明确标记的 sRGB 8-bit RGB；" +
                "P3、灰度或未标记色彩空间禁止隐式转换"
            )
        }
    }

    /// Source imaging, not fabricated Float64 input: decode an actual
    /// 8-bit file using ImageIO/Quartz in 8-bit RGBA, then promote each
    /// encoded sRGB channel to Double. Avoids Core Image's tested RGBAh
    /// working buffer. 16-bit/HDR/RAW files are rejected for this path.
    static func decode(
        _ data: Data, previewMaxSide: Int? = nil,
        maximumAllowedPixels: Int = 16_000_000
    ) throws -> Frame {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(
                imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            throw Failure.invalid("原版像素直连：ImageIO 无法读取照片")
        }
        guard original.bitsPerComponent == 8 else {
            throw Failure.invalid(
                "原版像素直连只接受 8-bit JPEG/HEIC/PNG；高位深、RAW 不得降级到 8-bit"
            )
        }
        // Pixel-preserving mode must not quietly turn a Display P3, gray,
        // untagged, or other ICC profile into sRGB via CGContext.draw.
        // Such a conversion changes the algorithm's input values even
        // when every decoded channel is stored as Double afterward.
        try requireExplicitSRGB(original)
        let exif = orientation(imageSource)
        guard (1...8).contains(exif) else {
            throw Failure.invalid("原版像素直连：EXIF 方向无效")
        }
        let image: CGImage
        if let maxSide = previewMaxSide, maxSide > 0,
           max(original.width, original.height) > maxSide {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(
                imageSource, 0, options
            ), thumb.bitsPerComponent == 8 else {
                throw Failure.invalid("原版像素直连：无法生成 8-bit 预览缩略图")
            }
            image = thumb
        } else {
            image = original
        }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 8192, h <= 8192,
              w <= maximumAllowedPixels / h else {
            throw Failure.invalid(
                "原版像素直连超出当前内存安全范围（最大 1600 万像素）；禁止偷偷缩图"
            )
        }

        var bytes = [UInt8](repeating: 0, count: w*h*4)
        let succeeded = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w*4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard succeeded else {
            throw Failure.invalid("原版像素直连：sRGB RGBA8 Quartz 解码失败")
        }

        let swapsAxes = exif >= 5
        let outW = swapsAxes ? h : w
        let outH = swapsAxes ? w : h
        var output = [Double](repeating: 0, count: w*h*3)
        for y in 0..<h {
            for x in 0..<w {
                let from = (y*w+x)*4
                guard bytes[from+3] == 255 else {
                    throw Failure.invalid(
                        "原版像素直连仅支持不透明照片；检测到 alpha 混合"
                    )
                }
                // EXIF 1..8. Applies integer-only coordinate transforms;
                // no filtering, half precision or additional gamma stage.
                let dx: Int
                let dy: Int
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
                let to = (dy*outW+dx)*3
                output[to]=Double(bytes[from])/255.0
                output[to+1]=Double(bytes[from+1])/255.0
                output[to+2]=Double(bytes[from+2])/255.0
            }
        }
        return Frame(width:outW,height:outH,rgb:output)
    }

    /// Reuse the validated production LUT + inhibition + FIR/YVV routines,
    /// passing source pixels as Float64 arrays instead of reading CIImage.
    /// The CIImage below is geometry-only. Its pixels are never rendered;
    /// the "printed" Double stage is captured BEFORE CIImage creation.
    static func develop(_ frame: Frame,
                        stage: SpatialDIRStage,
                        settings: SpatialDIRSettings) throws -> Frame {
        guard settings.enabled && settings.sourceConvolutionEnabled,
              settings.valid, stage.valid else {
            throw Failure.invalid(
                "原版像素直连需要已启用的原版 DIR FIR/YVV 和实测显影数据"
            )
        }
        let bounds = CGRect(x: 0,y: 0,width: frame.width,height: frame.height)
        let geometry = CIImage(color: CIColor(red:0,green:0,blue:0))
            .cropped(to: bounds)
        var printed: [Double]?
        _ = try SourceSpatialDIRConvolution.applyExactImagePath(
            to: geometry, stage:stage, settings:settings,
            grain:nil, stageObserver:nil, sourceRGBOverride:frame.rgb,
            stageDoubleObserver: { name,pixels in
                if name == "printed" { printed = pixels }
            },
            suppressFinalCIImage:true
        )
        guard let pixels = printed, pixels.count == frame.width*frame.height*3,
              pixels.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("原版像素直连：Double 印相结果缺失或非有限")
        }
        return Frame(width:frame.width,height:frame.height,rgb:pixels)
    }

    /// 8-bit display encoding is explicit and unavoidable for JPEG.
    /// No Core Image interpolation or internal Float16 intermediate.
    static func displayImage(_ frame: Frame) throws -> CGImage {
        let w=frame.width, h=frame.height
        guard w>0,h>0,w<=8192,h<=8192,
              w<=16_000_000/h,frame.rgb.count==w*h*3 else {
            throw Failure.invalid("原版像素直连：显示缓冲区尺寸无效")
        }
        var rgba=[UInt8](repeating:255,count:w*h*4)
        for p in 0..<(w*h) {
            for ch in 0..<3 {
                let v=frame.rgb[p*3+ch]
                guard v.isFinite else {
                    throw Failure.invalid("原版像素直连：输出出现 NaN/Inf")
                }
                // Source output is display-referred sRGB, not scene linear.
                rgba[p*4+ch]=UInt8(
                    (min(1,max(0,v))*255.0).rounded(.toNearestOrEven)
                )
            }
        }
        let cfData=rgba.withUnsafeBytes { Data($0) } as CFData
        guard let provider=CGDataProvider(data:cfData),
              let cg=CGImage(
                width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:w*4,space:srgb,
                bitmapInfo:CGBitmapInfo(
                    rawValue:CGImageAlphaInfo.noneSkipLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider:provider,decode:nil,shouldInterpolate:false,
                intent:.defaultIntent
              ) else {
            throw Failure.invalid("原版像素直连：无法创建无 CI 显示图像")
        }
        return cg
    }

    /// Runs in GitHub's macOS native validation executable as well as on
    /// iPhone. One opaque lossless PNG ensures byte order and row orientation
    /// are not silently altered by the new ImageIO/Quartz transport.
    static func validate8BitRoundTrip() throws -> String {
        let w=3,h=2
        let bytes:[UInt8]=[
            19,41,83,255,  101,143,179,255,  217,233,247,255,
            251,71,37,255,  127,89,53,255,   11,5,239,255
        ]
        let frame=Frame(
            width:w,height:h,
            rgb:(0..<(w*h)).flatMap { pixel in
                (0..<3).map { Double(bytes[pixel*4+$0])/255.0 }
            }
        )
        let cg=try displayImage(frame)
        let url=FileManager.default.temporaryDirectory
            .appendingPathComponent("spektrafilm-source-rgba8-" + UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at:url) }
        guard let dest=CGImageDestinationCreateWithURL(
            url as CFURL,UTType.png.identifier as CFString,1,nil
        ) else {
            throw Failure.invalid("原版像素验证：无法创建 PNG 测试图")
        }
        CGImageDestinationAddImage(dest,cg,nil)
        guard CGImageDestinationFinalize(dest) else {
            throw Failure.invalid("原版像素验证：PNG 编码失败")
        }
        let observed=try decode(Data(contentsOf:url))
        guard observed.width==w,observed.height==h else {
            throw Failure.invalid("原版像素验证：PNG 行列尺寸改变")
        }
        for k in frame.rgb.indices {
            if abs(observed.rgb[k]-frame.rgb[k])>1e-12 {
                throw Failure.invalid(
                    "原版像素验证：RGBA8 无损往返改变方向/通道。" +
                    "index=\(k),source=\(frame.rgb[k]),decoded=\(observed.rgb[k])"
                )
            }
        }
        return "PASS: 原版输入/输出 ImageIO 3×2 RGBA8 六像素无损往返；" +
            "不经过 Core Image。8-bit 输入认证仅限该夹具。"
    }

    /// A genuine Display P3 PNG must fail rather than be colour-converted
    /// into a seemingly 'exact' source RGB array. This proves file ingress,
    /// not just an isolated helper predicate.
    static func validateColorProfileGate() throws -> String {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            throw Failure.invalid("色彩空间验证：无法创建 Display P3 profile")
        }
        let rgba: [UInt8] = [40, 110, 220, 255]
        let raw = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: raw),
              let image = CGImage(
                width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 4, space: p3,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.noneSkipLast.rawValue |
                        CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw Failure.invalid("色彩空间验证：无法构造 P3 测试图片")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spektrafilm-source-p3-" + UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw Failure.invalid("色彩空间验证：无法编码 P3 PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.invalid("色彩空间验证：写入 P3 PNG 失败")
        }
        do {
            _ = try decode(Data(contentsOf: url))
        } catch Failure.invalid(let message) {
            guard message.contains("sRGB") else {
                throw Failure.invalid(
                    "色彩空间验证：P3 输入被错误原因拒绝：" + message
                )
            }
            return "PASS: Display P3 8-bit PNG 明确拒绝；" +
                "精确模式不会隐式转换为 sRGB。"
        }
        throw Failure.invalid(
            "色彩空间验证失败：Display P3 PNG 被当作精确 sRGB 输入"
        )
    }

    #if canImport(UIKit)
    static func preview(_ data:Data,stage:SpatialDIRStage,
                        settings:SpatialDIRSettings) throws -> UIImage {
        let frame=try decode(data,previewMaxSide:1500)
        let developed=try develop(frame,stage:stage,settings:settings)
        return UIImage(cgImage:try displayImage(developed))
    }
    #endif

    static func createJPEG(_ frame:Frame) throws -> URL {
        let cg=try displayImage(frame)
        let url=FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraFilmPort-source-io-" + UUID().uuidString)
            .appendingPathExtension("jpg")
        guard let destination=CGImageDestinationCreateWithURL(
            url as CFURL,UTType.jpeg.identifier as CFString,1,nil
        ) else {
            throw Failure.invalid("原版像素直连：无法创建 JPEG 目标")
        }
        CGImageDestinationAddImage(
            destination,cg,
            [kCGImageDestinationLossyCompressionQuality as String:0.98]
                as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.invalid("原版像素直连：高清 JPEG 写入失败")
        }
        return url
    }

    static func exportJPEG(_ data:Data,stage:SpatialDIRStage,
                           settings:SpatialDIRSettings) throws -> URL {
        let frame=try decode(data)
        let developed=try develop(frame,stage:stage,settings:settings)
        return try createJPEG(developed)
    }
}
