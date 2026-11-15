import Foundation

/// Real source physical IMAGE production diagnostic, NOT a substitute for
/// an independent Python RAW→negative→print→scanner whole-image tape.
/// All operations below call OriginalSourcePhysicalImage.develop directly.
/// Does NOT alter the existing Metal 8/8 device certification count.
enum Build89OutputGamutProductionDiagnostic {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self{return s}
            return nil
        }
    }
    private static func fetch(
        _ records:[String:[Double]],_ name:String,_ count:Int
    ) throws->[Double] {
        guard let a=records[name],a.count==count,
              a.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "Build89 实际光谱图像的 \(name) 源数值阶段丢失／非有限"
            )
        }
        return a
    }
    static func evaluate() throws->String {
        let width=7,height=5,count=width*height*3
        let frame=OriginalSourcePixelIO.Frame(
            width:width,height:height,
            rgb:(0..<(width*height)).flatMap {p in
                (0..<3).map {ch in
                    Double((p*17+ch*61+31)%227+12)/255.0
                }
            }
        )
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        dir.referencePixelSizeUM=35
        var p=OriginalSourcePhysicalImage.Parameters(
            filmID:"kodak_portra_400",
            paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,dir:dir,
            print:OriginalPrintOptics.Settings(enabled:true),
            morph:OriginalPrintMorph.Settings()
        )
        p.sourceOutputCCTFEncoding=false
        var taps=[String:[Double]]()
        func render(_ config:OriginalSourcePhysicalImage.Parameters)throws
            -> OriginalSourcePixelIO.Frame {
            taps.removeAll(keepingCapacity:true)
            return try OriginalSourcePhysicalImage.develop(
                frame,parameters:config,
                stageDoubleObserver:{label,data in taps[label]=data}
            )
        }

        // 1. Original OFF is true no-op for all three LINEAR RGB values,
        // never a hidden 33³ RGB LUT or per-channel [0,1] clamp.
        var off=Build89OriginalOutputGamut.Settings()
        off.algorithm = .off
        p.sourceOutputGamut=off
        let offFrame=try render(p)
        let offLinear=try fetch(taps,"sourceGamutLinear",count)
        let developedDensity=try fetch(taps,"density",count)
        guard offFrame.rgb==offLinear else {
            throw Failure.invalid(
                "Build89 source OFF／output_cctf_encoding=false 仍修改线性 RGB"
            )
        }

        // Confirm the observed actual photon-derived XYZ input and
        // selected source Gamut are in the CORRECT stage order.
        let engine=try p.createEngine()
        var worst=0.0
        for pix in 0..<(width*height) {
            let k=pix*3
            let xyz=try engine.sourceSpatialScanXYZ(
                filmDensity:Array(developedDensity[k..<k+3]),
                paperEV:p.paperEV
            )
            let linear=try engine.sourceSpatialXYZToRawLinearRGB(xyz)
            for ch in 0..<3 {
                worst=max(worst,abs(linear[ch]-offLinear[k+ch]))
            }
        }
        guard worst<=2e-11 else {
            throw Failure.invalid(
                "Build89 原片 XYZ→原版 RAW linear RGB 被旧 ACES／33³ LUT 污染"
            )
        }

        // 2. Original ACES source with nondefault threshold/limit/power.
        var aces=off
        aces.algorithm = .acesRGC
        aces.knee.threshold=0.23
        aces.knee.limit=1.1
        aces.knee.power=2.7
        p.sourceOutputGamut=aces
        let acesFrame=try render(p)
        let acesLinear=try fetch(taps,"sourceGamutLinear",count)
        for pix in 0..<(width*height) {
            let k=pix*3
            let expected=try Build89OriginalOutputGamut.compress(
                Array(offLinear[k..<k+3]),settings:aces
            )
            for ch in 0..<3 {
                worst=max(worst,abs(expected[ch]-acesLinear[k+ch]))
            }
        }
        guard worst<=2e-11,acesFrame.rgb==acesLinear else {
            throw Failure.invalid("Build89 自定义源 ACES 在错误阶段执行")
        }

        // 3. True default CAM16-UCS: first actual per-pixel
        // RGB→XYZ→CAM16UCS→source Cmax→inverse XYZ→output RGB.
        var cam=Build89OriginalOutputGamut.Settings()
        cam.algorithm = .cam16UCS
        p.sourceOutputGamut=cam
        let camFrame=try render(p)
        let camLinear=try fetch(taps,"sourceGamutLinear",count)
        var countChecked=0
        for pix in 0..<(width*height) {
            let k=pix*3
            let expected=try Build89OriginalOutputGamut.compress(
                Array(offLinear[k..<k+3]),settings:cam
            )
            for ch in 0..<3 {
                worst=max(worst,abs(expected[ch]-camLinear[k+ch]))
            }
            countChecked+=1
        }
        guard camFrame.rgb==camLinear,worst<=2e-11 else {
            throw Failure.invalid("Build89 实际源 CAM16 Float64 路径错误")
        }
        p.sourceOutputCCTFEncoding=true
        let encoded=try render(p)
        for pix in 0..<(width*height) {
            let k=pix*3
            let expected=OriginalScannerMath.sourceCCTFEncoding(
                Array(camLinear[k..<k+3])
            )
            for ch in 0..<3 {
                let delta=abs(expected[ch]-encoded.rgb[k+ch])
                worst=max(worst,delta)
                guard delta<=2e-11 else {
                    throw Failure.invalid(
                        "Build89 默认 CAM16 原版 CCTF 色彩矩阵顺序错误"
                    )
                }
            }
        }

        // 4. Source lightness + B/W reference + true XYZ glare must
        // be before output gamut and scanner Gaussian, not on sRGB.
        p.sourceColorReference.blackCorrection=true
        p.sourceColorReference.whiteCorrection=true
        p.scannerGlare=OriginalSourceScannerGlare.Settings(
            active:true,percent:0.035,roughness:0.7,blur:0.5
        )
        p.scannerGlareSeed=8888
        p.scannerOptics.lensBlurSigma=0.7
        p.scannerOptics.unsharpSigma=3.2
        p.scannerOptics.unsharpAmount=1.2
        let mixed=try render(p)
        let tapXYZ=try fetch(taps,"scannerGlareXYZ",count)
        let beforeOptics=try fetch(taps,"sourceGamutLinear",count)
        let finished=try fetch(taps,"scannerLinear",count)
        let compareEngine=try p.createEngine()
        for pix in 0..<(width*height) {
            let k=pix*3
            let raw=try compareEngine.sourceSpatialXYZToRawLinearRGB(
                Array(tapXYZ[k..<k+3])
            )
            let expected=try Build89OriginalOutputGamut.compress(
                raw,settings:cam
            )
            for ch in 0..<3 {
                worst=max(worst,abs(expected[ch]-beforeOptics[k+ch]))
            }
        }
        guard worst<=2e-11,
              beforeOptics != finished else {
            throw Failure.invalid(
                "Build89 源扫描 XYZ 眩光→CAM16→镜头 FIR/YVV 顺序错误"
            )
        }
        let repeated=try render(p)
        guard repeated.rgb==mixed.rgb else {
            throw Failure.invalid(
                "Build89 单线程控制 Numba glare 不可位级重放"
            )
        }

        // 5. Source numeric Display P3 may be independently compared,
        // but current JPEG exporter has no calibrated ICC: fail closed.
        var untagged=p
        var wide=cam
        wide.outputSpace = .displayP3
        untagged.sourceOutputGamut=wide
        do {
            _=try render(untagged)
            throw Failure.invalid(
                "Build89 未写 ICC 的广色域输出被误当 sRGB JPEG"
            )
        } catch OriginalSourcePhysicalImage.Failure.invalid(_) {}

        return "Build89 真实全图光谱处理 \(width)×\(height)：" +
            "胶片→原版印相 XYZ→Raw Linear RGB→OFF／自定义 ACES／" +
            "默认 CAM16-UCS Float64 原生逐像素→原版矩阵 CCTF；" +
            "组合 B/W→受控 XYZ glare→CAM16→镜头 FIR/YVV 顺序通过，" +
            "固定 seed=8888 可重复；最大生产阶段差 \(worst)。" +
            "数值广色域但未获 ICC 的 JPEG 显式拒绝。" +
            "【认证边界】App 自检代码已提供，不等于已经完成真机运行、" +
            "原版无种子多 worker RNG 或 12MP 独立 Python 整幅对照。"
    }
}
