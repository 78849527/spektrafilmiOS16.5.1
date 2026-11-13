import Foundation

/// Native numeric comparison against actual upstream Python reference:
/// colour.RGB_to_XYZ sRGB meters, Numba highlight recovery, and actual
/// fast_gaussian_filter FIR / YVV on two full non-tiled RGB fields.
enum OriginalSourceCameraBatchValidation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let message) = self {return message}
            return nil
        }
    }

    private static func image(_ w:Int,_ h:Int) -> [Double] {
        (0..<(w*h*3)).map {
            (Double(($0*37+11)%251)+0.5)/251.0
        }
    }
    private static func raw(_ w:Int,_ h:Int) -> [Double] {
        (0..<(w*h*3)).map {
            Double(($0*17+3)%397)/71.0
        }
    }
    private static func decode(_ base64:String,count:Int) throws -> [Double] {
        guard let bytes=Data(base64Encoded:base64),
              bytes.count==count*MemoryLayout<Double>.size else {
            throw Failure.invalid("源 Float64 相机参考二进制长度错误")
        }
        return bytes.withUnsafeBytes { raw in
            (0..<count).map {
                Double(bitPattern:UInt64(littleEndian:raw.loadUnaligned(
                    fromByteOffset:$0*8,as:UInt64.self
                )))
            }
        }
    }
    @discardableResult private static func compare(
        _ actual:[Double],_ expected:[Double],
        label:String,tolerance:Double
    ) throws -> Double {
        guard actual.count==expected.count, !actual.isEmpty,
              actual.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid(label + " RGB 数据长度或有限性错误")
        }
        let maxError=zip(actual,expected).map { pair in abs(pair.0-pair.1) }.max() ?? .infinity
        guard maxError<tolerance else {
            throw Failure.invalid(
                label + " Python→Swift Float64 差异 " +
                String(maxError) + " 超过 " + String(tolerance)
            )
        }
        print("PASS: " + label + " max_abs=" + String(maxError))
        return maxError
    }
    static func evaluate() throws {
        // Reference fixtures must identify the exact original Python
        // implementation and FIR/YVV dependency, not just visual samples.
        let sourceHashes = GeneratedSourceCameraReference.sourceSHA256
        let expectedSourceFiles: Set<String> = [
            "autoexposure", "highlight_boost",
            "camera_diffusion", "source_gaussian"
        ]
        guard Set(sourceHashes.keys) == expectedSourceFiles,
              sourceHashes.values.allSatisfy({ hash in
                  hash.count == 64 &&
                  hash.utf8.allSatisfy({
                      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
                  })
              }) else {
            throw Failure.invalid("原版摄影参考缺少原始 Python 文件 SHA-256")
        }
        print("PASS: upstream camera stage and Gaussian dependency SHA-256 recorded")
        let yWeights=GeneratedSourceCameraReference.sourceLuminanceWeights
        guard yWeights.count==3,
              yWeights.allSatisfy({ $0.isFinite && $0>0 }),
              abs(yWeights.reduce(0,+)-1.0)<1e-9 else {
            throw Failure.invalid("原版 sRGB colour-science 亮度矩阵参考无效")
        }
        print("PASS: source colour-science luminance Y weights \(yWeights)")
        let methodNames=[
            "average","median","center_weighted","partial",
            "matrix","multi_zone","highlight_weighted"
        ]
        for rec in GeneratedSourceCameraReference.meter {
            let input=image(rec.width,rec.height)
            guard rec.ev.count==methodNames.count else {
                throw Failure.invalid("Python 七种测光参考不完整")
            }
            for i in methodNames.indices {
                guard let method=OriginalSourceCameraOptics.Metering(
                    rawValue:methodNames[i]
                ) else {
                    throw Failure.invalid("测光方法未知 " + methodNames[i])
                }
                let actual=try OriginalSourceCameraOptics.measureAutoExposureEV(
                    encodedRGB:input,width:rec.width,height:rec.height,
                    method:method
                )
                try compare([actual],[rec.ev[i]],label:
                    "Python \(rec.width)×\(rec.height) \(methodNames[i])",
                    tolerance:2e-8
                )
            }
        }
        // Source Python's black-frame +/-Infinity recovery is not an
        // arbitrary clamped EV. Compare each original method explicitly.
        // A 257x301 zero frame also validates upstream nearest preview.
        for rec in GeneratedSourceCameraReference.meterEdge {
            let input=[Double](repeating:rec.level,
                               count:rec.width*rec.height*3)
            guard rec.ev.count==methodNames.count else {
                throw Failure.invalid("Python 黑白场原版测光方法不完整")
            }
            for i in methodNames.indices {
                guard let method=OriginalSourceCameraOptics.Metering(
                    rawValue:methodNames[i]
                ) else {
                    throw Failure.invalid("原版测光方法未知 " + methodNames[i])
                }
                let actual=try OriginalSourceCameraOptics.measureAutoExposureEV(
                    encodedRGB:input,width:rec.width,height:rec.height,
                    method:method
                )
                try compare([actual],[rec.ev[i]],label:
                    "Python edge \(rec.width)×\(rec.height) level=\(rec.level) \(methodNames[i])",
                    tolerance:2e-8
                )
            }
        }
        for rec in GeneratedSourceCameraReference.boost {
            var values=raw(rec.width,rec.height)
            let expected=try decode(rec.output,count:values.count)
            try OriginalSourceCameraOptics.boostHighlightsInPlace(
                &values,boostEV:rec.ev,
                boostRange:rec.span,protectEV:rec.protect
            )
            try compare(values,expected,label:
                "Numba photon boost EV=\(rec.ev) protect=\(rec.protect)",
                tolerance:1e-10
            )
        }
        for rec in GeneratedSourceCameraReference.lens {
            let values=raw(rec.width,rec.height)
            let expected=try decode(rec.output,count:values.count)
            let settings=OriginalSourceCameraOptics.Settings(
                metering:.disabled,boostEV:0,boostRange:0.3,
                protectEV:4,lensBlurUM:rec.microns,
                filmFormatMM:rec.formatMM
            )
            let actual=try OriginalSourceCameraOptics.applyLensBlur(
                values,width:rec.width,height:rec.height,settings:settings
            )
            try compare(actual,expected,label:
                "source camera raw Gaussian \(rec.microns)um",
                tolerance:3e-8
            )
        }

        // A malformed full-frame geometry must fail explicitly. It must
        // never overflow Int arithmetic or crash before source validation.
        do {
            _ = try OriginalSourceCameraOptics.applyLensBlur(
                [0.0, 0.0, 0.0],
                width: Int.max, height: 2,
                settings: .init(lensBlurUM: 15.0)
            )
            throw Failure.invalid("Oversized lens frame unexpectedly accepted")
        } catch OriginalSourceCameraOptics.Failure.invalid {
            print("PASS: overflowing camera lens frame rejected without trap")
        }
        do {
            _ = try OriginalSourceCameraOptics.applyLensBlur(
                [0.0, 0.0, 0.0],
                width: -2, height: 1,
                settings: .init(lensBlurUM: 15.0)
            )
            throw Failure.invalid("Negative camera lens frame unexpectedly accepted")
        } catch OriginalSourceCameraOptics.Failure.invalid {
            print("PASS: negative camera lens dimensions rejected")
        }

        // Established source sourceSpatialInput path must remain identical
        // to the new unboosted raw-photon path. This guards against
        // accidentally moving exposure compensation after H-D.
        let engine=try SpectralPhysics(
            filmID:"kodak_portra_400",
            paperID:"kodak_portra_endura",
            sourceScanner:true,scannerBlackWhite:false,
            cam16Gamut:false,printReferenceCorrection:false,
            printOptics:OriginalPrintOptics.Settings(enabled:true),
            cameraExposureEV:0.5,
            hanatosPrecision:.originalFloat64,
            sourceMeasuredFloat64:true
        )
        let input=[0.12,0.43,0.78]
        let old=try engine.sourceSpatialInput(encodedRGB:input,cameraEV:0.5)
        let photons=try engine.sourceCameraRaw(encodedRGB:input,cameraEV:0.5)
        let next=try engine.sourceSpatialInputFromCameraRaw(photons)
        try compare(old.rawLog,next.rawLog,
                    label:"source pre-H-D photon exposure order",tolerance:1e-12)
        try compare(old.initialDensity,next.initialDensity,
                    label:"source original film H-D unchanged",tolerance:1e-12)
        print("PASS: 7 metering modes + high-light boost + raw lens blur + source H-D integration")
    }
}
