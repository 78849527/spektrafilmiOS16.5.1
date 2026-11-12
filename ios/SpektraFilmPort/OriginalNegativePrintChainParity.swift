import Foundation

/// Source-contiguous post-film-development (already-developed CMY) proof.
/// Each vector crosses negative dye absorption, paper exposure, fitted H-D
/// and paper XYZ -> ACES / sRGB through the same production functions.
enum OriginalNegativePrintChainParity {
    struct Result {
        let channels: Int
        let outputOutsideTolerance: Int
        let stageOutsideTolerance: Int
        let outputMAE: Double
        let outputRMSE: Double
        let outputMax: Double
        let stageDetails: String

        var text: String {
            """
            Python 原版负片→相纸 H-D→RGB 连续光学链：\(channels) RGB 通道
            入口：已显影胶片 CMY 密度；包含负片染料、原版放大机曝光、
            预闪光、256 节点 CDF 相纸显影、相纸光谱扫描 XYZ/ACES/sRGB。
            最终 display sRGB MAE=\(outputMAE)，RMSE=\(outputRMSE)，
            max=\(outputMax)，超过 0.002：\(outputOutsideTolerance)/\(channels)
            中间阶段超限数=\(stageOutsideTolerance)（阈值 0.002）
            \(stageDetails)
            不含相机 RAW、负片 H-D/DIR、空间扩散、随机颗粒或整幅图。
            """
        }
    }

    enum Error: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    private static func morph(_ key: String) throws -> OriginalPrintMorph.Settings {
        var s=OriginalPrintMorph.Settings()
        switch key {
        case "neutral": break
        case "gamma_082": s.gamma=0.82
        case "exhaustion_04": s.developerExhaustion=0.4
        case "mixed":
            s.gamma=1.13; s.fast=0.93; s.slow=1.07
            s.red=1.04; s.green=0.94; s.blue=1.08
            s.developerExhaustion=0.25
        case "fast_slow": s.fast=1.20; s.slow=0.85
        case "rgb": s.red=1.10; s.green=0.93; s.blue=1.15
        default: throw Error.invalid("未知原版相纸 morph 配置：" + key)
        }
        return s
    }

    static func evaluate() throws -> Result {
        let vectors=GeneratedSourceNegativePrintChainReference.vectors
        guard vectors.count == 18 else {
            throw Error.invalid("负片相纸整链源参考必须为 6 组 × 3 密度")
        }
        let labels=["放大机原始曝光", "相纸 logE", "相纸 CDF H-D",
                    "光谱 XYZ", "线性 sRGB", "ACES RGC",
                    "display sRGB CCTF"]
        var sum=[Double](repeating:0,count:7)
        var square=[Double](repeating:0,count:7)
        var maxError=[Double](repeating:0,count:7)
        var outside=[Int](repeating:0,count:7)
        var worst=[String](repeating:"",count:7)
        var engines=[String:SpectralPhysics]()
        for (i,v) in vectors.enumerated() {
            let key=v.film + "|" + v.paper + "|" + v.morphMode +
                "|" + v.shift.map(String.init(describing:)).joined(separator:",")
            let engine:SpectralPhysics
            if let cached=engines[key] { engine=cached }
            else {
                let print=OriginalPrintOptics.Settings(
                    enabled:true,
                    normalizePrintExposure:false,
                    printExposureCompensation:false,
                    cyanShift:v.shift[0],
                    magentaShift:v.shift[1],yellowShift:v.shift[2],
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
            let actual=try engine.sourceNegativePrintStages(
                v.filmDensity,paperEV:v.ev
            )
            let observed=[actual.enlargerRaw,actual.paperLogExposure,
                          actual.paperDensity,actual.xyz,actual.linear,
                          actual.compressed,actual.encoded]
            let source=[v.sourceRaw,v.sourceLogExposure,
                        v.sourcePaperDensity,v.sourceXYZ,
                        v.sourceLinearRGB,v.sourceCompressedRGB,
                        v.sourceEncodedDisplayRGB]
            for stage in 0..<7 {
                guard observed[stage].count == 3 &&
                      source[stage].count == 3 else {
                    throw Error.invalid("原版连续链阶段维度错误")
                }
                for ch in 0..<3 {
                    let expected=source[stage][ch], found=observed[stage][ch]
                    guard expected.isFinite && found.isFinite else {
                        throw Error.invalid("负片相纸原版连续链产生非有限数值")
                    }
                    let err=abs(found-expected)
                    sum[stage]+=err
                    square[stage]+=err*err
                    if err>maxError[stage] {
                        maxError[stage]=err
                        worst[stage]="\(v.film)/\(v.paper) route#\(i) ch\(ch) " +
                            "source=\(expected) Swift=\(found)"
                    }
                    // No tolerance weakening for H-D or colour stages:
                    // Float32 measured spectra have an explicit 0.002 cap.
                    if err>0.002 { outside[stage]+=1 }
                }
            }
        }
        let n=Double(vectors.count*3)
        let text=(0..<7).map { stage in
            "\(labels[stage]): MAE=\(sum[stage]/n), " +
            "RMSE=\(sqrt(square[stage]/n)), max=\(maxError[stage]), " +
            "超限=\(outside[stage])/\(Int(n)), worst=\(worst[stage])"
        }.joined(separator:"\n")
        return Result(
            channels:Int(n),outputOutsideTolerance:outside[6],
            stageOutsideTolerance:outside.reduce(0,+),
            outputMAE:sum[6]/n,outputRMSE:sqrt(square[6]/n),
            outputMax:maxError[6],stageDetails:text
        )
    }
}
