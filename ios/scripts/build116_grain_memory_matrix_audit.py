#!/usr/bin/env python3
"""Build116: fail-closed one-tap 8-size x 2-grain-route iOS stress matrix."""
from pathlib import Path

root=Path(__file__).resolve().parents[2]
device=(root/"ios/SpektraFilmPort/Build108SourceOpticalDeviceStress.swift").read_text()
content=(root/"ios/SpektraFilmPort/ContentView.swift").read_text()
ui=(root/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
grain=(root/"ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift").read_text()
mem=(root/"ios/SpektraFilmPort/Build91PhysicalMemory.swift").read_text()
doc=(root/"docs/BUILD116-GRAIN-MEMORY-STAGED-ACCEPTANCE.md").read_text()

# The exact whole-frame dimensions, not just approximate display labels.
expected={
    "1MP":(1000,1000), "2MP":(1600,1250),
    "3MP":(2000,1500), "4MP":(2000,2000),
    "6MP":(3000,2000), "8MP":(4000,2000),
    "10MP":(4000,2500), "13MP":(5000,2600),
}
import re
actual={
    name:(int(width),int(height))
    for name,width,height in re.findall(
        r'\("(\d+MP)",(\d+),(\d+)\)',device
    )
}
assert actual==expected,(actual,expected)
assert 'for parallel in [false,true]' in device
assert 'parallel ? "Numba4WorkerFastStats" : "SciPySeeded"' in device
assert "matrixCases:results,plannedCaseCount:cases.count" in device
for tag in ["measuredCaseCount","refusedCaseCount","failedCaseCount",
            "notRunCaseCount","allAdmittedCasesPassed"]:
    assert tag in device,tag
for code in [
    'status=="refused_by_production_memory_gate"',
    'status=="real_source_float64_render_pass"',
    'status=="real_source_render_failed_or_unmeasured"',
    'status=="not_run"',
    "Build91PhysicalMemory.plan(", "Build91PhysicalMemory.validate(p)",
    "parallelFastStats:parallel", "checkpointURL:URL?=nil",
    "saveCheckpoint(\"BEFORE_", "saveCheckpoint(\"AFTER_",
]:
    assert code in device,code
assert 'useFastStats=true' in device
assert 'useUnseededParallel=true' in device
assert 'numbaSeed=8888' in device
assert 'static let extraBytesPerPixel: UInt64 = 272' in grain
assert 'static let unseededParallelExtraBytesPerPixel: UInt64 = 56' in grain
assert 'let allowed=min(1_500_000_000,physicalMemory/3)' in mem
assert "onRunBuild116GrainMemory()" in ui
assert "checkpointURL:checkpoint" in content
assert "proof.allAdmittedCasesPassed" in content
assert '8 尺寸 × 双颗粒路线' in doc
# Explicitly refuse to call "memory-gate refused" a physical test PASS.
assert "Admission-refused:" in device and "measuredCaseCount" in device
print("PASS Build116: 8 exact geometries x 2 source routes = 16 one-tap cases; full RSS, refusal, checkpoint and source safety gates")
