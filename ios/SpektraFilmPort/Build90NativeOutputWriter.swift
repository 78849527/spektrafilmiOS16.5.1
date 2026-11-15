import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Original numeric i/o path written as native ImageIO files. The source
/// original binary ICC bytes are generated separately from pinned io.py.
/// This is opt-in and intentionally leaves the existing 98% JPEG export,
/// Photos and Files presentation exactly as they were.
/// EXR is fail-closed until verified real OpenEXR encoder is linked.
enum Build90NativeOutputWriter {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self{return s}
            return nil
        }
    }
    struct Options {
        let format:Build90SourceOutputQuantization.FileFormat
        let bitDepth:Int
        let outputSpace:String
        let cctfEncoded:Bool
        let sourceImageData:Data?
        init(
            format:Build90SourceOutputQuantization.FileFormat,
            bitDepth:Int,
            outputSpace:String="sRGB",cctfEncoded:Bool=true,
            sourceImageData:Data?=nil
        ) {
            self.format=format;self.bitDepth=bitDepth
            self.outputSpace=outputSpace
            self.cctfEncoded=cctfEncoded
            self.sourceImageData=sourceImageData
        }
    }
    static func write(
        width w:Int,height h:Int,rgb:[Double],
        options:Options
    ) throws->URL {
        guard w>0,h>0,w<=8192,h<=8192,
              w<=16_000_000/h,
              rgb.count==w*h*3,
              rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "原版文件导出尺寸/Float64 输入无效，禁止自动缩图或降位深"
            )
        }
        let spec=try Build90SourceOutputQuantization.Specification(
            format:options.format,bitDepth:options.bitDepth
        )
        guard options.format != .exr else {
            throw Failure.invalid(
                "原版 EXR Float16/32 已移植数值转换；iOS 原生 EXR " +
                "编码器尚未验证，不允许将 TIFF/JPEG 改名为 .exr"
            )
        }
        guard let icc=Build90GeneratedSourceICC.exactProfile(
                  space:options.outputSpace,encoded:options.cctfEncoded
              ),let cs=Build90GeneratedSourceICC.exactCGColorSpace(
                  space:options.outputSpace,encoded:options.cctfEncoded
              ) else {
            throw Failure.invalid(
                "找不到原版完整 ICC（\(options.outputSpace), " +
                "\(options.cctfEncoded ? "encoded":"linear")）；" +
                "不能用 Apple 通用 profile 代替或假冒 sRGB"
            )
        }
        let bytes=try Build90SourceOutputQuantization.packed(
            rgb,as:spec
        )
        let bits=spec.storage.bitsPerChannel
        let bitmap:CGBitmapInfo
        switch spec.storage {
        case .uint8:
            bitmap=CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue)
        case .uint16:
            bitmap=CGBitmapInfo(rawValue:
                CGImageAlphaInfo.none.rawValue |
                CGBitmapInfo.byteOrder16Big.rawValue)
        case .float32:
            bitmap=CGBitmapInfo(rawValue:
                CGImageAlphaInfo.none.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue |
                CGBitmapInfo.floatComponents.rawValue)
        case .float16:
            throw Failure.invalid(
                "EXR half 只允许真实 OpenEXR 编码器，禁止 16-bit TIFF 冒充"
            )
        }
        guard let provider=CGDataProvider(data:bytes as CFData),
              let cg=CGImage(
                  width:w,height:h,
                  bitsPerComponent:bits,bitsPerPixel:bits*3,
                  bytesPerRow:w*3*(bits/8),
                  space:cs,bitmapInfo:bitmap,
                  provider:provider,decode:nil,
                  shouldInterpolate:false,intent:.defaultIntent
              ) else {
            throw Failure.invalid(
                "源 ICC+位深的 RGB CGImage 不受当前 ImageIO 支持；" +
                "禁止把 F32/16bit 偷换 RGBA8"
            )
        }

        // Preserve source EXIF + IPTC dictionaries when ImageIO exposes
        // them. The original Exiv2 XMP path is separate: do NOT claim
        // full raw-XMP preservation until a separate end-to-end test.
        var properties=[String:Any]()
        if let src=options.sourceImageData,
           let image=CGImageSourceCreateWithData(src as CFData,nil),
           let original=CGImageSourceCopyPropertiesAtIndex(image,0,nil)
                as? [String:Any] {
            for key in [
                kCGImagePropertyExifDictionary as String,
                kCGImagePropertyIPTCDictionary as String,
                kCGImagePropertyGPSDictionary as String
            ] {
                if let value=original[key] {
                    properties[key]=value
                }
            }
        }
        var exif=(properties[
            kCGImagePropertyExifDictionary as String
        ] as? [String:Any]) ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String]=w
        exif[kCGImagePropertyExifPixelYDimension as String]=h
        exif[kCGImagePropertyExifColorSpace as String]=(
            options.outputSpace=="sRGB" && options.cctfEncoded
        ) ? 1:65535
        properties[kCGImagePropertyExifDictionary as String]=exif
        properties[kCGImagePropertyOrientation as String]=1
        properties[kCGImagePropertyTIFFDictionary as String]=[
            kCGImagePropertyTIFFSoftware as String:"spektrafilm"
        ]
        if options.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality as String]=0.98
        }
        let suffix=options.cctfEncoded ? "":" (linear)"
        let profileName=options.outputSpace+suffix
        properties[kCGImagePropertyProfileName as String]=profileName
        let type:CFString
        switch options.format {
        case .jpeg:type=UTType.jpeg.identifier as CFString
        case .png:type=UTType.png.identifier as CFString
        case .tiff:type=UTType.tiff.identifier as CFString
        case .exr:
            throw Failure.invalid("EXR codec unverified")
        }
        let url=FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SpektraFilm-original-output-"+UUID().uuidString
            ).appendingPathExtension(options.format.extensionName)
        do {
            guard let dest=CGImageDestinationCreateWithURL(
                url as CFURL,type,1,nil
            ) else {
                throw Failure.invalid(
                    "此 iOS 运行时 ImageIO 无法创建目标文件格式"
                )
            }
            CGImageDestinationAddImage(dest,cg,properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw Failure.invalid(
                    "原版文件编码失败；不能将目标格式偷换为 JPEG"
                )
            }
            // Verify that this is a genuine native file of the
            // REQUESTED depth and the REQUESTED SOURCE ICC.
            let data=try Data(contentsOf:url)
            guard let src=CGImageSourceCreateWithData(data as CFData,nil),
                  let saved=CGImageSourceCreateImageAtIndex(src,0,nil),
                  saved.width==w,saved.height==h,
                  saved.bitsPerComponent==bits else {
                throw Failure.invalid(
                    "文件写入后位深/尺寸不符：禁止提交假 16/32bit 文件"
                )
            }
            if spec.storage == .float32 &&
               !saved.bitmapInfo.contains(.floatComponents) {
                throw Failure.invalid(
                    "TIFF F32 在 ImageIO 往返中被转换为整数/半精度"
                )
            }
            guard let embeddedSpace=saved.colorSpace,
                  let rawICC=embeddedSpace.copyICCData() else {
                throw Failure.invalid("编码文件缺少可读取的 ICC")
            }
            let savedICC=rawICC as Data
            if savedICC != icc {
                let created=cs.copyICCData() as Data?
                let count=min(savedICC.count,icc.count)
                let first=(0..<count).first(where:{
                    savedICC[$0] != icc[$0]
                }) ?? count
                let createdEqual=(created==icc)
                throw Failure.invalid(
                    "实际文件 ICC 字节变化：source=\(icc.count) " +
                    "read=\(savedICC.count) " +
                    "firstDiff=\(first) sourceColorSpacePreserved=\(createdEqual); " +
                    "不能宣称原始 ICC 完全一致"
                )
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at:url)
            throw error
        }
    }
}
