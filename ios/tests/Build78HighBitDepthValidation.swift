import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Build78/07 macOS ImageIO *file* regression: no fake UInt16->Double
/// arrays. Encode actual 16-bit PNG/TIFF, reopen via the SAME public
/// OriginalSourcePixelIO.decode used by iPhone production, and verify
/// every RGB channel with exact Double(UInt16)/65535.0 equality.
/// This is a strict small-fixture ingress test, NOT full ICC/RAW parity.
enum Build78HighBitDepthValidation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let text)=self { return text }
            return nil
        }
    }

    static func fixture(
        space:CGColorSpace,alpha:UInt16=65535,declareAlpha:Bool=false
    ) throws -> (CGImage,[UInt16]) {
        let values:[UInt16]=[
            0,1023,65535,alpha, 65535,0,32768,alpha,
            1,2048,32767,alpha, 12345,54321,999,alpha,
            65534,2,16384,alpha, 9999,32767,65535,alpha
        ]
        var encoded=Data()
        for sample in values {
            encoded.append(UInt8(truncatingIfNeeded:sample))
            encoded.append(UInt8(truncatingIfNeeded:sample >> 8))
        }
        guard let provider=CGDataProvider(data:encoded as CFData),
              let image=CGImage(
                width:3,height:2,bitsPerComponent:16,bitsPerPixel:64,
                bytesPerRow:24,space:space,
                bitmapInfo:CGBitmapInfo(
                    rawValue:(declareAlpha ? CGImageAlphaInfo.last.rawValue :
                        CGImageAlphaInfo.noneSkipLast.rawValue) |
                        CGBitmapInfo.byteOrder16Little.rawValue
                ),
                provider:provider,decode:nil,shouldInterpolate:false,
                intent:.defaultIntent
              ) else {
            throw Failure.invalid("Could not construct real 16-bit sRGB source")
        }
        return (image,values)
    }

    static func encode(
        _ image:CGImage, type:UTType, orientation:Int?=nil
    ) throws -> Data {
        let out=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(
            out as CFMutableData,type.identifier as CFString,1,nil
        ) else { throw Failure.invalid("Could not encode genuine 16-bit file") }
        let props:CFDictionary? = orientation.map { value in
            [kCGImagePropertyOrientation as String:NSNumber(value:value)]
                as CFDictionary
        }
        CGImageDestinationAddImage(dest,image,props)
        guard CGImageDestinationFinalize(dest) else {
            throw Failure.invalid("ImageIO 16-bit fixture encoding failed")
        }
        return out as Data
    }

    static func verify(
        actual:OriginalSourcePixelIO.Frame,
        expected:[UInt16], type:String
    ) throws {
        guard actual.width==3,actual.height==2,
              actual.rgb.count==18 else {
            throw Failure.invalid("16-bit \(type) image geometry changed")
        }
        for pixel in 0..<6 {
            for ch in 0..<3 {
                let e=Double(expected[pixel*4+ch])/65535.0
                let got=actual.rgb[pixel*3+ch]
                guard e.bitPattern==got.bitPattern else {
                    throw Failure.invalid(
                        "16-bit \(type) component changed: pixel "
                        + "\(pixel) ch \(ch): \(e) != \(got)"
                    )
                }
            }
        }
    }

    static func expectReject(_ input:Data,label:String) throws {
        do {
            _=try OriginalSourcePixelIO.decode(input)
        } catch {
            print("PASS Build78 strict fail-closed \(label): "
                  + error.localizedDescription)
            return
        }
        throw Failure.invalid("Build78 unexpectedly accepted \(label)")
    }

    static func evaluate() throws {
        guard let srgb=CGColorSpace(name:CGColorSpace.sRGB),
              let p3=CGColorSpace(name:CGColorSpace.displayP3) else {
            throw Failure.invalid("Source colour profile unavailable")
        }
        let (image,reference)=try fixture(space:srgb)
        var success=0
        for type in [UTType.png,UTType.tiff] {
            let data=try encode(image,type:type)
            guard let cgSource=CGImageSourceCreateWithData(
                data as CFData,nil
            ),let decoded=CGImageSourceCreateImageAtIndex(
                cgSource,0,nil
            ),decoded.bitsPerComponent==16 else {
                throw Failure.invalid(
                    "ImageIO silently downconverted 16-bit \(type.identifier)"
                    + " before the precision gate"
                )
            }
            let frame=try OriginalSourcePixelIO.decode(data)
            try verify(actual:frame,expected:reference,type:type.identifier)
            let preview=try OriginalSourcePixelIO.decode(
                data,previewMaxSide:2
            )
            guard preview.width==2,preview.height==1,
                  preview.rgb.count==6 else {
                throw Failure.invalid("Build78 16-bit preview bounds invalid")
            }
            // At 3x2 -> 2x1, center-nearest picks input (0,1) & (2,1),
            // with no gamma transform or UInt8 conversion.
            for outX in 0..<2 {
                let inputX=outX==0 ? 0 : 2
                let sourceOffset=(3+inputX)*4
                for ch in 0..<3 {
                    let wanted=Double(reference[sourceOffset+ch])/65535.0
                    guard preview.rgb[outX*3+ch].bitPattern ==
                            wanted.bitPattern else {
                        throw Failure.invalid(
                            "Build78 nearest 16-bit preview mutated a pixel"
                        )
                    }
                }
            }
            var rejectedResize=false
            do {
                _=try OriginalSourcePixelIO.decode(
                    data,resizedTo:(width:2,height:1)
                )
            } catch { rejectedResize=true }
            guard rejectedResize else {
                throw Failure.invalid(
                    "16-bit source export must reject unverified cubic resize"
                )
            }
            success+=1
        }
        // Genuine TIFF EXIF direction data is interpreted by the SAME
        // production UInt16 reader, never a simulated rotated array.
        for rotation in [3,6,8] {
            let file=try encode(image,type:.tiff,orientation:rotation)
            let frame=try OriginalSourcePixelIO.decode(file)
            let rotated=rotation==6 || rotation==8
            guard frame.width==(rotated ? 2 : 3),
                  frame.height==(rotated ? 3 : 2) else {
                throw Failure.invalid(
                    "16-bit TIFF EXIF rotation \(rotation) geometry changed"
                )
            }
            for sy in 0..<2 {
                for sx in 0..<3 {
                    let dx:Int,dy:Int
                    switch rotation {
                    case 3: dx=2-sx;dy=1-sy
                    case 6: dx=1-sy;dy=sx
                    default: dx=sy;dy=2-sx
                    }
                    for c in 0..<3 {
                        let wanted=Double(reference[(sy*3+sx)*4+c])/65535
                        let got=frame.rgb[(dy*frame.width+dx)*3+c]
                        guard got.bitPattern==wanted.bitPattern else {
                            throw Failure.invalid(
                                "16-bit TIFF EXIF \(rotation) changed pixel "
                                + "\(sx),\(sy) channel \(c)"
                            )
                        }
                    }
                }
            }
        }
        let (p3Image,_)=try fixture(space:p3)
        try expectReject(try encode(p3Image,type:.tiff),label:"16-bit P3 TIFF")

        let (alphaImage,_)=try fixture(space:srgb,alpha:32768,declareAlpha:true)
        try expectReject(try encode(alphaImage,type:.tiff),
                         label:"nonopaque alpha TIFF")

        print("PASS Build78 actual 16-bit integer sRGB TIFF+PNG file ingress "
              + "\(success)/2, 18 per-file RGB channels bitwise exact "
              + "as Double(UInt16)/65535, nearest 16-bit preview, "
              + "no 8-bit/Float16 fallback, invalid P3/alpha and "
              + "all tested TIFF EXIF orientations preserve UInt16; "
              + "unsupported precise export resizing rejected; "
              + "NOT full ICC, RAW or Float TIFF equivalence.")
    }
}
