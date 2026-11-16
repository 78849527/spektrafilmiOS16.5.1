import Foundation

/// Opt-in physical iPhone diagnostic of the SAME unseeded multiworker
/// sampler used by OriginalSourcePhysicalGrain.apply. Statistics are not
/// bitstream equivalence to an arbitrary Python prange scheduling trace.
enum Build115ParallelNumbaEvidence {
    struct Moments:Codable {
        let count:Int
        let mean:Double
        let variance:Double
    }
    struct Report:Codable {
        let schema:Int
        let version:String
        let build:String
        let sourceCommit:String
        let osVersion:String
        let physicalDevice:Bool
        let sourceGrainEnabled:Bool
        let sourceParallelSelected:Bool
        let sourceFastStatsSelected:Bool
        let workerCount:Int
        let particle:Moments?
        let microstructure:Moments?
        let originalSublayersWithSciPyPass:Bool
        let originalSublayersWithFastStatsPass:Bool
        let unseededIndependentDrawsDiffer:Bool
        let sourceStatisticalChecksPassedOnTarget:Bool
        let originalPythonBitIdenticalParallelCertified:Bool
        let firstFailure:String?
        let limitations:[String]
    }
    private static func moments(_ values:[Double])->Moments {
        let n=Double(values.count)
        let mu=values.reduce(0.0,+)/n
        let variance=values.reduce(0.0) {
            $0+($1-mu)*($1-mu)
        }/n
        return Moments(count:values.count,mean:mu,variance:variance)
    }
    private static func close(_ got:Moments,mean:Double,variance expectedVariance:Double,
                              muTol:Double,varTol:Double)->Bool {
        got.mean.isFinite && got.variance.isFinite &&
        abs(got.mean-mean)<muTol &&
        abs(got.variance-expectedVariance)<varTol
    }
    private static func fullGrainIntegration(fast:Bool) throws->Bool {
        let w=18,h=13,pixels=w*h
        let density=[Double](repeating:0.23,count:pixels*3)
        let layers=OriginalSourcePhysicalGrain.MeasuredLayers(
            maxima:[Double](repeating:0.5,count:9),
            sublayers:{ value in
                var result=[Double](repeating:0,count:9)
                for sl in 0..<3 {
                    for ch in 0..<3 {
                        result[sl*3+ch]=value[ch]/3.0
                    }
                }
                return result
            }
        )
        var options=OriginalSourcePhysicalGrain.Settings()
        options.active=true
        options.sublayersActive=true
        options.useUnseededParallel=true
        options.useFastStats=fast
        // Production unseeded: never supply 8888 to these workers.
        options.numbaSeed=nil
        options.fastStatsSeed=nil
        let actual=try OriginalSourcePhysicalGrain.apply(
            density,width:w,height:h,pixelUM:0.35,
            measured:layers,settings:options
        )
        return actual.count==density.count &&
            actual.allSatisfy({$0.isFinite})
    }

    static func capture(
        version:String,build:String,commit:String,osVersion:String,
        physical:Bool,grain:Bool,parallel:Bool,fast:Bool
    )->Report {
        let count=65_536
        var particles:Moments?
        var micro:Moments?
        var sourceSciPy=false,sourceFast=false,different=false
        var failure:String?
        do {
            let rates=[Double](repeating:8,count:count)
            let ps=[Double](repeating:0.4,count:count)
            let pool=try OriginalSourceNumbaParallelWorkers(workerCount:4)
            let counts=try pool.particleLayer(rates:rates,probabilities:ps)
            let microSamples=try pool.microstructure(
                count:count*3,microStd:0.3
            )
            particles=moments(counts.map(Double.init))
            micro=moments(microSamples)
            // Two independently OS-entropy-seeded production instances
            // MUST not produce identical entire random fields.
            let second=try OriginalSourceNumbaParallelWorkers(workerCount:4)
            different=counts != (try second.particleLayer(
                rates:rates,probabilities:ps
            ))
            sourceSciPy=try fullGrainIntegration(fast:false)
            sourceFast=try fullGrainIntegration(fast:true)
            if !different || !sourceSciPy || !sourceFast ||
                !close(particles!,mean:3.2,variance:3.2,muTol:0.10,varTol:0.24) ||
                !close(micro!,mean:1,variance:0.09,muTol:0.013,varTol:0.012) {
                failure="原版 Numba 多线程统计矩或真实三亚层生产整合未通过"
            }
        } catch {
            failure=error.localizedDescription
        }
        let target=physical && osVersion=="16.5.1" &&
            commit.count==40 &&
            commit.allSatisfy({"0123456789abcdef".contains($0)})
        if !target && failure==nil {
            failure="当前运行非绑定 SHA 的 iOS 16.5.1 真机"
        }
        return Report(
            schema:1,version:version,build:build,sourceCommit:commit,
            osVersion:osVersion,physicalDevice:physical,
            sourceGrainEnabled:grain,sourceParallelSelected:parallel,
            sourceFastStatsSelected:fast,workerCount:4,
            particle:particles,microstructure:micro,
            originalSublayersWithSciPyPass:sourceSciPy,
            originalSublayersWithFastStatsPass:sourceFast,
            unseededIndependentDrawsDiffer:different,
            sourceStatisticalChecksPassedOnTarget:target && failure==nil,
            originalPythonBitIdenticalParallelCertified:false,
            firstFailure:failure,
            limitations:[
                "真实 iPhone 本次执行 Numba parallel 分布统计及两组实际三亚层 source grain 流程；固定单线程原版对照仍单独有效",
                "Numba Python 未固定 worker 初态与 prange 任务调度，不能要求两次渲染得到逐像素相同随机数",
                "源算法、Poisson/Binomial 分支、MT19937/Box-Muller 内核相同；iOS GCD 分区及系统随机种子不是 Numba prange 内部调度",
                "本次没有认证默认 Numba prange 每线程 bitstream、真实 13MP 含颗粒、RAW 和 Python 整图"
            ]
        )
    }
    static func write(_ report:Report,documents:URL)throws->(log:URL,json:URL) {
        let folder=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true
        )
        let prefix="Build115-numba-parallel-"+UUID().uuidString
        let json=folder.appendingPathComponent(prefix+".json")
        let log=folder.appendingPathComponent(prefix+".log")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        try encoder.encode(report).write(to:json,options:.atomic)
        let t="""
        Build115 unseeded Numba 4-worker physical iPhone statistics
        SHA: \(report.sourceCommit), version \(report.version) Build\(report.build), iOS \(report.osVersion)
        iPhone: \(report.physicalDevice)
        Statistics PASS: \(report.sourceStatisticalChecksPassedOnTarget)
        Poisson+Binomial mean/variance: \(report.particle.map{String($0.mean)+"/"+String($0.variance)} ?? "not_run")
        Microstructure mean/variance: \(report.microstructure.map{String($0.mean)+"/"+String($0.variance)} ?? "not_run")
        SciPy/fast_stats production 3x3 integration: \(report.originalSublayersWithSciPyPass)/\(report.originalSublayersWithFastStatsPass)
        Independent OS entropy draws differ: \(report.unseededIndependentDrawsDiffer)
        Exact unseeded Python prange bit parity: \(report.originalPythonBitIdenticalParallelCertified)
        First failure: \(report.firstFailure ?? "none")
        \(report.limitations.joined(separator:"\n"))
        """
        try t.write(to:log,atomically:true,encoding:.utf8)
        return (log,json)
    }
}
