import Foundation

/// Build88 native FULL production sequence probe. Runs the actual source
/// optical 81nm scanner, separately from 8/8 Metal certification.
/// It is a test that can be executed on iOS 16.5.1, NOT evidence of an
/// actual connected device run or independent whole-image Python RGB parity.
enum Build88ScannerCombinedProductionDiagnostic {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(m)=self{return m}
            return nil
        }
    }

    private static func stage(
        _ taps:[String:[Double]],_ name:String,_ count:Int
    ) throws -> [Double] {
        guard let values=taps[name],
              values.count==count,
              values.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Build88 缺少源扫描真实生产阶段："+name)
        }
        return values
    }

    static func evaluate() throws -> String {
        let width=9,height=7
        let channels=width*height*3
        let original=OriginalSourcePixelIO.Frame(
            width:width,height:height,
            rgb:(0..<(width*height)).flatMap { p in
                (0..<3).map { c in
                    Double((p*13+c*43+(p/width)*19+37)%210+18)/255.0
                }
            }
        )
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        dir.referencePixelSizeUM=30
        var parameters=OriginalSourcePhysicalImage.Parameters(
            filmID:"kodak_portra_400",
            paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,dir:dir,
            print:OriginalPrintOptics.Settings(enabled:true),
            morph:OriginalPrintMorph.Settings()
        )
        parameters.scannerOptics.lensBlurSigma=0.9
        parameters.scannerOptics.unsharpSigma=3.2
        parameters.scannerOptics.unsharpAmount=2.4
        var taps=[String:[Double]]()
        func render(_ config:OriginalSourcePhysicalImage.Parameters) throws
          -> OriginalSourcePixelIO.Frame {
            taps.removeAll(keepingCapacity:true)
            return try OriginalSourcePhysicalImage.develop(
                original,parameters:config,
                stageDoubleObserver:{ name,buffer in
                    taps[name]=buffer
                }
            )
        }

        // ScanningStage: paper CMY -> XYZ -> linear RGB -> lens Gaussian
        // -> unsharp -> optional output CCTF, never blur encoded sRGB.
        let encoded=try render(parameters)
        let blurred=try stage(taps,"scannerLensBlur",channels)
        let unsharpBlur=try stage(taps,"scannerUnsharpBlur",channels)
        let linear=try stage(taps,"scannerLinear",channels)
        let scanned=try stage(taps,"printed",channels)
        guard blurred != unsharpBlur,unsharpBlur != linear,
              encoded.rgb==scanned else {
            throw Failure.invalid(
                "Build88 FIR/YVV 锐化顺序或正式扫描输出有误"
            )
        }

        var raw=parameters
        raw.sourceOutputCCTFEncoding=false
        let linearOutput=try render(raw)
        let linearTap=try stage(taps,"scannerLinear",channels)
        guard linearOutput.rgb==linearTap else {
            throw Failure.invalid(
                "Build88 output_cctf_encoding=false 未输出原版线性 RGB"
            )
        }
        for i in 0..<channels {
            let expected=OriginalScannerMath.encodeSRGB(linearOutput.rgb[i])
            guard expected.isFinite,
                  abs(expected-encoded.rgb[i])<=2e-12 else {
                throw Failure.invalid(
                    "Build88 扫描输出 CCTF 开关顺序不等价 \(i)"
                )
            }
        }

        // Source ScannerStage: calibrated B/W XYZ first, seeded
        // lognormal glare IN XYZ next, only then XYZ→linear RGB+ACES.
        var calibrated=parameters
        calibrated.sourceColorReference.blackCorrection=true
        calibrated.sourceColorReference.whiteCorrection=true
        calibrated.scannerGlare=OriginalSourceScannerGlare.Settings(
            active:true,percent:0.035,roughness:0.7,blur:3.3
        )
        calibrated.scannerGlareSeed=8888
        let mixed=try render(calibrated)
        let resultDensity=try stage(taps,"density",channels)
        let observedXYZ=try stage(taps,"scannerGlareXYZ",channels)
        let observedLinear=try stage(
            taps,"scannerGlareLinearRGB",channels
        )
        let engine=try calibrated.createEngine()
        let lamp=try engine.sourceSpatialScannerIlluminantXYZ()
        let field=try OriginalSourceScannerGlare.computeAmount(
            width:width,height:height,
            settings:calibrated.scannerGlare,
            controlledSeed:calibrated.scannerGlareSeed
        )
        var maxXYZ=0.0,maxLinear=0.0
        for p in 0..<(width*height) {
            let k=p*3
            let correctedReference=try engine.sourceSpatialScanXYZ(
                filmDensity:Array(resultDensity[k..<k+3]),
                paperEV:calibrated.paperEV
            )
            let expected=(0..<3).map {
                correctedReference[$0]+field[p]*lamp[$0]
            }
            let linearRGB=try engine.sourceSpatialXYZToLinearRGB(
                expected
            )
            for ch in 0..<3 {
                let delta=abs(observedXYZ[k+ch]-expected[ch])
                let linearDelta=abs(observedLinear[k+ch]-linearRGB[ch])
                maxXYZ=max(maxXYZ,delta)
                maxLinear=max(maxLinear,linearDelta)
                guard delta<=1e-11,linearDelta<=1e-11 else {
                    throw Failure.invalid(
                        "Build88 先 BW 后 XYZ 眩光/色彩转换 p\(p)c\(ch)"
                    )
                }
            }
        }
        let repeatMixed=try render(calibrated)
        guard repeatMixed.rgb==mixed.rgb,
              mixed.rgb!=encoded.rgb else {
            throw Failure.invalid(
                "Build88 受控 XYZ 眩光与黑白校准未改变输出或不能重放"
            )
        }

        // Direct positive scan skips the enlarger. It also supports
        // source LINEAR RGB output rather than unconditionally sRGB CCTF.
        var direct=OriginalSourcePhysicalImage.Parameters(
            filmID:"fujifilm_provia_100f",
            paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,dir:dir,
            print:OriginalPrintOptics.Settings(enabled:false),
            morph:OriginalPrintMorph.Settings()
        )
        direct.sourceOutputCCTFEncoding=false
        let positive=try render(direct)
        guard positive.rgb.count==channels,
              positive.rgb.allSatisfy({$0.isFinite}),
              taps["paperLogExposure"]==nil else {
            throw Failure.invalid(
                "Build88 正片未从摄影直扫输出线性 RGB"
            )
        }

        return "Build88 生产源扫描 9×7：真实 81nm 相纸 XYZ→ACES 线性 RGB" +
               "→FIR/YVV 镜头及锐化→可选 sRGB CCTF；" +
               "BW 参考→XYZ Numba 眩光→ACES 的次序和显式 seed=8888 " +
               "重放一致；正片直接扫描不走相纸。" +
               "XYZ 最大分段误差 \(maxXYZ)，线性 \(maxLinear)。" +
               "【范围】这只是已编写的 App 内自检，不是本次已执行" +
               " iPhoneOS 真机数值、原版默认多线程 RNG 或 8MP 整图认证。"
    }
}
