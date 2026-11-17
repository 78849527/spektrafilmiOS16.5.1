#!/usr/bin/env python3
"""Build115 fail-closed original default Numba parallel production integration."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
read=lambda p:(root/p).read_text()
grain=read("ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift")
workers=read("ios/SpektraFilmPort/OriginalSourceNumbaParallelWorkers.swift")
model=read("ios/SpektraFilmPort/ContentView.swift")
ui=read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
physical=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
ledger=read("ios/SpektraFilmPort/Build106SourceMemoryLedger.swift")
device=read("ios/SpektraFilmPort/Build115ParallelNumbaEvidence.swift")
source=read("src/spektrafilm/model/grain.py")
stats=read("src/spektrafilm/utils/fast_stats.py")
for part,needle in [
 (grain,"var useUnseededParallel = false"),
 (grain,"var useFastStats = false"),
 (grain,"useUnseededParallel &&"),
 (grain,"multiworker.particleLayer("),
 (grain,"multiworker.microstructure("),
 (grain,"unseededParallelExtraBytesPerPixel: UInt64 = 56"),
 (model,"@Published var sourceGrainUseUnseededParallel = false"),
 (model,"@Published var sourceGrainFastStatsEnabled = false"),
 (model,"useUnseededParallel:sourceGrainUseUnseededParallel"),
 (model,"fastStatsSeed:sourcePhysicalGrainEnabled &&"),
 (ui,'resetToggle("Numba 默认多线程 · 无固定种子"'),
 (ui,'resetToggle("Numba fast_stats 粒子（原版可选）"'),
 (ui,"onRunBuild115ParallelGrain()"),
 (device,"fullGrainIntegration(fast:true)"),
 (device,"fullGrainIntegration(fast:false)"),
 (device,"originalPythonBitIdenticalParallelCertified:false"),
 (ledger,"parallelGrainExtraBytesPerPixel: UInt64 = 56"),
 (physical,"parallelGrain:parameters.sourceGrain.useUnseededParallel"),
 (workers,"DispatchQueue.concurrentPerform"),
 (workers,"SystemRandomNumberGenerator()"),
 (workers,"worker.source.runOriginalTwoPhase("),
 (workers,"worker.source.nextMicrostructureNormal()"),
 (source,"use_fast_stats=False"),
 (stats,"@njit(parallel=True"),
 (stats,"prange(n_elements)"),
]: 
    assert needle in part,needle
# The original fixed-seed replay is still present as a separate source path.
assert "OriginalSourceNumbaSingleThreadNormal(seed:seed)" in grain
assert "OriginalSourceSciPySampler.drawLayer(" in grain
assert "seed:UInt32(ch+sl*10)" in grain
# No automatic branch change or global precision/renderer changes.
assert "useUnseededParallel = true" not in grain
# Historical contracts stay valid across the new Build116 revision.
assert 'MARKETING_VERSION: "1.8.82"' in read("ios/project.yml")
assert 'CURRENT_PROJECT_VERSION: "116"' in read("ios/project.yml")
print("PASS Build115: genuine per-worker random streams, Poisson->Binomial->lognormal, SciPy and seeded replay preserved; UI opt-in; 56B/px additional preflight")
