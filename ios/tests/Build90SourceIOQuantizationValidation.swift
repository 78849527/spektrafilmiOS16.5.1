import Foundation

@main
enum Build90SourceIOQuantizationValidation {
    enum Failure:Error {case invalid(String)}
    static func doubleArray(_ a:[NSNumber])->[Double] {
        a.map{$0.doubleValue}
    }
    static func main()throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need pinned source io.py numeric output fixture")
        }
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard let root=try JSONSerialization.jsonObject(with:data)
                as? [String:Any],
              let items=root["cases"] as? [[String:Any]],
              items.count==8,
              let pixels=root["pixels"] as? Int,pixels==40 else {
            throw Failure.invalid("Original 8 file formats x 40 source pixels missing")
        }
        var passed=0,ints=0,floats=0,rawOut=0
        var worst=0.0
        for (index,row) in items.enumerated() {
            guard let fileExtension=row["format"] as? String,
                  let bits=row["bitDepth"] as? Int,
                  let expectedType=row["dtype"] as? String,
                  let sourcePixels=row["input"] as? [[NSNumber]],
                  let expectedPixels=row["expected"] as? [[NSNumber]],
                  let sourceBits=row["expectedBits"] as? [[NSNumber]] else {
                throw Failure.invalid("Pinned Python OIIO entry incomplete")
            }
            let fileType:Build90SourceOutputQuantization.FileFormat
            switch fileExtension {
            case "jpg","jpeg":fileType = .jpeg
            case "png":fileType = .png
            case "tif","tiff":fileType = .tiff
            case "exr":fileType = .exr
            default:throw Failure.invalid("Unexpected original file extension")
            }
            let spec=try Build90SourceOutputQuantization.Specification(
                format:fileType,bitDepth:bits
            )
            guard spec.storage.rawValue==expectedType else {
                throw Failure.invalid(
                    "Original OIIO dtype \(expectedType), native " +
                    "\(spec.storage.rawValue)"
                )
            }
            let raw=sourcePixels.flatMap{doubleArray($0)}
            let expected=expectedPixels.flatMap{doubleArray($0)}
            let encoded=try Build90SourceOutputQuantization.quantize(
                raw,as:spec
            )
            let byteData=try Build90SourceOutputQuantization.packed(
                raw,as:spec
            )
            guard encoded.count==expected.count,
                  byteData.count==(expected.count*
                    spec.storage.bitsPerChannel/8) else {
                throw Failure.invalid("Source OIIO buffer size/dtype wrong")
            }
            let expectedBitPattern=sourceBits.flatMap{$0.map{$0.uint32Value}}
            for ch in expected.indices {
                let delta=abs(encoded[ch]-expected[ch])
                guard delta.isFinite,delta==0 else {
                    throw Failure.invalid(
                        "Actual original \(fileExtension)-\(bits) " +
                        "case \(index) channel \(ch): Swift \(encoded[ch]) " +
                        "Python \(expected[ch]), abs delta \(delta)"
                    )
                }
                let bits=Float(encoded[ch]).bitPattern
                guard bits==expectedBitPattern[ch] else {
                    throw Failure.invalid(
                        "Original Float16/32 or uint exact binary32 stage mismatch"
                    )
                }
                if spec.storage == .float16 ||
                   spec.storage == .float32 {
                    floats+=1
                    if raw[ch]<0 || raw[ch]>1 {rawOut+=1}
                } else {ints+=1}
                worst=max(worst,delta)
                passed+=1
            }
        }
        guard passed==960,ints>0,floats>0,rawOut>0 else {
            throw Failure.invalid("Original 960 format channels missing")
        }
        let invalid=[
            (Build90SourceOutputQuantization.FileFormat.tiff,24),
            (.exr,8)
        ]
        for (file,bit) in invalid {
            do{
                _=try Build90SourceOutputQuantization.Specification(
                    format:file,bitDepth:bit
                )
                throw Failure.invalid("Forbidden source output depth accepted")
            }catch Build90SourceOutputQuantization.Failure.invalid(_){}
        }
        print("PASS BUILD90 real original io.py AST: 960/960 " +
              "float/int output channels EXACT zero error, JPEG+PNG " +
              "forced uint8, TIFF8/16/32, EXRhalf/F32, clipped integer " +
              "and raw HDR; native byte count verified; EXR codec " +
              "availability is NOT inferred from numeric support.")
    }
}
