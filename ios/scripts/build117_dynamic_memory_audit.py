#!/usr/bin/env python3
"""Build117: dynamic 80% headroom, 3-layer grain scratch and original safety gates."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
read=lambda p:(root/p).read_text()
mem=read("ios/SpektraFilmPort/Build91PhysicalMemory.swift")
grain=read("ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift")
ledger=read("ios/SpektraFilmPort/Build106SourceMemoryLedger.swift")
project=read("ios/project.yml")
tests=read("ios/tests/Build91PhysicalMemoryMatrixValidation.swift")
assert "min(1_500_000_000" not in mem
assert "maximumSourceMemoryBudget" not in read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
assert "let allowed=processAvailable.map{($0/10)*8} ?? physicalMemory/3" in mem
assert "$0>0 && plan.estimatedPeakBytes<=($0/10)*8" in mem
assert "FFT.sourceCap" in mem
assert "retainAllSublayers=stageObserver != nil" in grain
assert "pixels*(retainAllSublayers ? 9 : 3)" in grain
assert "layerInputs[p*3+sl]=layerScratch[sl*3+ch]" in grain
assert "retainAllSublayers ? p*9+li : p*3+sl" in grain
assert "static let extraBytesPerPixel: UInt64 = 224" in grain
assert "static let unseededParallelExtraBytesPerPixel: UInt64 = 56" in grain
assert "static let grainBytesPerPixel: UInt64 = 224" in ledger
assert "let layers=pixels*3*8" in ledger
assert "let cloud=withDyeCloud ? pixels*8 : 0" in ledger
assert "complex.estimatedPeakBytes==4_665_600_000" in tests
assert 'MARKETING_VERSION: "1.8.83"' in project
assert 'CURRENT_PROJECT_VERSION: "117"' in project
print("PASS Build117 dynamic process 80% / fallback physical-third; 3-layer per-channel Float64; 13MP never auto-resized or bypassed")
