import Foundation

/// Build115: opt-in multi-worker stochastic branch for the *unseeded*
/// original fast_stats.py prange path. Every worker holds its own MT19937,
/// Numba fast_poisson/fast_binomial/fast_lognormal normal cache. The seed
/// material comes from OS entropy once at job creation, not a fixed 8888.
///
/// Semantics: one worker owns a disjoint contiguous flat pixel interval,
/// retains its stream from one sublayer to the next, and consumes Poisson
/// then Binomial then microstructure in original source function order.
/// Python's prange scheduling / initial worker RNG states are not specified:
/// this is a distribution-level candidate, NOT a bit-identical replica of
/// arbitrary Python unseeded multiworker outputs.
///
/// Kept distinct from the certified one-worker seeded source replay.
final class OriginalSourceNumbaParallelWorkers {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason)=self { return reason }
            return nil
        }
    }

    private final class Worker {
        var source:OriginalSourceNumbaFastCounts
        var counts=[Int64]()
        var micro=[Double]()
        var failure:String?
        init(seed:UInt32) {
            source=OriginalSourceNumbaFastCounts(seed:seed)
        }
    }
    let workerCount:Int
    private let workers:[Worker]

    /// Only the optional deterministic test vector supplies seeds.
    /// Production MUST omit it; users cannot set it through the UI.
    init(workerCount:Int, diagnosticSeeds:[UInt32]?=nil) throws {
        guard (2...8).contains(workerCount) else {
            throw Failure.invalid(
                "Numba 多线程颗粒必须使用 2–8 个独立工作线程"
            )
        }
        let seeds:[UInt32]
        if let diagnosticSeeds {
            guard diagnosticSeeds.count==workerCount,
                  Set(diagnosticSeeds).count==workerCount else {
                throw Failure.invalid("Numba 多线程诊断种子长度或唯一性错误")
            }
            seeds=diagnosticSeeds
        } else {
            var system=SystemRandomNumberGenerator()
            var unique=Set<UInt32>()
            var entropy=[UInt32]()
            while entropy.count<workerCount {
                let next=UInt32.random(in:UInt32.min...UInt32.max,using:&system)
                if unique.insert(next).inserted {entropy.append(next)}
            }
            seeds=entropy
        }
        self.workerCount=workerCount
        workers=seeds.map {Worker(seed:$0)}
    }

    static var defaultWorkers:Int {
        max(2,min(8,ProcessInfo.processInfo.activeProcessorCount))
    }

    private func interval(_ worker:Int,count:Int)->Range<Int> {
        let start=(count/workerCount)*worker+
            min(worker,count%workerCount)
        let size=count/workerCount+(worker<count%workerCount ? 1 : 0)
        return start..<(start+size)
    }

    /// One whole layer: actual original fast_stats source branches and
    /// continuous worker-specific state across the complete nine layers.
    /// Each worker's temporary Poisson / Binomial fields are private; no
    /// worker may touch another worker's Array buffer.
    func particleLayer(rates:[Double],probabilities:[Double]) throws ->[Int64] {
        let count=rates.count
        guard count>0,count==probabilities.count,
              count<=16_000_000,
              rates.allSatisfy({$0.isFinite && $0>=0}),
              probabilities.allSatisfy({$0.isFinite && (0...1).contains($0)}) else {
            throw Failure.invalid("多线程 Poisson→Binomial 输入形状/概率不合法")
        }
        DispatchQueue.concurrentPerform(iterations:workerCount) { index in
            let worker=workers[index]
            worker.failure=nil
            worker.counts.removeAll(keepingCapacity:false)
            let range=interval(index,count:count)
            if range.isEmpty {return}
            do {
                let value=try worker.source.runOriginalTwoPhase(
                    rates:Array(rates[range]),
                    probabilities:Array(probabilities[range])
                )
                worker.counts=value.binomial
            } catch {
                worker.failure=error.localizedDescription
            }
        }
        for index in workers.indices {
            if let failure=workers[index].failure {
                throw Failure.invalid("Numba worker \(index) 粒子计算失败："+failure)
            }
        }
        var combined=[Int64]()
        combined.reserveCapacity(count)
        for worker in workers {
            combined.append(contentsOf:worker.counts)
            worker.counts.removeAll(keepingCapacity:false)
        }
        guard combined.count==count else {
            throw Failure.invalid("Numba 多线程粒子输出不足，禁止替代原版")
        }
        return combined
    }

    /// Upstream fast_lognormal_from_mean_std(mean=1, std=microStd).
    /// The same workers continue drawing after all nine particle layers,
    /// and sample a separate unseeded normal per pixel/channel.
    func microstructure(count:Int,microStd:Double) throws ->[Double] {
        guard count>0,count<=48_000_000,
              microStd.isFinite,microStd>0.05 else {
            throw Failure.invalid("Numba 多线程微结构输入或生效阈值不合法")
        }
        let sigma2=log(1.0+microStd*microStd)
        let sigma=sqrt(sigma2)
        let mu = -sigma2/2.0
        guard sigma.isFinite,mu.isFinite else {
            throw Failure.invalid("Numba 微结构对数正态参数无效")
        }
        DispatchQueue.concurrentPerform(iterations:workerCount) { index in
            let worker=workers[index]
            worker.failure=nil
            worker.micro.removeAll(keepingCapacity:false)
            let range=interval(index,count:count)
            if range.isEmpty {return}
            var samples=[Double]()
            samples.reserveCapacity(range.count)
            do {
                for _ in range {
                    let normal=try worker.source.nextMicrostructureNormal()
                    let sample=exp(mu+sigma*normal)
                    guard sample.isFinite && sample>0 else {
                        throw Failure.invalid("Numba 多线程微结构产生无效结果")
                    }
                    samples.append(sample)
                }
                worker.micro=samples
            } catch {
                worker.failure=error.localizedDescription
            }
        }
        for index in workers.indices {
            if let failure=workers[index].failure {
                throw Failure.invalid("Numba worker \(index) 微结构失败："+failure)
            }
        }
        var combined=[Double]()
        combined.reserveCapacity(count)
        for worker in workers {
            combined.append(contentsOf:worker.micro)
            worker.micro.removeAll(keepingCapacity:false)
        }
        guard combined.count==count else {
            throw Failure.invalid("Numba 多线程微结构输出不足")
        }
        return combined
    }
}
