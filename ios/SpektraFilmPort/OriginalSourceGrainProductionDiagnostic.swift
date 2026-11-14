import Foundation

/// Build74 real-iPhone CPU production diagnostic for the opt-in source
/// four-stage grain density chain. It exercises the SAME
/// OriginalSourcePhysicalImage.develop path as full-size export, before the
/// optical enlarger/paper/scanner. This is not an independent upstream Python
/// full-photo RGB certificate or an unseeded Numba prange replay.
enum OriginalSourceGrainProductionDiagnostic {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let value) = self { return value }
            return nil
        }
    }

    static func evaluate() throws -> String {
        let w=12,h=10
        let rgb=(0..<(w*h)).flatMap { p in
            (0..<3).map { ch in
                Double((19 + p*17 + ch*43 + (p/w)*31) % 256) / 255.0
            }
        }
        let source=OriginalSourcePixelIO.Frame(width:w,height:h,rgb:rgb)
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        dir.referencePixelSizeUM=0.35
        let baseline=OriginalSourcePhysicalImage.Parameters(
            filmID:"kodak_portra_400",
            paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,dir:dir,
            print:OriginalPrintOptics.Settings(enabled:true),
            morph:OriginalPrintMorph.Settings()
        )
        var enabled=baseline
        enabled.sourceGrain.active=true
        enabled.sourceGrain.numbaSeed=8888
        enabled.sourceGrain.microstructureUM=0.2
        enabled.sourceGrain.microstructureNM=30.0
        var stages:[String:[Double]]=[:]
        let actual=try OriginalSourcePhysicalImage.develop(
            source,parameters:enabled,
            stageDoubleObserver:{name,values in stages[name]=values}
        )
        let repeated=try OriginalSourcePhysicalImage.develop(
            source,parameters:enabled
        )
        let without=try OriginalSourcePhysicalImage.develop(
            source,parameters:baseline
        )
        let required:[(String,Int)]=[
            ("sourceGrainSublayers",w*h*9),
            ("sourceGrainDyeClouds",w*h*3),
            ("sourceGrainMicrostructure",w*h*3),
            ("sourceGrainFinalDensity",w*h*3),
            ("grainDensity",w*h*3),
            ("printed",w*h*3)
        ]
        guard actual.rgb.count==w*h*3,
              actual.rgb==repeated.rgb, actual.rgb != without.rgb,
              actual.rgb.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid(
                "原版 3×3 颗粒未在真实 iPhone 生产链中稳定改变扫描输出"
            )
        }
        for (name,count) in required {
            guard let values=stages[name],values.count==count,
                  values.allSatisfy({$0.isFinite}) else {
                throw Failure.invalid("原版生产颗粒阶段缺失/非有限：" + name)
            }
        }
        guard stages["sourceGrainFinalDensity"] == stages["grainDensity"],
              stages["printed"] == actual.rgb,
              stages["sourceGrainDyeClouds"] != stages["sourceGrainMicrostructure"] else {
            throw Failure.invalid("颗粒阶段顺序/Numba 微结构未执行")
        }
        let engine=try enabled.createEngine()
        let density=stages["grainDensity"]!
        var worst=0.0
        for p in 0..<(w*h) {
            let k=p*3
            let scan=try engine.sourceSpatialScan(
                filmDensity:[density[k],density[k+1],density[k+2]],
                paperEV:enabled.paperEV
            )
            for ch in 0..<3 {
                let delta=abs(scan[ch]-actual.rgb[k+ch])
                worst=max(worst,delta)
                guard delta <= 1e-11 else {
                    throw Failure.invalid(
                        "颗粒 CMY 未先进入原版放大机/相纸/扫描 p=\(p), ch=\(ch), Δ=\(delta)"
                    )
                }
            }
        }
        var missingSeed=enabled
        missingSeed.sourceGrain.numbaSeed=nil
        do {
            _=try OriginalSourcePhysicalImage.develop(
                source,parameters:missingSeed
            )
            throw Failure.invalid("生产链错误接受无固定种子的 Numba RNG")
        } catch OriginalSourcePhysicalGrain.Failure.invalid {}

        return "Build74 真机原版显影链 12×10 / 360 RGB 通道：" +
            "三亚层 1080 Double→九路 SciPy→染料云 FIR/YVV→受控 Numba 微结构→" +
            "末端 FIR/YVV→原版放大机/相纸/扫描；" +
            "源 CMY→最终 RGB 最大同链路误差=\(worst)；" +
            "seed=8888 重复输出一致、无 seed 拒绝、关闭颗粒改变输出均通过。" +
            "【未认证】独立 Python 端到端 RGB/RAW、多线程 RNG、整幅照片。"
    }
}
