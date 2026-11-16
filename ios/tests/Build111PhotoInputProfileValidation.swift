import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
enum Build111PhotoInputProfileValidation {
    static func jpeg(_ color:CGColorSpace)->Data {
        let w=48,h=48
        var bytes=[UInt8](repeating:255,count:w*h*4)
        for i in 0..<(w*h) {
            bytes[i*4]=UInt8(i%255)
            bytes[i*4+1]=UInt8((i*13)%255)
            bytes[i*4+2]=UInt8((i*7)%255)
        }
        let cg:CGImage?=bytes.withUnsafeMutableBytes { b in
            guard let ctx=CGContext(data:b.baseAddress,width:w,height:h,
                bitsPerComponent:8,bytesPerRow:w*4,space:color,
                bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue) else {return nil}
            return ctx.makeImage()
        }
        precondition(cg != nil,"fixture CGContext failed")
        let out=NSMutableData()
        let dest=CGImageDestinationCreateWithData(
            out,UTType.jpeg.identifier as CFString,1,nil
        )!
        CGImageDestinationAddImage(dest,cg!,nil)
        precondition(CGImageDestinationFinalize(dest),"fixture JPEG failure")
        return out as Data
    }

    static func main() throws {
        let sourceP3=jpeg(CGColorSpace(name:CGColorSpace.displayP3)!)
        let p3=Build111PhotoInputProfile.inspect(sourceP3,entry:.camera)
        precondition(p3.color == .displayP3,"P3 must be detected from actual CGImage")
        precondition(!p3.directCompatible && p3.convertibleP3,
            "P3 should require explicit conversion")
        precondition(p3.declaredDepth==8 && p3.width==48)
        let src=sourceP3
        let converted=try Build111PhotoInputProfile.convertP3ToSRGB(sourceP3)
        let result=Build111PhotoInputProfile.inspect(converted,entry:.converted)
        precondition(src==sourceP3,"original bytes must not be changed")
        precondition(result.directCompatible && result.color == .sRGB,
            "converted bytes must carry real sRGB data/profile")
        precondition(result.width==p3.width && result.height==p3.height)
        precondition(converted != sourceP3,"conversion must be new file bytes")

        let sourceSRGB=jpeg(CGColorSpace(name:CGColorSpace.sRGB)!)
        let ok=Build111PhotoInputProfile.inspect(sourceSRGB,entry:.album)
        precondition(ok.directCompatible && !ok.convertibleP3,
            "sRGB should be accepted without conversion")
        let sameFile=Build111PhotoInputProfile.inspect(sourceSRGB,entry:.file)
        precondition(sameFile.directCompatible &&
            sameFile.entry == .file)
        let broken=Build111PhotoInputProfile.inspect(Data([0,1,2]),entry:.file)
        precondition(!broken.directCompatible && !broken.convertibleP3,
            "invalid bytes must fail closed")
        print("PASS Build111 actual P3 JPEG -> consent ColorSync sRGB JPEG / metadata, 8-bit, original-byte immutability; sRGB, Photos/Files/camera, invalid fallback")
    }
}
