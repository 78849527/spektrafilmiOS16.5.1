#!/usr/bin/env python3
"""Build133: protect original RAW staging and the measured memory barrier."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
read=lambda p:(root/p).read_text()
ladder=read("ios/SpektraFilmPort/Build133RAWMemoryLadder.swift")
filtering=read("ios/SpektraFilmPort/SourceSpatialDIRConvolution.swift")
physical=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
ui=read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
app=read("ios/SpektraFilmPort/ContentView.swift")
project=read("ios/project.yml")
for exact in (
    "P1OriginalRawACESIngress.open(",
    "P1OriginalRawACESIngress.makeSourceFrame(",
    "OriginalSourcePhysicalImage.developInPlace(",
    "phaseMemoryObserver:{ phase in mark(phase) }",
    "status=\"failed_or_admission_refused\"",
    "sampledPeakRSS",
    "checkpointURL",
    "raw_aces16_decoded",
    "source.packedRGB16.withUnsafeBytes",
    "configured.cameraInputColorSpace = .acesLinear",
    "OriginalSourcePhysicalImage.validateMemoryBudget(",
):
    assert exact in ladder, exact
assert "private static func diagnosticPatch(" in ladder
assert "level==4" in ladder or "level == 4" in ladder
assert "var channelSource=[Double]" not in filtering
assert "filtered[p]=input[p*3+channel]" in filtering
assert "let v=B*input[p*3+channel]+B1*s1+B2*s2+B3*s3" in filtering
assert "estimatedPeakBytesPerPixel: UInt64 = 104" in physical
assert "alreadyCommittedInputBytes:committedInputBytes" in physical
assert "onRunBuild133RAWMemory: (Int) -> Void" in ui
assert "onRunBuild133RAWMemory(level)" in ui
assert "runBuild133RAWMemory(_ level:Int)" in app
assert "diagnosticPendingFeedback=pair" in app
from build_ci_version_floor import minimum_build,minimum_minor
assert minimum_build(project,133) and minimum_minor(project,99)
print("PASS Build133 real RAW 0/1/2/3/4 independent source checkpoints and 8 B/px original Double buffer elimination")
print("NO CERTIFICATION: iOS RAW end-to-end, actual Jetsam high-watermark and Python full-frame equivalence await device LOG+JSON")
