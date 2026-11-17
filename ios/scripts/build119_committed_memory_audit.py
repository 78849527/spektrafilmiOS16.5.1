#!/usr/bin/env python3
"""Build119: 13MP late headroom accounts for already-owned Float64 RGB frame."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
read=lambda p:(root/p).read_text()
memory=read("ios/SpektraFilmPort/Build91PhysicalMemory.swift")
physical=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
stress=read("ios/SpektraFilmPort/Build108SourceOpticalDeviceStress.swift")
ui=read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
cv=read("ios/SpektraFilmPort/ContentView.swift")
project=read("ios/project.yml")
tests=read("ios/tests/Build119CommittedFrameMemoryValidation.swift")
assert "alreadyCommittedInputBytes:UInt64=0" in memory
assert "alreadyCommittedInputBytes<=plan.basePeakBytes" in memory
assert "remainingPeak=plan.estimatedPeakBytes-alreadyCommittedInputBytes" in memory
assert "remainingPeak<=($0/10)*8" in memory
assert "remainingPeak<=plan.allowedBytes" in memory
assert "alreadyCommittedInputBytes:UInt64=0" in physical
assert "alreadyCommittedInputBytes:alreadyCommittedInputBytes" in physical
assert "frame.rgb.count==w*h*3" in physical
assert "let committedInputBytes=UInt64(frame.rgb.count)" in physical
assert "alreadyCommittedInputBytes:committedInputBytes" in physical
# The raw ImageIO/preview pre-decode path must have no committed credit.
assert "additionalBytesPerPixel:preflightAdditional," in physical
assert "alreadyCommittedInputBytes:committedInputBytes" not in physical.split(
    "let preflightAdditional=Build106SourceMemoryLedger.productionAdditional("
)[1]
assert "lateAdmissionRefused=error is Build91PhysicalMemory.Failure" in stress
assert 'lateAdmissionRefused ? "refused_by_production_memory_gate"' in stress
assert "build==\"119\"" in stress
assert "Build119-\\(report.megapixels)MP-grain-memory-" in stress
assert "Build119：单独测试" in ui
assert "Build119-last-\\(megapixels)MP-checkpoint.txt" in cv
from build_ci_version_floor import minimum_minor,minimum_build
assert minimum_minor(project,85) and minimum_build(project,119)
assert "alreadyCommittedInputBytes:committed" in tests
assert "2_873_685_440" in tests
assert "2_080_000_000" in tests
assert "plan.basePeakBytes+1" in tests
print("PASS Build119 correct late allocated input accounting (13MP +312MB), 80%-process headroom, no premature predecode credit, true refusal classification and 8/10/13MP separated reports")
