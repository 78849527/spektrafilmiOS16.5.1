import Foundation

/// Build86: tests the REAL in-production film→paper→scanner path, not an
/// isolated mathematical copy. Strictly an on-device self-check; does not
/// stand in for independent Python whole-RGB parity or unseeded prange.
enum Build86BulkProductionPathDiagnostic {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(message)=self {return message}
            return nil
        }
    }

    private static func require(
        _ stage:[String:[Double]],_ name:String,count:Int
    ) throws -> [Double] {
        guard let values=stage[name],values.count==count,
              values.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Build86 缺少生产链阶段 "+name)
        }
        return values
    }

    static func evaluate() throws -> String {
        let w=12,h=10,pixels=w*h
        let frame=OriginalSourcePixelIO.Frame(
            width:w,height:h,rgb:(0..<pixels).flatMap { p in
                (0..<3).map { ch in
                    Double((13 + p*17 + ch*41 + (p/w)*19)%256)/255.0
                }
            }
        )
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        dir.referencePixelSizeUM=0.35
        let base=OriginalSourcePhysicalImage.Parameters(
            filmID:"kodak_portra_400",paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,dir:dir,
            print:OriginalPrintOptics.Settings(enabled:true),
            morph:OriginalPrintMorph.Settings()
        )
        var traces=[String:[Double]]()
        func run(_ parameter:OriginalSourcePhysicalImage.Parameters) throws
          -> OriginalSourcePixelIO.Frame {
            try OriginalSourcePhysicalImage.develop(
                frame,parameters:parameter,
                stageDoubleObserver:{name,values in
                    traces[name]=values
                }
            )
        }
        let baseline=try run(base)
        let baseDensity=try require(traces,"density",count:pixels*3)
        let outputBase=try require(traces,"printed",count:pixels*3)
        guard baseline.rgb==outputBase else {
            throw Failure.invalid("Build86 生产扫描输出和观察值不一致")
        }

        var custom=base
        var settings=Build84OriginalFilmDIR.RuntimeSettings()
        settings.amount=0.76
        settings.inhibitionSameLayer=1.16
        settings.inhibitionInterlayer=0.81
        settings.gammaRGB=[0.88,1.08,1.15]
        settings.diffusionSizeUM=8
        settings.diffusionTailUM=92
        settings.diffusionTailWeight=0.12
        custom.sourceDIR=settings
        traces.removeAll()
        let dynamic=try run(custom)
        _=try require(traces,"initial",count:pixels*3)
        let dynamicDensity=try require(traces,"density",count:pixels*3)
        guard dynamic.rgb != baseline.rgb,
              dynamicDensity != baseDensity else {
            throw Failure.invalid("Build86 动态 256 节点 DIR 没有改变正式显影")
        }

        var bypass=custom
        settings.active=false
        bypass.sourceDIR=settings
        traces.removeAll()
        _=try run(bypass)
        let inactiveInhibitors=try require(
            traces,"inhibitors",count:pixels*3
        )
        let inactiveDiffuse=try require(
            traces,"diffused",count:pixels*3
        )
        guard inactiveInhibitors.allSatisfy({$0==0}),
              inactiveDiffuse.allSatisfy({$0==0}) else {
            throw Failure.invalid("Build86 关闭 DIR 后仍执行化学抑制")
        }

        var noSpatial=custom
        settings.active=true
        settings.diffusionSizeUM=0
        noSpatial.sourceDIR=settings
        traces.removeAll()
        _=try run(noSpatial)
        let chemical=try require(
            traces,"inhibitors",count:pixels*3
        )
        let spatialOff=try require(
            traces,"diffused",count:pixels*3
        )
        guard chemical==spatialOff else {
            throw Failure.invalid("Build86 空间关闭时未保留完整 DIR 化学量")
        }

        var single=base
        single.sourceGrain.active=true
        single.sourceGrain.sublayersActive=false
        single.sourceGrain.nSubLayers=3
        single.sourceGrain.numbaSeed=nil
        traces.removeAll()
        let singleImage=try run(single)
        let singleGrain=try require(
            traces,"sourceGrainSingleLayer",count:pixels*3
        )
        let singleDensity=try require(
            traces,"grainDensity",count:pixels*3
        )
        guard singleDensity != baseDensity,
              singleImage.rgb != baseline.rgb,
              singleGrain.allSatisfy({$0.isFinite}),
              try run(single).rgb == singleImage.rgb else {
            throw Failure.invalid("Build86 单层 SciPy 颗粒未进入原版印相或不可重复")
        }

        var fast=base
        fast.sourceGrain.active=true
        fast.sourceGrain.sublayersActive=true
        fast.sourceGrain.useFastStats=true
        fast.sourceGrain.fastStatsSeed=8888
        fast.sourceGrain.numbaSeed=8888
        traces.removeAll()
        let fastImage=try run(fast)
        let cloud=try require(traces,"sourceGrainDyeClouds",count:pixels*3)
        let micro=try require(traces,"sourceGrainMicrostructure",count:pixels*3)
        let final=try require(traces,"sourceGrainFinalDensity",count:pixels*3)
        let printed=try require(traces,"printed",count:pixels*3)
        guard micro != cloud,final != baseDensity,
              printed==fastImage.rgb,
              try run(fast).rgb==fastImage.rgb else {
            throw Failure.invalid("Build86 Numba 连续随机颗粒没有正确显影和印相")
        }
        var conflict=fast
        conflict.sourceGrain.numbaSeed=9999
        do {
            _=try run(conflict)
            throw Failure.invalid("Build86 接受两个不同的 Numba 线程状态")
        } catch OriginalSourcePhysicalGrain.Failure.invalid {
            // Source single-worker requires the same evolving worker state.
        }
        return "Build86 生产链 12×10：动态 256 H-D/DIR、自定义 Gamma/半径、" +
               "关闭化学、关闭空间、SciPy 3 子层、Numba fast_stats 九亚层" +
               "→连续 lognormal→染料云→相纸→扫描，生产分段/重复回放/错误分支通过。" +
               "【非认证】尚未在本次会话实机执行，亦不代表原版默认 prange、多线程、RAW 或全尺寸 RGB 精确一致。"
    }
}
