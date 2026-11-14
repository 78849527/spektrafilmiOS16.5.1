import Foundation

/// On-device smoke of the ACTUAL nonlinear SpectralPhysics full-size
/// source-physical image path, not a simulated RGB colour overlay.
/// This is intentionally a tiny fixed 7x5 two-dimensional frame, so an
/// A15 iPhone can measure correct stage topology without memory risk.
/// No independent upstream whole-image RGB fixture is claimed here.
enum OriginalSourceScannerGlareProductionDiagnostic {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    static func evaluate() throws -> String {
        let w=7,h=5
        var rgb=[Double](repeating:0,count:w*h*3)
        for p in 0..<(w*h) {
            rgb[p*3] = 0.08+0.008*Double(p%17)
            rgb[p*3+1] = 0.11+0.007*Double(p%19)
            rgb[p*3+2] = 0.13+0.006*Double(p%23)
        }
        let input=OriginalSourcePixelIO.Frame(
            width:w,height:h,rgb:rgb
        )
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        dir.referencePixelSizeUM=45
        var params=OriginalSourcePhysicalImage.Parameters(
            filmID:"kodak_portra_400",paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,
            dir:dir,print:OriginalPrintOptics.Settings(enabled:true),
            morph:OriginalPrintMorph.Settings()
        )
        // Explicit old baseline must remain untouched when glare is OFF.
        let noGlare=try OriginalSourcePhysicalImage.develop(
            input,parameters:params
        )
        params.scannerGlare = OriginalSourceScannerGlare.Settings(
            active:true,percent:0.03,roughness:0.7,blur:0.5
        )
        params.scannerGlareSeed=8888
        var traces=[String:[Double]]()
        let actual=try OriginalSourcePhysicalImage.develop(
            input,parameters:params,stageDoubleObserver: {
                stage,pixels in traces[stage]=pixels
            }
        )
        let repeated=try OriginalSourcePhysicalImage.develop(
            input,parameters:params
        )
        guard actual.rgb==repeated.rgb,actual.rgb != noGlare.rgb,
              let density=traces["density"],
              let xyz=traces["scannerGlareXYZ"],
              let linear=traces["scannerGlareLinearRGB"],
              xyz.count==w*h*3,linear.count==w*h*3,
              density.count==w*h*3 else {
            throw Failure.invalid(
                "实际逐像素源扫描眩光没有进入生产 XYZ 通路或固定种子不可重复"
            )
        }
        let engine=try params.createEngine()
        let lamp=try engine.sourceSpatialScannerIlluminantXYZ()
        let field=try OriginalSourceScannerGlare.computeAmount(
            width:w,height:h,settings:params.scannerGlare,
            controlledSeed:params.scannerGlareSeed
        )
        var maximumXYZ=0.0,maximumLinear=0.0,maximumEncoded=0.0
        for p in 0..<(w*h) {
            let k=p*3
            let originalXYZ=try engine.sourceSpatialScanXYZ(
                filmDensity:Array(density[k..<(k+3)]),paperEV:0
            )
            let expectedXYZ=(0..<3).map {
                originalXYZ[$0]+field[p]*lamp[$0]
            }
            let expectedLinear=try engine.sourceSpatialXYZToLinearRGB(
                expectedXYZ
            )
            for ch in 0..<3 {
                let a=abs(expectedXYZ[ch]-xyz[k+ch])
                let b=abs(expectedLinear[ch]-linear[k+ch])
                let cc=abs(
                    OriginalScannerMath.encodeSRGB(expectedLinear[ch])
                    - actual.rgb[k+ch]
                )
                maximumXYZ=max(maximumXYZ,a)
                maximumLinear=max(maximumLinear,b)
                maximumEncoded=max(maximumEncoded,cc)
                guard a<=1e-11,b<=1e-11,cc<=1e-11 else {
                    throw Failure.invalid(
                        "实际源扫描眩光错误定位 p=\(p) c=\(ch)" +
                        " xyz=\(a) linear=\(b) sRGB=\(cc)"
                    )
                }
            }
        }
        // No silent choice of an unseeded/default pseudo RNG.
        params.scannerGlareSeed=nil
        do {
            _=try OriginalSourcePhysicalImage.develop(
                input,parameters:params
            )
            throw Failure.invalid("缺少 Numba 种子却被生产扫描入口静默接受")
        } catch OriginalSourcePhysicalImage.Failure.invalid {}

        return "真实 OriginalSourcePhysicalImage.develop 生产计算："
             + "\(w)×\(h) 负片→相纸光谱→整图 XYZ 受控眩光→"
             + "ACES 线性 RGB→sRGB，\(w*h*3) RGB 通道。"
             + "\n原版固定种子=8888，重复输出位级一致，"
             + "未开启眩光时保持原路线，缺少种子明确报错。"
             + "\nXYZ max=\(maximumXYZ)，线性 RGB max=\(maximumLinear)，"
             + "显示 sRGB max=\(maximumEncoded)（1e-11 同链路数值门限）。"
             + "\n【认证边界】真实生产 Swift 分段顺序和真机数值检查；"
             + "还不是独立 Python 原版整幅 RGB 比较、"
             + "无固定种子 Numba 多线程 RNG 或 RAW/JPEG 等价。"
    }
}
