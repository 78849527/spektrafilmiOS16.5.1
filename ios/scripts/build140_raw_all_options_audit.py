#!/usr/bin/env python3
"""Build140: exact-option/FFT RAW admission audit, no unsafe Jetsam bypass."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
read=lambda name:(root/name).read_text()
physical=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
app=read("ios/SpektraFilmPort/ContentView.swift")
raw=read("ios/SpektraFilmPort/P1OriginalRawACESIngress.swift")
safe=read("ios/SpektraFilmPort/SafeExportResolution.swift")
ledger=read("ios/SpektraFilmPort/Build106SourceMemoryLedger.swift")
memory=read("ios/SpektraFilmPort/Build91PhysicalMemory.swift")
test=read("ios/tests/Build140RAWMemoryAdmissionValidation.swift")

assert physical.count("Build106SourceMemoryLedger.productionAdditional(")==1
assert "static func memoryEnvelope(" in physical
assert "parameters:Parameters" in physical
assert "stageObserver:stageDoubleObserver != nil" in physical
assert "paperStageObserver:stageObserver &&" in physical
assert "alreadyCommittedInputBytes:committedInputBytes" in physical
assert "cameraDiffusion:envelope.cameraDiffusion" in physical
assert "paperDiffusion:envelope.paperDiffusion" in physical
assert "cameraOptics.diffusion.strength>0" in physical
assert "printDiffusion.spatialScale>0" in physical

assert "let rawPhysicalSettings:OriginalSourcePhysicalImage.Parameters?" in app
assert "rawOpticalPeakBPP:UInt64?" in app
assert "OriginalSourcePhysicalImage.memoryEnvelope(" in app
assert "rawOpticalPeakBPP ??" in app
assert "parameters:rawPhysicalSettings" in app
assert "parameters:settings" in app
assert "sourceScannerGlareEnabled && sourceScannerGlarePercent>0" in app

source=raw.split("static func developSourceCandidate(",1)[1].split(
    "/// Build139:",1
)[0]
assert "width:working.width,height:working.height,parameters:selected" in source
assert "try OriginalSourcePhysicalImage.developInPlace(" in source
assert "Build139RAWPreviewDownsample" not in source
assert "width:reduced.width,height:reduced.height,parameters:selected" in raw

assert "let extra=Build106SourceMemoryLedger.productionAdditional(" in physical
assert "return parallelGrain ? 72 : 64" in ledger
assert "if !parallelGrain && !serialMicrostructureActive {return 56}" in ledger
assert "serialMicrostructureActive:serialMicrostructureActive" in physical
assert "microStd>0.05" in physical
assert "candidate.estimatedPeakBytes==sourcePixels*160" in test
assert "noMicroExtra==" in test
assert "if grain && parallelGrain" in ledger
assert "let allowed=processAvailable.map{($0/10)*8} ?? physicalMemory/3" in memory
assert "remainingPeak<=($0/10)*8" in memory
assert "estimatedPeakBytes: fullSourceProcessing" in safe
assert "sourcePixels * estimatedBytesPerPixel" in safe
assert "sourcePixels * 24 + dimensions.pixels * 48" in safe
assert "max(" in safe
assert "originalBudgetPercent: UInt64 = 70" in safe
assert "Build136RAWOutputResize.resample(" in app

assert "for mask in 0..<256" in test
assert "grainOnly==64" in test
assert "estimatedPeakBytes==sourcePixels*168" in test
assert "estimatedPeakBytes==sourcePixels*(104+extra)" in test
assert "processAvailableMemory:1_500_000_000" in test

print("PASS Build140 source audit: exact 256 opt-in feature envelopes, one source gate, sequential phase peaks, original RAW export geometry, 70/80% live-memory refusal intact")
print("PENDING: 12MP A15 Jetsam/RSS samples, actual 3x3 grain and all-optics peak traces")
