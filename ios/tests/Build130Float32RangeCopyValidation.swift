import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Exercises actual IEEE754 Float32 TIFF bytes and the real Build78 decoder.
/// This is a compatibility *copy* test, not Apple RAW/rawpy optical parity.
enum Build130Float32RangeCopyValidation {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let s)=self {return s}
            return nil
        }
    }
    private static func require(_ ok:Bool,_ reason:String)throws {
        guard ok else {throw Failure.invalid(reason)}
    }
    private static func tiff(
        _ values:[Float],
        profile:CGColorSpace?=CGColorSpace(name:CGColorSpace.sRGB)
    ) throws->Data {
        guard values.count==24, let space=profile else {
            throw Failure.invalid("Missing ICC or 3x2x4 Float32 fixture")
        }
        var raw=Data()
        for n in values {
            let bits=n.bitPattern
            for i in 0..<4 {
                raw.append(UInt8(truncatingIfNeeded:bits >> (8*i)))
            }
        }
        guard let provider=CGDataProvider(data:raw as CFData),
              let image=CGImage(
                width:3,height:2,bitsPerComponent:32,
                bitsPerPixel:128,bytesPerRow:48,space:space,
                bitmapInfo:CGBitmapInfo(rawValue:
                    CGBitmapInfo.floatComponents.rawValue |
                    CGBitmapInfo.byteOrder32Little.rawValue |
                    CGImageAlphaInfo.noneSkipLast.rawValue
                ),
                provider:provider,decode:nil,
                shouldInterpolate:false,intent:.defaultIntent
              ) else {
            throw Failure.invalid("Cannot allocate binary32 CGImage")
        }
        let out=NSMutableData()
        guard let writer=CGImageDestinationCreateWithData(
            out as CFMutableData,UTType.tiff.identifier as CFString,1,nil
        ) else {
            throw Failure.invalid("Cannot allocate TIFF destination")
        }
        CGImageDestinationAddImage(writer,image,nil)
        guard CGImageDestinationFinalize(writer) else {
            throw Failure.invalid("Cannot encode real TIFF fixture")
        }
        return out as Data
    }

    static func evaluate() throws {
        let original:[Float]=[
            -0.25,0.125,1.5,1.0,
            0.75,0.375,0.875,1.0,
            0.0625,2.5,0.3,1.0,
            0.4,0.7,0.55,1.0,
            1.0,0.0,0.225,1.0,
            0.833,0.912,0.277,1.0
        ]
        let bytes=try tiff(original)
        let preserved=bytes
        let frameBefore=try OriginalSourcePixelIO.decode(bytes)
        try require(frameBefore.rgb.contains(where:{$0<0 || $0>1}),
                    "HDR fixture erroneously in SDR range")
        let r=try Build130Float32RangeCopy.makeMappedWorkingCopy(bytes)
        try require(bytes==preserved,
                    "Range-mapped operation modified input file")
        try require(r.outOfRangeComponents==3,
                    "Expected exactly negative and superwhite RGB samples")
        try require(r.sourceMinimum == -0.25 &&
                    r.sourceMaximum==2.5,"Incorrect full-frame min/max")
        try require(r.admission.format=="TIFF" &&
                    r.admission.floatingComponents &&
                    r.admission.decodedDepth==32 &&
                    r.admission.declaredDepth==32 &&
                    r.admission.directCompatible,
                    "Working copy is not independently verified ICC Float32 TIFF")
        let frameAfter=try OriginalSourcePixelIO.decode(r.bytes)
        try require(frameAfter.width==3 && frameAfter.height==2,
                    "Geometry changed")
        try require(frameAfter.rgb.allSatisfy({$0.isFinite && $0>=0 && $0<=1}),
                    "Output escaped original optical [0,1] range")
        // Common affine map must preserve global RGB component ordering.
        let indices=original.indices.filter{$0 % 4 != 3}
        let sorted=indices.sorted { original[$0] < original[$1] }
        for j in 1..<sorted.count {
            let a=sorted[j-1],b=sorted[j]
            let ai=(a/4)*3+(a%4),bi=(b/4)*3+(b%4)
            try require(frameAfter.rgb[ai]<=frameAfter.rgb[bi],
                        "Range mapping changed relative RGB ordering")
        }
        // No implicit conversion for an already certified SDR source.
        let regular=Array(repeating:Float(0.5),count:6)
        var sdr=[Float]()
        for i in 0..<6 {
            sdr.append(regular[i])
            sdr.append(0.25)
            sdr.append(0.75)
            sdr.append(1.0)
        }
        do {
            _=try Build130Float32RangeCopy.makeMappedWorkingCopy(
                try tiff(sdr))
            throw Failure.invalid("Already in-range Float32 was needlessly remapped")
        } catch let failure as Build130Float32RangeCopy.Failure {
            try require(failure.localizedDescription.contains("已在 0～1"),
                        "Unexpected legal-input rejection reason")
        }
        let p3=CGColorSpace(name:CGColorSpace.displayP3)
        if p3 != nil {
            do {
                _=try Build130Float32RangeCopy.makeMappedWorkingCopy(
                    try tiff(original,profile:p3))
                throw Failure.invalid("P3 Float32 falsely tagged as sRGB")
            } catch is Build130Float32RangeCopy.Failure {}
        }
        var invalid=original
        invalid[0]=Float.nan
        do {
            _=try Build130Float32RangeCopy.makeMappedWorkingCopy(try tiff(invalid))
            throw Failure.invalid("NaN was accepted")
        } catch is Build130Float32RangeCopy.Failure {}
        print("PASS explicit mapped Float32 TIFF: original unchanged, ICC/bit-depth verified, " +
              "negative/superwhite samples remapped without hard clipping, " +
              "0..1 source optical admission + monotonic order, already-SDR/P3/NaN fail-closed")
        print("NOT CERTIFIED: rawpy input equivalence or real iOS16.5.1 Apple RAW end-to-end UX")
    }
}
