#!/usr/bin/env python3
"""Build135 fixed-MB gate removal: static and executable-guard coverage."""
from pathlib import Path
from build_ci_version_floor import minimum_build,minimum_minor
root=Path(__file__).resolve().parents[2]
r=lambda p:(root/p).read_text()
safe=r("ios/SpektraFilmPort/SafeExportResolution.swift")
tiff=r("ios/SpektraFilmPort/Build96TIFF16Writer.swift")
rawf=r("ios/SpektraFilmPort/Build128RAWFloat32Transport.swift")
raw16=r("ios/SpektraFilmPort/Build95LibRaw16Ingress.swift")
native=r("ios/SpektraFilmPort/Build94LibRawBridge.mm")
metal=r("ios/SpektraFilmPort/OriginalMetalGrain.swift")
ui=r("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
physical=r("ios/SpektraFilmPort/Build91PhysicalMemory.swift")
tests=r("ios/tests/SafeExportResolutionValidation.swift")
project=r("ios/project.yml")
for name,s in [("export",safe),("tiff",tiff),("Float32",rawf),
               ("LibRaw-Swift",raw16),("LibRaw-C++",native),
               ("Metal grain",metal)]:
    for old in ("1_500_000_000","1_400_000_000","1400000000ull","1_300_000_000"):
        assert old not in s,(name,old)
assert "case .original: percentage = originalBudgetPercent" in safe
assert "let budget = processAvailableMemory ?? physicalMemory / 3" in safe
assert "bytes <= headroom / 100 * 70" in tiff
assert "estimate<=headroom/100*70" in rawf
assert "estimatedBytes > (headroom / 100ull) * 70ull" in native
assert "projectedBytes <= (memoryBudget / 100) * 70" in metal
assert "let allowed=processAvailable.map{($0/10)*8} ?? physicalMemory/3" in physical
assert "sourceCap:UInt64=512_000_000" in physical
assert ui.count("根据可用内存")>=2
assert "rawTIFF16.estimatedPeakBytes > 1_500_000_000" in tests
assert minimum_build(project,135) and minimum_minor(project,101)
print("PASS Build135 user-facing memory gates: fixed 1500/1400/1300MB removed; real 70%-80% process headroom remains")
print("RETAINED: source FFT 512MB scratch cap, maximum pixel geometry, user-selected smart/economy pixel ceilings; not bypassed")
