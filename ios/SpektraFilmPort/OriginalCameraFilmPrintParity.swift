import Foundation

/// Runs actual Swift production Hanatos 2025 (Float64 and Float16 variants),
/// camera exposure, measured negative H-D / nonspatial DIR, optical print,
/// absolute paper CDF H-D and source XYZ/ACES/sRGB, against upstream Python
/// source references generated at CI build from actual source functions.
enum OriginalCameraFilmPrintParity {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(s)=self { return s }
            return nil
        }
    }

    private struct Metric {
        var sum:Double=0
        var squares:Double=0
        var max:Double=0
        var outside:Int=0
        var worst:String=""
        mutating func observe(
            source:Double,native:Double,label:String
        ) throws {
            guard source.isFinite && native.isFinite else {
                throw Failure.invalid("Hanatos 连续链检测出现 NaN/Inf：" + label)
            }
            let delta=abs(source-native)
            sum+=delta
            squares+=delta*delta
            if delta>max { max=delta;worst=label+" Python=\(source) Swift=\(native)" }
            if delta>0.002 { outside+=1 }
        }
        func describe(_ title:String,_ channels:Int)->String {
            let n=Double(channels)
            return "\(title): MAE=\(sum/n), RMSE=\(sqrt(squares/n)), " +
                   "max=\(max), 超限=\(outside)/\(channels), worst=\(worst)"
        }
    }

    struct Result {
        let channels:Int
        let preciseStageExceed:Int
        let preciseOutputExceed:Int
        let preciseMAE:Double
        let preciseRMSE:Double
        let preciseMax:Double
        let mobileStageExceed:Int
        let mobileOutputExceed:Int
        let mobileMax:Double
        let text:String
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
        case "fast_slow":s.fast=1.20;s.slow=0.85
        case "rgb":s.red=1.10;s.green=0.93;s.blue=1.15
        default:throw Failure.invalid("未知原版打印 H-D 设置："+key)
        }
        return s
    }

    static func evaluate() throws -> Result {
        let vectors=GeneratedSourceCameraFilmPrintReference.vectors
        guard vectors.count==24 else {
            throw Failure.invalid("源 Hanatos→负片→相纸参考组数不是 24")
        }
        let names=[
            "Hanatos 光谱感光 RAW",
            "拍摄 EV→胶片 log10 RAW",
            "负片初始 H-D CMY",
            "DIR 抑制修正 logE",
            "负片最终显影 CMY",
            "原版放大机光学 RAW",
            "相纸 logE",
            "相纸三层绝对 CDF H-D",
            "光谱扫描 XYZ",
            "线性 sRGB",
            "ACES RGC",
            "display sRGB CCTF",
            "生产 sRGB 输入→最终 RGB"
        ]
        var stats=Array(
            repeating:Array(repeating:Metric(),count:names.count),
            count:2
        )
        var engines=[[String:SpectralPhysics](),[String:SpectralPhysics]()]
        for (index,v) in vectors.enumerated() {
            guard v.linearRGB.count==3 && v.encodedInputRGB.count==3 &&
                  v.shift.count==3 else {
                throw Failure.invalid("源 Hanatos 数据形状错误")
            }
            let key="\(v.film)|\(v.paper)|\(v.morphMode)|\(v.shift)|" +
                    "\(v.preflashExposure)|\(v.preflashM)|\(v.preflashY)"
            let source=[
                v.sourceHanatosRaw,v.sourceFilmLogRaw,
                v.sourceInitialFilmDensity,v.sourceDIRCorrectedLogRaw,
                v.sourceFilmDevelopedDensity,v.sourcePrintRaw,
                v.sourcePaperLogExposure,v.sourcePaperDensity,
                v.sourceXYZ,v.sourceLinearRGB,v.sourceACES,
                v.sourceEncodedRGB,v.sourceEncodedRGB
            ]
            for mode in 0..<2 {
                let precision:OriginalHanatosResponse.Precision =
                    mode==0 ? .originalFloat64 : .mobileFloat16
                let engine:SpectralPhysics
                if let existing=engines[mode][key] { engine=existing }
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
                        cam16Gamut:false,printReferenceCorrection:false,
                        printMorph:try morph(v.morphMode),
                        printOptics:print,hanatosPrecision:precision
                    )
                    engines[mode][key]=engine
                }
                let full=try engine.sourceCameraFilmPrintStages(
                    linearRGB:v.linearRGB,cameraEV:v.cameraEV,
                    paperEV:v.paperEV
                )
                let film=full.developed.filmDIR
                let paper=full.developed.printStages
                let production=engine.render(
                    v.encodedInputRGB,exposureEV:v.cameraEV,
                    paperEV:v.paperEV
                )
                let native=[
                    full.hanatosRaw,full.filmLogRaw,
                    film.initialDensity,film.correctedLogRaw,
                    film.developedDensity,paper.enlargerRaw,
                    paper.paperLogExposure,paper.paperDensity,
                    paper.xyz,paper.linear,paper.compressed,
                    paper.encoded,production
                ]
                guard native.count==source.count else {
                    throw Failure.invalid("Hanatos 连续阶段数量不一致")
                }
                for stage in 0..<source.count {
                    guard source[stage].count==3 &&
                          native[stage].count==3 else {
                        throw Failure.invalid("Hanatos 源/本机颜色通道不为三个")
                    }
                    for ch in 0..<3 {
                        try stats[mode][stage].observe(
                            source:source[stage][ch],
                            native:native[stage][ch],
                            label:"\(v.film)/\(v.paper) case#\(index) ch\(ch)"
                        )
                    }
                }
            }
        }
        let channels=vectors.count*3
        let exact=stats[0],fast=stats[1]
        let exactStageExceed=exact.reduce(0) { $0+$1.outside }
        let fastStageExceed=fast.reduce(0) { $0+$1.outside }
        let exactDetails=names.indices.map {
            exact[$0].describe(names[$0],channels)
        }.joined(separator:"\n")
        let fastDetails=names.indices.map {
            fast[$0].describe(names[$0],channels)
        }.joined(separator:"\n")
        let summary="""
            Python 原版 Hanatos 2025→拍摄 EV→负片 H-D/DIR→相纸 CDF H-D→ACES RGB
            24 色光谱组合 × 3 = \(channels) 通道，13 个连续计算与生产预览阶段。
            【原版 Float64 光谱 LUT】最终 sRGB：
            MAE=\(exact[11].sum/Double(channels)), RMSE=\(sqrt(exact[11].squares/Double(channels))),
            max=\(exact[11].max), 超限=\(exact[11].outside)/\(channels)，
            十三阶段总超限=\(exactStageExceed)（阈值 0.002）。
            \(exactDetails)

            【移动快速 Float16 光谱 LUT】对照同一源 Python Float64：
            最终 sRGB max=\(fast[11].max), 超限=\(fast[11].outside)/\(channels)，
            十三阶段总超限=\(fastStageExceed)。
            这是单独标记的量化性能结果，不冒充原版数值认证。
            \(fastDetails)
            注意：输入为线性 sRGB 样本，扫描/印相使用原版光学 ACES
            无归一化参考配置；不包含 RAW 解码、空间 DIR、Numba 随机颗粒、
            图像逐像素、边缘散射或全精度整图渲染。
            """
        return Result(
            channels:channels,preciseStageExceed:exactStageExceed,
            preciseOutputExceed:exact[11].outside,
            preciseMAE:exact[11].sum/Double(channels),
            preciseRMSE:sqrt(exact[11].squares/Double(channels)),
            preciseMax:exact[11].max,
            mobileStageExceed:fastStageExceed,
            mobileOutputExceed:fast[11].outside,
            mobileMax:fast[11].max,text:summary
        )
    }
}
