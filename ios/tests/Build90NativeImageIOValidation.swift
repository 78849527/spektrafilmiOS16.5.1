import Foundation
import CoreGraphics
import ImageIO

@main
enum Build90RealNativeImageIOValidation {
    enum Failure:Error {case invalid(String)}
    static func main() throws {
        let width=3,height=2
        let rgb:[Double]=[
            0.01,0.15,0.32,
            0.55,0.31,0.99,
            1.4,0.37,-0.2,
            0.8,0.8,0.8,
            0.2,0.7,0.04,
            0.004,0.983,0.41
        ]
        let samples:[(
            Build90SourceOutputQuantization.FileFormat,Int,String,Bool
        )]=[
            (.jpeg,16,"sRGB",true),
            (.png,32,"sRGB",true),
            (.tiff,8,"sRGB",true),
            (.tiff,16,"sRGB",true),
            (.tiff,32,"sRGB",false),
            (.png,8,"Display P3",true),
            (.tiff,16,"ITU-R BT.2020",true),
            (.tiff,16,"ITU-R BT.2020",false)
        ]
        var certified=0,matchedICC=0,depths=[Int]()
        for (format,bits,space,encoded) in samples {
            let expectedSpec=try Build90SourceOutputQuantization.Specification(
                format:format,bitDepth:bits
            )
            let opt=Build90NativeOutputWriter.Options(
                format:format,bitDepth:bits,outputSpace:space,
                cctfEncoded:encoded
            )
            let url=try Build90NativeOutputWriter.write(
                width:width,height:height,rgb:rgb,options:opt
            )
            defer {try? FileManager.default.removeItem(at:url)}
            let bytes=try Data(contentsOf:url)
            guard bytes.count>40,
                  let src=CGImageSourceCreateWithData(bytes as CFData,nil),
                  let image=CGImageSourceCreateImageAtIndex(src,0,nil),
                  image.width==width,image.height==height,
                  image.bitsPerComponent==expectedSpec.storage.bitsPerChannel
            else {
                throw Failure.invalid(
                    "Actual \(space) \(format.rawValue)-\(bits) file bit-depth wrong"
                )
            }
            let sourceICC=Build90GeneratedSourceICC.exactProfile(
                space:space,encoded:encoded
            )
            guard let cs=image.colorSpace,
                  let rawICC=cs.copyICCData(),
                  (rawICC as Data)==sourceICC else {
                throw Failure.invalid(
                    "Actual disk image ICC bytes do not equal source ICC"
                )
            }
            matchedICC+=1
            let p=CGImageSourceCopyPropertiesAtIndex(src,0,nil)
                as? [String:Any] ?? [:]
            let orientation=p[kCGImagePropertyOrientation as String]
                as? Int ?? 1
            guard orientation==1 else {
                throw Failure.invalid("Original source EXIF orientation must be 1")
            }
            depths.append(image.bitsPerComponent)
            certified+=1
            print("PASS native ImageIO \(space) \(format.rawValue) " +
                  "\(bits) actual \(bytes.count) bytes; " +
                  "readback \(image.bitsPerComponent)bpc exact source ICC.")
        }
        guard certified==samples.count,
              matchedICC==samples.count,
              depths.contains(32),depths.contains(16),
              depths.contains(8) else {
            throw Failure.invalid("Native real-file matrix insufficient")
        }
        // Source has no Display P3 linear ICC. This fails visibly,
        // never silently retags linear P3 as sRGB/P3 gamma.
        do{
            let url=try Build90NativeOutputWriter.write(
                width:width,height:height,rgb:rgb,
                options:.init(format:.tiff,bitDepth:16,
                              outputSpace:"Display P3",
                              cctfEncoded:false)
            )
            try? FileManager.default.removeItem(at:url)
            throw Failure.invalid("Source P3 linear ICC missing yet accepted")
        }catch Build90NativeOutputWriter.Failure.invalid(_){}
        // EXR encoder not linked: never emit fake JPG/PNG with .exr suffix.
        do{
            let url=try Build90NativeOutputWriter.write(
                width:width,height:height,rgb:rgb,
                options:.init(format:.exr,bitDepth:16,
                              outputSpace:"sRGB",cctfEncoded:true)
            )
            try? FileManager.default.removeItem(at:url)
            throw Failure.invalid("Fake .exr file created without real codec")
        }catch Build90NativeOutputWriter.Failure.invalid(_){}
        print("PASS BUILD90 actual macOS ImageIO: " +
              "\(certified) physical files, JPEG/PNG/TIFF U8/U16/F32, " +
              "source ICC exact byte-for-byte, metadata and depth " +
              "readback; missing P3 linear ICC and EXR codec fail-closed. " +
              "This is macOS native I/O, NOT iPhone16.5 device execution.")
    }
}
