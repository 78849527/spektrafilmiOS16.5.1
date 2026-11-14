import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Build78/07 original TIFF floating-point FILE test, not artificial direct
/// Float -> Double conversion. Actual macOS ImageIO encoding and decoding
/// must preserve IEEE754 binary32 sample values, negatives and superwhite.
enum Build78FloatTIFFValidation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let reason)=self { return reason }
            return nil
        }
    }

    private static let source:[Float] = [
        -0.25, 0.0, 1.25, 1.0,
        0.0625, 0.375, 2.5, 1.0,
        1.0, -1.0, 0.75, 1.0,
        0.25, 0.5, 0.875, 1.0,
        0.125, 0.625, 0.8125, 1.0,
        4.0, 0.9375, -0.5, 1.0,
    ]

    private static func originalImage(
        colorSpace:CGColorSpace?=CGColorSpace(name:CGColorSpace.sRGB)
    ) throws -> CGImage {
        guard let srgb=colorSpace else {
            throw Failure.invalid("Could not find sRGB ICC profile")
        }
        var data=Data()
        for value in source {
            let word=value.bitPattern
            for byte in 0..<4 {
                data.append(UInt8(truncatingIfNeeded:word >> (8*byte)))
            }
        }
        guard let provider=CGDataProvider(data:data as CFData),
              let cg=CGImage(
                width:3,height:2,bitsPerComponent:32,
                bitsPerPixel:128,bytesPerRow:48,space:srgb,
                bitmapInfo:CGBitmapInfo(rawValue:
                    CGBitmapInfo.floatComponents.rawValue |
                    CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.noneSkipLast.rawValue
                ),
                provider:provider,decode:nil,
                shouldInterpolate:false,intent:.defaultIntent
              ) else {
            throw Failure.invalid("Failed to allocate true IEEE754 Float32 RGB image")
        }
        return cg
    }

    private static func encodedTIFF(_ image:CGImage) throws -> Data {
        let bytes=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(
            bytes as CFMutableData,UTType.tiff.identifier as CFString,1,nil
        ) else {
            throw Failure.invalid("ImageIO cannot encode IEEE754 TIFF")
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.invalid("ImageIO Float32 TIFF encoding failed")
        }
        return bytes as Data
    }


    // Build78/07: real ImageIO binary16 TIFF; unsupported OS encoders
    // must fail closed rather than promoting the input through RGBA8.
    // A source binary16 value is always exactly representable in Double.
    static func evaluateHalf() throws {
        let words:[UInt16] = [
            0xbc00,0x0000,0x3e00,0x3c00,
            0x0001,0x8000,0x4100,0x3c00,
            0x3c00,0xc000,0x3800,0x3c00,
            0x3400,0x3a00,0x3c00,0x3c00,
            0x3555,0x7bff,0x0001,0x3c00,
            0xb800,0x0400,0x3c00,0x3c00
        ]
        var data=Data()
        for word in words {
            data.append(UInt8(truncatingIfNeeded:word))
            data.append(UInt8(truncatingIfNeeded:word >> 8))
        }
        guard let profile=CGColorSpace(name:CGColorSpace.extendedSRGB),
              let provider=CGDataProvider(data:data as CFData),
              let image=CGImage(
                width:3,height:2,bitsPerComponent:16,
                bitsPerPixel:64,bytesPerRow:24,space:profile,
                bitmapInfo:CGBitmapInfo(rawValue:
                    CGBitmapInfo.floatComponents.rawValue |
                    CGBitmapInfo.byteOrder16Little.rawValue |
                    CGImageAlphaInfo.noneSkipLast.rawValue),
                provider:provider,decode:nil,
                shouldInterpolate:false,intent:.defaultIntent
              ) else {
            print("UNAVAILABLE Build78 actual Float16 CGImage construction; "
                  + "Float16 TIFF not certified on this host")
            return
        }
        guard let file=try? encodedTIFF(image),
              let src=CGImageSourceCreateWithData(file as CFData,nil),
              let actual=CGImageSourceCreateImageAtIndex(src,0,nil) else {
            print("UNAVAILABLE Build78 Float16 TIFF ImageIO encoding; "
                  + "retain fail-closed production decoder")
            return
        }
        let isFloating=actual.bitmapInfo.contains(.floatComponents)
            && (actual.bitsPerComponent==16 ||
                actual.bitsPerComponent==32)
        let tagged=actual.colorSpace.map { CFEqual($0,profile) } ?? false
        if !isFloating || !tagged {
            var unexpectedlyAccepted=false
            do { _=try OriginalSourcePixelIO.decode(file)
                 unexpectedlyAccepted=true }
            catch {}
            guard !unexpectedlyAccepted else {
                throw Failure.invalid(
                    "Build78 Float16 TIFF silently accepted an unverified "
                    + "integer or incorrectly tagged ImageIO conversion")
            }
            print("PASS Build78 Float16 TIFF fail-closed: ImageIO "
                  + "returned bpc=\(actual.bitsPerComponent), "
                  + "float=\(actual.bitmapInfo.contains(.floatComponents)), "
                  + "tagged extended sRGB=\(tagged)")
            return
        }
        let frame=try OriginalSourcePixelIO.decode(file)
        guard frame.width==3,frame.height==2,frame.rgb.count==18 else {
            throw Failure.invalid("Build78 Float16 TIFF decoded wrong shape")
        }
        for pixel in 0..<6 {
            for c in 0..<3 {
                let expected=Double(Float16(bitPattern:words[pixel*4+c]))
                let got=frame.rgb[pixel*3+c]
                guard got.bitPattern==expected.bitPattern else {
                    throw Failure.invalid(
                        "Float16 TIFF lost exact sample at "
                        + "\(pixel),\(c): \(expected) != \(got)")
                }
            }
        }
        print("PASS Build78 genuine Float16 TIFF 18/18 exact CPU Double "
              + "samples, including signed zero, subnormal, negative "
              + "and superwhite; only current ImageIO host certified")
    }

    static func evaluate() throws {
        let bytes=try encodedTIFF(originalImage())
        guard let src=CGImageSourceCreateWithData(bytes as CFData,nil),
              let actual=CGImageSourceCreateImageAtIndex(src,0,nil),
              actual.bitsPerComponent==32,
              actual.bitmapInfo.contains(.floatComponents) else {
            throw Failure.invalid(
                "ImageIO encoded TIFF lost its Float32 channel precision"
            )
        }
        FileHandle.standardError.write(Data(
            ("Build78 Float TIFF diagnostic: name="
                + String(describing:actual.colorSpace?.name)
                + " bpc=\(actual.bitsPerComponent)"
                + " float=\(actual.bitmapInfo.contains(.floatComponents))\n"
            ).utf8
        ))
        let frame=try OriginalSourcePixelIO.decode(bytes)
        guard frame.width==3,frame.height==2,
              frame.rgb.count==18 else {
            throw Failure.invalid("Float32 TIFF RGB shape or channel count changed")
        }
        for pixel in 0..<6 {
            for c in 0..<3 {
                let expected=Double(source[pixel*4+c])
                let got=frame.rgb[pixel*3+c]
                guard got.bitPattern==expected.bitPattern else {
                    throw Failure.invalid(
                        "Float32 TIFF precision, out-of-gamut or negative "
                        + "changed by ImageIO ingress at \(pixel),\(c): "
                        + "\(expected) != \(got)"
                    )
                }
            }
        }
        let preview=try OriginalSourcePixelIO.decode(bytes,previewMaxSide:2)
        guard preview.width==2,preview.height==1 else {
            throw Failure.invalid("Float32 TIFF preview geometry invalid")
        }
        for x in 0..<2 {
            let sourceX=x==0 ? 0 : 2
            for c in 0..<3 {
                let expected=Double(source[(3+sourceX)*4+c])
                guard preview.rgb[x*3+c].bitPattern==expected.bitPattern else {
                    throw Failure.invalid(
                        "Float32 TIFF display-only nearest neighbor altered original precision"
                    )
                }
            }
        }
        var resizeRejected=false
        do { _=try OriginalSourcePixelIO.decode(
            bytes,resizedTo:(width:2,height:1)
        ) } catch { resizeRejected=true }
        guard resizeRejected else {
            throw Failure.invalid(
                "Float32 TIFF cannot use unverified Quartz export resampling"
            )
        }
        guard let p3=CGColorSpace(name:CGColorSpace.displayP3) else {
            throw Failure.invalid("Build78 P3 profile unavailable")
        }
        let p3File=try encodedTIFF(try originalImage(colorSpace:p3))
        var rejectedP3=false
        do { _=try OriginalSourcePixelIO.decode(p3File) }
        catch { rejectedP3=true }
        guard rejectedP3 else {
            throw Failure.invalid(
                "Build78 wrong: Float32 P3 TIFF silently passed as extended sRGB"
            )
        }
        try evaluateHalf()
        print(
            "PASS Build78 actual Float32 TIFF 3x2 provider: 18/18 samples "
            + "equal Double(Float32), negative and >1 preserved, TIFF ICC "
            + "and packing checked, float P3 rejected, "
            + "resized export explicitly rejected; "
            + "does NOT establish ProPhoto, EXR, device Float16 or full-frame parity."
        )
    }
}
