import Foundation

/// Real original Python model/density_curves.py + couplers.py film H-D/DIR
/// (nonspatial, LUT-mode) followed by native production optics, source
/// 256-point s023 paper CDF and print scan RGB. Input is already-film log
/// exposure: explicitly NOT camera RAW, spatial DIR/grain or whole image.
enum OriginalFilmDIRPrintParity {
    struct Result {
        let channels:Int
        let stageOutsideTolerance:Int
        let outputOutsideTolerance:Int
        let outputMAE:Double
        let outputRMSE:Double
        let outputMax:Double
        let stageDetails:String

        var text:String {
            """
            源 Python 负片 H-D＋非空间 DIR→相纸→RGB 连续对照：\(channels) 通道
            入口：相机曝光后的胶片 log10 RAW（不含相机 RAW/色彩输入）。
            负片实测 H-D→源 DIR 抑制 logE→修正负片密度→放大机→
            相纸三层 CDF H-D→扫描 XYZ→ACES RGC→最终 sRGB。
            最终 sRGB MAE=\(outputMAE), RMSE=\(outputRMSE), max=\(outputMax),
            误差大于 0.002：\(outputOutsideTolerance)/\(channels)。
            全部阶段超限数：\(stageOutsideTolerance)，阈值=0.002。
            \(stageDetails)
            注意：不含 Hanatos 原始相机光谱曝光、空间 DIR、随机颗粒、
            Float64 整图精度、RAW 或照片 JPEG；非整图认证。
            """
        }
    }

    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(v)=self { return v }
            return nil
        }
    }

    private static func morph(_ key:String) throws -> OriginalPrintMorph.Settings {
        var s=OriginalPrintMorph.Settings()
        switch key {
        case "neutral": break
        case "gamma_082": s.gamma=0.82
        case "exhaustion_04": s.developerExhaustion=0.4
        case "mixed":
            s.gamma=1.13;s.fast=0.93;s.slow=1.07
            s.red=1.04;s.green=0.94;s.blue=1.08
            s.developerExhaustion=0.25
        case "fast_slow": s.fast=1.20;s.slow=0.85
        case "rgb": s.red=1.10;s.green=0.93;s.blue=1.15
        default: throw Failure.invalid("未知原版相纸 CDF 调整模式："+key)
        }
        return s
    }

    static func evaluate() throws -> Result {
        let vectors=GeneratedSourceFilmDIRPrintReference.vectors
        guard vectors.count==18 else {
            throw Failure.invalid("源负片 H-D/DIR→相纸参考数据不是 18 组")
        }
        let labels=[
            "胶片实测 H-D 初始 CMY",
            "源 DIR 抑制修正 logE",
            "负片显影 DIR 后 CMY",
            "放大机 RAW 光学曝光",
            "相纸 logE",
            "相纸源三层 CDF H-D CMY",
            "相纸扫描光谱 XYZ",
            "线性 sRGB",
            "ACES RGC",
            "display sRGB CCTF"
        ]
        var sum=[Double](repeating:0,count:10)
        var square=[Double](repeating:0,count:10)
        var maximum=[Double](repeating:0,count:10)
        var outside=[Int](repeating:0,count:10)
        var worst=[String](repeating:"",count:10)
        var engines=[String:SpectralPhysics]()
        for (i,v) in vectors.enumerated() {
            guard v.filmLogRaw.count==3 &&
                  v.shift.count==3 else {
                throw Failure.invalid("原版负片显影参考数据尺寸错误")
            }
            let key="\(v.film)|\(v.paper)|\(v.morphMode)|\(v.shift)|" +
                "\(v.preflashExposure)|\(v.preflashM)|\(v.preflashY)"
            let engine:SpectralPhysics
            if let existing=engines[key] { engine=existing }
            else {
                let print=OriginalPrintOptics.Settings(
                    enabled:true,normalizePrintExposure:false,
                    printExposureCompensation:false,
                    cyanShift:v.shift[0],magentaShift:v.shift[1],
                    yellowShift:v.shift[2],
                    preflashExposure:v.preflashExposure,
                    preflashMagentaShift:v.preflashM,
                    preflashYellowShift:v.preflashY
                )
                engine=try SpectralPhysics(
                    filmID:v.film,paperID:v.paper,
                    sourceScanner:true,scannerBlackWhite:false,
                    cam16Gamut:false,
                    printReferenceCorrection:false,
                    printMorph:try morph(v.morphMode),
                    printOptics:print
                )
                engines[key]=engine
            }
            let actual=try engine.sourceFilmDIRPrintStages(
                v.filmLogRaw,paperEV:v.ev
            )
            let film=actual.filmDIR
            let paper=actual.printStages
            let observed=[
                film.initialDensity,film.correctedLogRaw,film.developedDensity,
                paper.enlargerRaw,paper.paperLogExposure,paper.paperDensity,
                paper.xyz,paper.linear,paper.compressed,paper.encoded
            ]
            let source=[
                v.initialFilmDensity,v.dirCorrectedLogRaw,
                v.sourceDevelopedFilmDensity,
                v.sourceRaw,v.sourceLogExposure,v.sourcePaperDensity,
                v.sourceXYZ,v.sourceLinearRGB,v.sourceCompressedRGB,
                v.sourceEncodedDisplayRGB
            ]
            for stage in 0..<10 {
                guard observed[stage].count==3 &&
                      source[stage].count==3 else {
                    throw Failure.invalid("负片→相纸源数值阶段尺寸错误")
                }
                for ch in 0..<3 {
                    let expected=source[stage][ch],value=observed[stage][ch]
                    guard expected.isFinite && value.isFinite else {
                        throw Failure.invalid("负片→相纸源数值出现 NaN 或 Inf")
                    }
                    let diff=abs(value-expected)
                    sum[stage]+=diff
                    square[stage]+=diff*diff
                    if diff>maximum[stage] {
                        maximum[stage]=diff
                        worst[stage]="\(v.film)/\(v.paper) #\(i) ch\(ch) " +
                            "Python=\(expected) Swift=\(value)"
                    }
                    if diff>0.002 { outside[stage]+=1 }
                }
            }
        }
        let n=Double(vectors.count*3)
        let details=(0..<10).map { stage in
            "\(labels[stage]): MAE=\(sum[stage]/n), " +
            "RMSE=\(sqrt(square[stage]/n)), " +
            "max=\(maximum[stage]), 超限=\(outside[stage])/\(Int(n)), " +
            "worst=\(worst[stage])"
        }.joined(separator:"\n")
        return Result(
            channels:Int(n),
            stageOutsideTolerance:outside.reduce(0,+),
            outputOutsideTolerance:outside[9],
            outputMAE:sum[9]/n,
            outputRMSE:sqrt(square[9]/n),
            outputMax:maximum[9],
            stageDetails:details
        )
    }
}
