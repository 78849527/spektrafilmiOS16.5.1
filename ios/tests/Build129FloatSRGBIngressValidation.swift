import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Build129 macOS real-file fixture. Standalone small stubs expose ONLY
/// the common production Build78/111/128 types needed for I/O verification.
enum SafeExportResolution {
    static func currentProcessHeadroom() -> UInt64? { nil }
}
enum OriginalSourcePixelIO {
    struct Frame {
        let width:Int
        let height:Int
        let rgb:[Double]
    }
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let s)=self{return s}
            return nil
        }
    }
    static func validatePixelDimensions(
        width:Int,height:Int,maximumAllowedPixels:Int
    ) throws {
        guard width>0,height>0,width<=8192,height<=8192,
              width<=maximumAllowedPixels/height else {
            throw Failure.invalid("非法尺寸或高位深内存上限")
        }
    }
    static func orientation(_ src:CGImageSource)->Int {
        let p=CGImageSourceCopyPropertiesAtIndex(src,0,nil)
            as? [String:Any]
        return (p?[kCGImagePropertyOrientation as String] as? Int) ?? 1
    }
    static func decode(_ bytes:Data) throws -> Frame {
        guard let src=CGImageSourceCreateWithData(bytes as CFData,nil),
              let image=CGImageSourceCreateImageAtIndex(src,0,nil) else {
            throw Failure.invalid("真实 TIFF ImageIO 解码失败")
        }
        return try Build78FloatTIFFIngress.decode(
            source:src,image:image,previewMaxSide:nil,
            resizedTo:nil,maximumAllowedPixels:16_000_000
        )
    }
}
@main
enum Build129FloatSRGBIngressValidation {
    static func require(_ ok:Bool,_ message:String) throws {
        guard ok else {
            throw OriginalSourcePixelIO.Failure.invalid(message)
        }
    }
    /// Exact Float32 transport, not global remapping: retain negative and
    /// superwhite samples for the original spectral model's stage rules.
    static func verifyUnchangedFloatValues() throws {
        let sample:[Float] = [
            -0.25, 0.375, 1.5, 1.0,
            0.0,   0.50,  2.25, 1.0,
            0.875, 1.25, -0.125,1.0,
            1.0,   0.25,  0.375,1.0,
            0.125, 0.375, 0.625,1.0,
            1.25,  0.75,  1.5,  1.0
        ]
        var raw=Data()
        for value in sample {
            let bits=value.bitPattern
            for byte in 0..<4 {
                raw.append(UInt8(truncatingIfNeeded:bits >> (byte*8)))
            }
        }
        guard let srgb=CGColorSpace(name:CGColorSpace.sRGB),
              let provider=CGDataProvider(data:raw as CFData),
              let image=CGImage(
                  width:3,height:2,bitsPerComponent:32,bitsPerPixel:128,
                  bytesPerRow:48,space:srgb,
                  bitmapInfo:CGBitmapInfo(rawValue:
                      CGBitmapInfo.floatComponents.rawValue |
                      CGBitmapInfo.byteOrder32Little.rawValue |
                      CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider:provider,decode:nil,
                  shouldInterpolate:false,intent:.defaultIntent
              ) else {
            throw OriginalSourcePixelIO.Failure.invalid(
                "无法创建真实 Float32 超范围 RGB 测试图")
        }
        let buffer=NSMutableData()
        guard let dst=CGImageDestinationCreateWithData(
            buffer as CFMutableData,UTType.tiff.identifier as CFString,1,nil
        ) else {
            throw OriginalSourcePixelIO.Failure.invalid("TIFF writer unavailable")
        }
        CGImageDestinationAddImage(dst,image,nil)
        try require(CGImageDestinationFinalize(dst),
                    "无法编码真实 Float32 范围测试图")
        let data=buffer as Data
        let profile=Build111PhotoInputProfile.inspect(data,entry:.converted)
        try require(profile.directCompatible && profile.decodedDepth==32 &&
                    profile.floatingComponents,"Float32 TIFF ICC/位深不合格")
        let before=try OriginalSourcePixelIO.decode(data)
        try require(before.rgb.count==18,"Float32 RGB 实测通道数错误")
        for index in 0..<6 {
            for channel in 0..<3 {
                let expected=Double(sample[index*4+channel])
                let got=before.rgb[index*3+channel]
                try require(got==expected,
                            "Float32 RGB 通道被裁切或重映射："+String(index)+"/"+String(channel))
            }
        }
        try require(before.rgb.contains(where:{$0<0}) &&
                    before.rgb.contains(where:{$0>1}),
                    "Float32 负值与超白输入未原样保留")
        print("PASS unaltered real TIFF32 negative/superwhite RGB → Float64 " +
              "without remapping, clipping, JPEG8 or gamut relabel")
    }
    static func main() throws {
        try verifyUnchangedFloatValues()
        let bounds=CGRect(x:0,y:0,width:8,height:6)
        let input=CIImage(
            color:CIColor(red:0.1234567,green:0.3456789,blue:0.87654321)
        ).cropped(to:bounds)
        // Exercise the actual Build128 exporter and admission, no surrogate
        // JPEG or synthetic Inspection replacing a real file.
        let actual=try Build128RAWFloat32Transport.makeVerifiedCopy(input)
        try require(actual.admission.directCompatible,
                    "真实 RGBAf TIFF 被错误拒绝")
        try require(actual.admission.declaredDepth==32 &&
                    actual.admission.decodedDepth==32 &&
                    actual.admission.floatingComponents,
                    "真实 TIFF 位深不是 IEEE754 Float32")
        try require(actual.admission.color == .sRGB ||
                    actual.admission.color == .extendedSRGB,
                    "未知/未标记 ICC 被当作 sRGB")
        let frame=try OriginalSourcePixelIO.decode(actual.bytes)
        try require(frame.width==8 && frame.height==6 &&
                    frame.rgb.count==8*6*3,
                    "Build78 浮点原版输入整帧没有按真实尺寸读取")
        try require(frame.rgb.allSatisfy({$0.isFinite}),
                    "输入出现 NaN/Inf")
        // Explicit sRGB Float32 is newly accepted. All other unsupported
        // combinations continue to fail, including same 32bpc integer,
        // float16 regular sRGB and P3 Float32.
        func inspection(_ kind:Build111PhotoInputProfile.ColorKind,
                        _ bits:Int,_ floating:Bool)
        -> Build111PhotoInputProfile.Inspection {
            .init(entry:.converted,format:"TIFF",width:8,height:6,
                  declaredDepth:bits,decodedDepth:bits,color:kind,
                  exactColorName:nil,hasAlphaChannel:false,
                  floatingComponents:floating,imageIOUsable:true,
                  failureReason:nil)
        }
        try require(inspection(.sRGB,32,true).directCompatible,
                    "Float32 sRGB 应独立准入")
        try require(inspection(.extendedSRGB,32,true).directCompatible,
                    "Float32 extended sRGB 旧功能被误删")
        try require(!inspection(.displayP3,32,true).directCompatible,
                    "P3 Float32 不允许静默当作 sRGB")
        try require(!inspection(.untagged,32,true).directCompatible,
                    "未标记 Float32 不允许直接通过")
        try require(!inspection(.sRGB,32,false).directCompatible,
                    "整数32不能冒充 Float32")
        try require(!inspection(.sRGB,16,true).directCompatible,
                    "Float16 标准 sRGB 尚未认证")
        try require(inspection(.sRGB,8,false).directCompatible,
                    "既有 JPEG8 sRGB 不应被误拒绝")
        try require(inspection(.sRGB,16,false).directCompatible,
                    "既有 sRGB 整数16 TIFF 不应回退")
        print("PASS Build129 real CI RGBAf TIFF → actual " +
              actual.admission.color.rawValue +
              " ICC/Float32 8×6 ImageIO → Build78 CPU Double;" +
              " negative P3/untagged/uint32/Float16 checks, legacy paths.")
        print("NOT CERTIFIED: iOS16.5.1 CIRAWFilter exact camera DNG " +
              "ICC handling or source Python rawpy numerical equivalence.")
    }
}
