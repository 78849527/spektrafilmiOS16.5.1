import Foundation

/// Build115 CI: REAL production candidate, not an independent NumPy
/// bitstream. Compare distributions, RNG worker-state continuity and the
/// old controlled one-worker path. Python 4-thread source oracle is
/// executed separately in the same build.
@main
struct Build115ParallelNumbaValidation {
    struct Moment: Codable {
        let count:Int
        let mean:Double
        let variance:Double
    }
    struct Evidence: Codable {
        let schema:Int
        let workerCount:Int
        let originalLambda:Double
        let originalProbability:Double
        let particles:Moment
        let microstructure:Moment
        let bitReplayDiagnosticPassed:Bool
        let independentUnseededOutputsDiffer:Bool
        let exactPythonUnseededBitParityCertified:Bool
        let defaultSourceStatisticalRangePassed:Bool
    }
    static func moments<T:BinaryInteger>(_ source:[T])->Moment {
        calc(source.map(Double.init))
    }
    static func calc(_ source:[Double])->Moment {
        let mean=source.reduce(0,+)/Double(source.count)
        let variance=source.reduce(0) { partial,x in
            partial+(x-mean)*(x-mean)
        }/Double(source.count)
        return Moment(count:source.count,mean:mean,variance:variance)
    }
    static func check(_ name:String,_ data:Moment,
                      mean:Double,variance:Double,
                      meanTolerance:Double,varTolerance:Double) {
        guard data.count>0 && data.mean.isFinite &&
              data.variance.isFinite &&
              abs(data.mean-mean)<meanTolerance &&
              abs(data.variance-variance)<varTolerance else {
            fatalError("Build115 source statistical FAIL \(name): \(data)")
        }
    }
    static func main() throws {
        let count=65_536
        let rates=[Double](repeating:8.0,count:count)
        let ps=[Double](repeating:0.4,count:count)
        let seeds:[UInt32]=[1009,2003,3001,4001]
        let replayA=try OriginalSourceNumbaParallelWorkers(
            workerCount:4,diagnosticSeeds:seeds
        )
        let replayB=try OriginalSourceNumbaParallelWorkers(
            workerCount:4,diagnosticSeeds:seeds
        )
        // One continuous state: twice draw particles from each worker,
        // then draw lognormal microstructure. Identical test seeds replay;
        // unseeded production mode intentionally will not.
        let pA=try replayA.particleLayer(rates:rates,probabilities:ps)
        let pB=try replayB.particleLayer(rates:rates,probabilities:ps)
        guard pA==pB else {fatalError("Build115 worker replay changed")}
        let laterA=try replayA.particleLayer(rates:rates,probabilities:ps)
        let laterB=try replayB.particleLayer(rates:rates,probabilities:ps)
        guard laterA==laterB, pA != laterA else {
            fatalError("Build115 source worker RNG did not advance")
        }
        let mA=try replayA.microstructure(count:count*3,microStd:0.3)
        let mB=try replayB.microstructure(count:count*3,microStd:0.3)
        guard mA==mB else {fatalError("Build115 persistent worker normals changed")}
        let particleMoment=moments(pA)
        let microMoment=calc(mA)
        // Poisson(8) thinning by Binomial(p=.4) has mean and variance 3.2.
        check("Poisson + Binomial compound",particleMoment,
              mean:3.2,variance:3.2,
              meanTolerance:0.10,varTolerance:0.24)
        // Exact source fast_lognormal_from_mean_std parameters:
        // linear mean=1, std=.3 -> variance=.09.
        check("Numba lognormal mean/std",microMoment,
              mean:1.0,variance:0.09,
              meanTolerance:0.013,varTolerance:0.012)
        let entropyA=try OriginalSourceNumbaParallelWorkers(workerCount:4)
        let entropyB=try OriginalSourceNumbaParallelWorkers(workerCount:4)
        let independentA=try entropyA.particleLayer(
            rates:rates,probabilities:ps
        )
        let independentB=try entropyB.particleLayer(
            rates:rates,probabilities:ps
        )
        guard independentA != independentB else {
            fatalError("Build115 OS entropy streams unexpectedly frozen")
        }
        let report=Evidence(
            schema:1,workerCount:4,originalLambda:8,
            originalProbability:0.4,
            particles:particleMoment,microstructure:microMoment,
            bitReplayDiagnosticPassed:true,
            independentUnseededOutputsDiffer:true,
            exactPythonUnseededBitParityCertified:false,
            defaultSourceStatisticalRangePassed:true
        )
        let json=JSONEncoder()
        json.outputFormatting=[.prettyPrinted,.sortedKeys]
        let bytes=try json.encode(report)
        if let path=ProcessInfo.processInfo.environment[
            "BUILD115_PARALLEL_STATS_OUTPUT"
        ], !path.isEmpty {
            try bytes.write(to:URL(fileURLWithPath:path),options:.atomic)
        }
        print("PASS Build115 Swift 4 workers, seeded replay, continuous state, independent OS entropy; Poisson->Binomial mean=\(particleMoment.mean), var=\(particleMoment.variance), micro mean=\(microMoment.mean), var=\(microMoment.variance)")
        print("NOT CERTIFIED: arbitrary unseeded Numba worker scheduling / exact per-pixel Python bitstream")
    }
}
