import Foundation

/// Build87 app-resident production probe. These are ACTUAL
/// OriginalSourcePhysicalImage.develop calls, never mocked reference math.
/// Not a substitute for Python source whole-RGB or real iPhone execution.
enum Build87PrintScanProductionDiagnostic {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(v)=self{return v}
            return nil
        }
    }
    private static func finite(
        _ stages:[String:[Double]],_ name:String,_ count:Int
    ) throws -> [Double] {
        guard let samples=stages[name],samples.count==count,
              samples.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Build87 缺少正式处理路径 "+name)
        }
        return samples
    }
    static func evaluate() throws -> String {
        let w=12,h=10,channels=w*h*3
        let image=OriginalSourcePixelIO.Frame(
            width:w,height:h,
            rgb:(0..<(w*h)).flatMap{p in
                (0..<3).map{ch in
                    Double((p*17+ch*57+13+(p/w)*19)%256)/255.0
                }
            }
        )
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        dir.referencePixelSizeUM=0.5
        let negative=OriginalSourcePhysicalImage.Parameters(
            filmID:"kodak_portra_400",paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,dir:dir,
            print:OriginalPrintOptics.Settings(enabled:true),
            morph:OriginalPrintMorph.Settings()
        )
        var taps=[String:[Double]]()
        func imageRun(_ settings:OriginalSourcePhysicalImage.Parameters) throws
            -> OriginalSourcePixelIO.Frame {
            try OriginalSourcePhysicalImage.develop(
                image,parameters:settings,
                stageDoubleObserver:{name,samples in taps[name]=samples}
            )
        }
        let untreated=try imageRun(negative)
        let originalFilm=try finite(taps,"density",channels)
        let basePaper=try finite(taps,"paperLogExposure",channels)
        _=try finite(taps,"paperDevelopedDensity",channels)
        _=try finite(taps,"printed",channels)

        var changedModes=0
        for (black,white) in [(true,false),(false,true),(true,true)] {
            var p=negative
            p.sourceColorReference.blackCorrection=black
            p.sourceColorReference.whiteCorrection=white
            taps.removeAll()
            let out=try imageRun(p)
            let film=try finite(taps,"density",channels)
            let paper=try finite(taps,"paperLogExposure",channels)
            let developed=try finite(taps,"paperDevelopedDensity",channels)
            let scanned=try finite(taps,"printed",channels)
            guard film==originalFilm,paper != basePaper,
                  developed.count==channels,
                  out.rgb==scanned,
                  out.rgb != untreated.rgb else {
                throw Failure.invalid(
                    "Build87 负片黑白校准没有在相纸/XYZ 正确阶段改变生产输出"
                )
            }
            let again=try imageRun(p)
            guard again.rgb==out.rgb else {
                throw Failure.invalid("Build87 黑白曝光校准非确定性或缓存状态不正确")
            }
            changedModes+=1
        }

        // Positive stocks never visit the enlarger. The same reference
        // settings must change camera-film exposure, not paper H-D.
        let positive=OriginalSourcePhysicalImage.Parameters(
            filmID:"fujifilm_provia_100f",paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,dir:dir,
            print:OriginalPrintOptics.Settings(enabled:false),
            morph:OriginalPrintMorph.Settings()
        )
        taps.removeAll()
        let direct=try imageRun(positive)
        guard taps["paperLogExposure"]==nil else {
            throw Failure.invalid("Build87 正片错误地进入光学放大机")
        }
        var positiveReference=positive
        positiveReference.sourceColorReference.blackCorrection=true
        positiveReference.sourceColorReference.whiteCorrection=true
        taps.removeAll()
        let calibrated=try imageRun(positiveReference)
        let calibratedFilm=try finite(taps,"density",channels)
        guard calibrated.rgb != direct.rgb,
              calibratedFilm.allSatisfy({$0.isFinite}),
              taps["paperLogExposure"]==nil else {
            throw Failure.invalid(
                "Build87 原版正片拍摄曝光校准没有进入直扫路径"
            )
        }

        var forbidden=negative
        forbidden.sourceColorReference.blackCorrection=true
        forbidden.scannerGlare.active=true
        forbidden.scannerGlare.percent=0.1
        forbidden.scannerGlareSeed=8888
        do {
            _=try imageRun(forbidden)
            throw Failure.invalid("Build87 黑白校准静默与未认证扫描眩光混合")
        } catch OriginalSourcePhysicalImage.Failure.invalid(_) {}
        return "Build87 原版冲印真实生产链：12×10，三种负片黑白参考组合" +
            "→256 节点相纸曝光→光谱 XYZ 校正→输出；正片在 Hanatos 曝光前校准" +
            "→直接扫描，不调用相纸；所有输出有限、可复现；未认证的眩光组合拒绝。" +
            "【范围】仅 App 诊断实现，非本轮 iPhone 真机执行或独立 Python 整图认证。"
    }
}
