import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Explicit user-consented working COPY for float TIFF samples outside
/// the original optical model's encoded RGB [0, 1] domain.
///
/// This is a GLOBAL AFFINE gamut/range mapping, not a Python rawpy
/// reproduction, not equivalent to original input samples, not clamping,
/// and not the original optical algorithm. It preserves IEEE754 Float32
/// components and their channel ordering, without an 8-bit intermediate.
/// NEVER run implicitly in the photo importer or optical renderer.
enum Build130Float32RangeCopy {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let message)=self {return message}
            return nil
        }
    }
    struct Result {
        let bytes:Data
        let admission:Build111PhotoInputProfile.Inspection
        let sourceMinimum:Double
        let sourceMaximum:Double
        let outOfRangeComponents:Int
    }
    private struct Layout {
        let width:Int
        let height:Int
        let stride:Int
        let channels:Int
        let little:Bool
        let colorSpace:CGColorSpace
        let bitmapInfo:CGBitmapInfo
        let bitsPerPixel:Int
        let alpha:Int?
    }
    private struct Metrics {
        var minimum=Double.infinity
        var maximum = -Double.infinity
        var outOfRange=0
        var count=0
    }
    private static func layout(
        _ image:CGImage,_ src:CGImageSource,_ profile:Build111PhotoInputProfile.Inspection
    ) throws -> Layout {
        guard profile.directCompatible,
              profile.format=="TIFF",profile.floatingComponents,
              profile.declaredDepth==32,profile.decodedDepth==32,
              (profile.color == .sRGB || profile.color == .extendedSRGB),
              image.bitsPerComponent==32,
              image.bitmapInfo.contains(.floatComponents),
              let uti=CGImageSourceGetType(src),
              UTType(uti as String)?.conforms(to:.tiff)==true,
              let colorSpace=image.colorSpace,colorSpace.model == .rgb else {
            throw Failure.invalid("仅真实 IEEE754 Float32 sRGB/扩展sRGB TIFF 可进行明确范围映射")
        }
        guard OriginalSourcePixelIO.orientation(src)==1 else {
            throw Failure.invalid("Float32 范围映射不改变 EXIF 旋转；当前非方向1的照片拒绝映射")
        }
        let channels:Int
        let alpha:Int?
        switch image.alphaInfo {
        case .none:
            channels=3;alpha=nil
        case .noneSkipLast, .last, .premultipliedLast:
            channels=4;alpha=3
        case .noneSkipFirst, .first, .premultipliedFirst:
            channels=4;alpha=0
        default:
            throw Failure.invalid("Float32 TIFF Alpha 位置不可验证，拒绝隐式混色")
        }
        let order=image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        guard order==CGBitmapInfo.byteOrder32Little.rawValue ||
              order==CGBitmapInfo.byteOrder32Big.rawValue,
              image.bitsPerPixel==channels*32,
              image.bytesPerRow>=image.width*channels*4,
              image.width>0,image.height>0,
              image.width<=16_000_000/image.height else {
            throw Failure.invalid("Float32 TIFF 字节序、行跨度或像素数未获验证")
        }
        return Layout(width:image.width,height:image.height,
                      stride:image.bytesPerRow,channels:channels,
                      little:order==CGBitmapInfo.byteOrder32Little.rawValue,
                      colorSpace:colorSpace,bitmapInfo:image.bitmapInfo,
                      bitsPerPixel:image.bitsPerPixel,alpha:alpha)
    }
    private static func sample(_ p:UnsafePointer<UInt8>,_ offset:Int,_ little:Bool)->Float {
        var bits:UInt32=0
        if little {
            for i in 0..<4 {bits |= UInt32(p[offset+i]) << (8*i)}
        } else {
            for i in 0..<4 {bits=(bits<<8)|UInt32(p[offset+i])}
        }
        return Float(bitPattern:bits)
    }
    private static func store(_ p:UnsafeMutablePointer<UInt8>,
                              _ offset:Int,_ little:Bool,_ value:Float) {
        let bits=value.bitPattern
        for i in 0..<4 {
            let shift=little ? 8*i : 8*(3-i)
            p[offset+i]=UInt8(truncatingIfNeeded:bits >> shift)
        }
    }
    private static func scan(_ bytes:Data,_ layout:Layout)throws->Metrics {
        guard bytes.count>=(layout.height-1)*layout.stride +
              layout.width*layout.channels*4 else {
            throw Failure.invalid("Float32 TIFF 数据短于标注的行跨度")
        }
        return try bytes.withUnsafeBytes { raw -> Metrics in
            guard let p=raw.baseAddress?.assumingMemoryBound(to:UInt8.self) else {
                throw Failure.invalid("Float32 TIFF 没有真实像素数据")
            }
            var result=Metrics()
            let first=layout.alpha == 0 ? 1 : 0
            for y in 0..<layout.height {
                for x in 0..<layout.width {
                    let off=y*layout.stride+x*layout.channels*4
                    if let alpha=layout.alpha {
                        let a=sample(p,off+alpha*4,layout.little)
                        guard a.isFinite && a==1.0 else {
                            throw Failure.invalid("Float32 原片存在透明/非有限 alpha；禁止自动混色")
                        }
                    }
                    for c in 0..<3 {
                        let v=Double(sample(p,off+(first+c)*4,layout.little))
                        guard v.isFinite else {
                            throw Failure.invalid("Float32 RGB 存在 NaN/Inf；禁止范围映射")
                        }
                        result.minimum=min(result.minimum,v)
                        result.maximum=max(result.maximum,v)
                        if v<0 || v>1 {result.outOfRange+=1}
                        result.count+=1
                    }
                }
            }
            return result
        }
    }

    static func makeMappedWorkingCopy(_ input:Data)throws->Result {
        let profile=Build111PhotoInputProfile.inspect(input,entry:.converted)
        guard let source=CGImageSourceCreateWithData(
                input as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let image=CGImageSourceCreateImageAtIndex(source,0,nil),
              let provider=image.dataProvider,
              let data=provider.data as Data? else {
            throw Failure.invalid("Float32 TIFF 文件 ImageIO 解码失败")
        }
        let l=try layout(image,source,profile)
        let required=UInt64(l.width)*UInt64(l.height)*88+96_000_000
        let budget=min(1_500_000_000,ProcessInfo.processInfo.physicalMemory/3)
        guard required<=budget else {
            throw Failure.invalid("Float32 范围映射内存估算超过设备预算；保留原片")
        }
        if let headroom=SafeExportResolution.currentProcessHeadroom() {
            guard headroom>0,required<=headroom/100*80 else {
                throw Failure.invalid("Float32 范围映射进程内存不足；未修改任何原片")
            }
        }
        let m=try scan(data,l)
        guard m.outOfRange>0 else {
            throw Failure.invalid("Float32 TIFF 原版输入数值已在 0～1，不应做范围映射；应检查其他光学设置")
        }
        // A globally shared affine transform preserves channel order,
        // unlike per-channel min-max normalization. Epsilon reserves
        // headroom for IEEE754 Float32 encoder roundoff; no hard clamp.
        let bottom=min(0.0,m.minimum)
        let top=max(1.0,m.maximum)
        let margin=1.0/65536.0
        let scale=(1.0-2.0*margin)/(top-bottom)
        let bias=margin-bottom*scale
        guard scale.isFinite,scale>0,bias.isFinite else {
            throw Failure.invalid("Float32 范围映射系数非法")
        }
        var mapped=Data(data)
        try mapped.withUnsafeMutableBytes { raw in
            guard let p=raw.baseAddress?.assumingMemoryBound(to:UInt8.self) else {
                throw Failure.invalid("Float32 目标缓冲区无法创建")
            }
            let first=l.alpha == 0 ? 1 : 0
            for y in 0..<l.height {
                for x in 0..<l.width {
                    let off=y*l.stride+x*l.channels*4
                    for c in 0..<3 {
                        let pos=off+(first+c)*4
                        let original=Double(sample(
                            UnsafePointer(p),pos,l.little))
                        let transformed=Float(original*scale+bias)
                        guard transformed.isFinite,
                              transformed>=0,transformed<=1 else {
                            throw Failure.invalid("Float32 范围映射出现超界，取消复制")
                        }
                        store(p,pos,l.little,transformed)
                    }
                }
            }
        }
        guard let outProvider=CGDataProvider(data:mapped as CFData),
              let output=CGImage(
                width:l.width,height:l.height,
                bitsPerComponent:32,bitsPerPixel:l.bitsPerPixel,
                bytesPerRow:l.stride,space:l.colorSpace,
                bitmapInfo:l.bitmapInfo,provider:outProvider,
                decode:nil,shouldInterpolate:false,
                intent:.defaultIntent) else {
            throw Failure.invalid("无法生成可验证的 Float32 CGImage")
        }
        let buffer=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.tiff.identifier as CFString,1,nil) else {
            throw Failure.invalid("无法创建 Float32 TIFF 写入器")
        }
        CGImageDestinationAddImage(destination,output,nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.invalid("Float32 TIFF 写入失败；原件未更改")
        }
        let result=buffer as Data
        let after=Build111PhotoInputProfile.inspect(result,entry:.converted)
        guard after.directCompatible,after.floatingComponents,
              after.decodedDepth==32,after.declaredDepth==32,
              after.width==l.width,after.height==l.height,
              (after.color == .sRGB || after.color == .extendedSRGB),
              let verifiedSrc=CGImageSourceCreateWithData(result as CFData,nil),
              let verifiedImage=CGImageSourceCreateImageAtIndex(verifiedSrc,0,nil),
              let verifiedProvider=verifiedImage.dataProvider,
              let verifiedData=verifiedProvider.data as Data? else {
            throw Failure.invalid("Float32 映射副本没有通过真实 TIFF/ICC/32-bit 验证")
        }
        let verifiedLayout=try layout(verifiedImage,verifiedSrc,after)
        let vm=try scan(verifiedData,verifiedLayout)
        guard vm.count==m.count,vm.outOfRange==0,
              vm.minimum>=0,vm.maximum<=1 else {
            throw Failure.invalid(
                "映射后 TIFF 仍有 RGB 超出 0～1；拒绝进入原版光学，不转换到 8-bit"
            )
        }
        return Result(bytes:result,admission:after,
                      sourceMinimum:m.minimum,sourceMaximum:m.maximum,
                      outOfRangeComponents:m.outOfRange)
    }
}
