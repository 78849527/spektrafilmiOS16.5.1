#!/usr/bin/env python3
"""Build118 isolated large-frame buttons, stage RSS and shared production gate."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
read=lambda p:(root/p).read_text()
ui=read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
cv=read("ios/SpektraFilmPort/ContentView.swift")
stress=read("ios/SpektraFilmPort/Build108SourceOpticalDeviceStress.swift")
physical=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
grain=read("ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift")
ledger=read("ios/SpektraFilmPort/Build106SourceMemoryLedger.swift")
mem=read("ios/SpektraFilmPort/Build91PhysicalMemory.swift")
project=read("ios/project.yml")
for term in [
    "ForEach([8,10,13],id:\\.self)",
    "onRunBuild118LargeMemory(mp)",
    "let onRunBuild118LargeMemory: (Int) -> Void",
    "Build119：单独测试",
]:
    assert term in ui,term
for term in [
    "private func runBuild118LargeMemory(_ megapixels:Int)",
    "runBuild118LargeMemory(mp)",
    "Build119-last-\\(megapixels)MP-checkpoint.txt",
    "captureBuild118Large(",
    "writeBuild118Large(",
    "diagnosticPendingFeedback=pair"
]:
    assert term in cv,term
for term in [
    "case 8: shape=(4000,2000)",
    "case 10: shape=(4000,2500)",
    "case 13: shape=(5000,2600)",
    "for parallel in [false,true]",
    "let target=physicalDevice && osVersion==\"16.5.1\"",
    "build==\"119\"",
    "phaseSink:((StageRSS)->Void)?=nil",
    "phaseMemoryObserver:phaseObserver",
    "checkpoint(\"BEFORE_\\(route)\")",
    "checkpoint(\"IN_\\(route)_\\(sample.stage)\")",
    "checkpoint(\"AFTER_\\(route)\")",
    "let prefix=\"Build119-\\(report.megapixels)MP-grain-memory-\"",
    "real_source_float64_render_pass",
    "refused_by_production_memory_gate",
    "real_source_render_failed_or_unmeasured",
]:
    assert term in stress,term
# Build140: renderer, RAW ingress and ordinary-photo predecode share one
# conservative exact source-option ledger. No independent magic coefficients.
assert physical.count("Build106SourceMemoryLedger.productionAdditional(")==1
assert "static func memoryEnvelope(" in physical
assert "stageObserver:stageDoubleObserver != nil" in physical
assert physical.count("parameters:parameters")>=2
for term in [
    "phaseMemoryObserver: ((String) -> Void)? = nil",
    "grainSublayers:parameters.sourceGrain.sublayersActive",
    "phaseMemoryObserver?(\"spatial_DIR_ready\")",
    "phaseMemoryObserver?(\"scanner_output_ready\")",
]:
    assert term in physical,term
assert "phaseMemoryObserver: ((String)->Void)? = nil" in grain
assert "phaseMemoryObserver?(\"grain_particle_scratch_released\")" in grain
assert "return parallelGrain ? 72 : 64" in ledger
assert "return conservative" in ledger
assert "let allowed=processAvailable.map{($0/10)*8} ?? physicalMemory/3" in mem
from build_ci_version_floor import minimum_minor,minimum_build
assert minimum_minor(project,85) and minimum_build(project,119)
print("PASS Build118 3 separate 8/10/13MP buttons, 2 independent source-grain paths, phase RSS, per-size checkpoints and conservative legacy feature memory accounting")
