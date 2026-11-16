import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// True macOS disk image roundtrip of SOURCE metadata through the original
/// NativeOutputWriter. Explicitly NOT raw-XMP preservation or iPhone parity.
@main
enum FinalSourceMetadataRoundTripValidation {
    enum Failure:Error {case invalid(String)}
    static func read(_ bytes:Data) throws->[String:Any] {
        guard let image=CGImageSourceCreateWithData(bytes as CFData,nil),
              let metadata=CGImageSourceCopyPropertiesAtIndex(image,0,nil)
                  as? [String:Any] else {
            throw Failure.invalid("ImageIO cannot read file metadata")
        }
        return metadata
    }
    static func nested(_ properties:[String:Any],_ key:CFString)->[String:Any] {
        properties[key as String] as? [String:Any] ?? [:]
    }
    static func makeOriginal()->Data? {
        let bytes=Data(repeating:128,count:4*3*4)
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),
              let provider=CGDataProvider(data:bytes as CFData),
              let image=CGImage(
                width:4,height:3,bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:16,space:space,
                bitmapInfo:CGBitmapInfo(
                    rawValue:CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue),
                provider:provider,decode:nil,
                shouldInterpolate:false,intent:.defaultIntent
              ) else {return nil}
        let out=NSMutableData()
        guard let writer=CGImageDestinationCreateWithData(
            out as CFMutableData,UTType.jpeg.identifier as CFString,1,nil
        ) else{return nil}
        let props:[String:Any]=[
            kCGImagePropertyExifDictionary as String:[
                kCGImagePropertyExifDateTimeOriginal as String:
                    "2020:11:16 14:23:01"
            ],
            kCGImagePropertyIPTCDictionary as String:[
                kCGImagePropertyIPTCKeywords as String:[
                    "source-spektrafilm","acceptance-B"
                ]
            ],
            kCGImagePropertyGPSDictionary as String:[
                kCGImagePropertyGPSLatitudeRef as String:"N",
                kCGImagePropertyGPSLatitude as String:29.5633,
                kCGImagePropertyGPSLongitudeRef as String:"E",
                kCGImagePropertyGPSLongitude as String:106.5516
            ],
        ]
        CGImageDestinationAddImage(writer,image,props as CFDictionary)
        guard CGImageDestinationFinalize(writer) else{return nil}
        return out as Data
    }
    static func validate(_ before:[String:Any],
        _ after:[String:Any],format:String) throws {
        let exifKey=kCGImagePropertyExifDateTimeOriginal as String
        let exif0=nested(before,kCGImagePropertyExifDictionary)
        let exif1=nested(after,kCGImagePropertyExifDictionary)
        guard let date=exif0[exifKey] as? String,
              date=="2020:11:16 14:23:01",
              exif1[exifKey] as? String==date else {
            throw Failure.invalid(format+" true EXIF DateTimeOriginal lost")
        }
        let keywordKey=kCGImagePropertyIPTCKeywords as String
        let kw0=nested(before,kCGImagePropertyIPTCDictionary)
        let kw1=nested(after,kCGImagePropertyIPTCDictionary)
        guard let left=kw0[keywordKey] as? [String],
              left.contains("source-spektrafilm"),
              let right=kw1[keywordKey] as? [String],
              Set(left)==Set(right) else {
            throw Failure.invalid(format+" true IPTC Keywords not preserved")
        }
        let latKey=kCGImagePropertyGPSLatitude as String
        let gps0=nested(before,kCGImagePropertyGPSDictionary)
        let gps1=nested(after,kCGImagePropertyGPSDictionary)
        guard let v0=gps0[latKey] as? NSNumber,
              let v1=gps1[latKey] as? NSNumber,
              abs(v0.doubleValue-v1.doubleValue)<0.00001 else {
            throw Failure.invalid(format+" true GPS latitude not preserved")
        }
        print("PASS \(format): source EXIF+IPTC+GPS actual disk output")
    }
    static func main() throws {
        guard let bytes=makeOriginal() else {
            throw Failure.invalid("source metadata JPEG encode failed")
        }
        let before=try read(bytes)
        let rgb=[Double](repeating:0.5,count:4*3*3)
        for (format,bits) in [
            (Build90SourceOutputQuantization.FileFormat.jpeg,8),
            (.tiff,16)
        ] {
            let output=try Build90NativeOutputWriter.write(
                width:4,height:3,rgb:rgb,
                options:.init(format:format,bitDepth:bits,
                              sourceImageData:bytes)
            )
            defer {try? FileManager.default.removeItem(at:output)}
            try validate(before,try read(Data(contentsOf:output)),
                         format:format.rawValue)
        }
        print("PASS source JPEG+TIFF EXIF/IPTC/GPS limited roundtrip; XMP NOT CERTIFIED")
    }
}
