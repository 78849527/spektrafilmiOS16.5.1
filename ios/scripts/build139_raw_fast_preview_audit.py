#!/usr/bin/env python3
"""Build139 source checks: quick RAW preview only; full RAW export unmodified."""
from pathlib import Path

root=Path(__file__).resolve().parents[2]
load=lambda p:(root/p).read_text()
app=load("ios/SpektraFilmPort/ContentView.swift")
ui=load("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
ingress=load("ios/SpektraFilmPort/P1OriginalRawACESIngress.swift")
reducer=load("ios/SpektraFilmPort/Build139RAWPreviewDownsample.swift")
test=load("ios/tests/Build139RAWPreviewDownsampleValidation.swift")
project=load("ios/project.yml")

assert 'maxLongEdge: Int = 1280' in ingress
assert 'static func developPreviewCandidate(' in ingress
quick=ingress.split("static func developPreviewCandidate(",1)[1].split(
    "    /// Match original rawpy:",1
)[0]
full=ingress.split("static func developSourceCandidate(",1)[1].split(
    "    /// Build139:",1
)[0]
assert 'Build139RAWPreviewDownsample.frame(' in quick
assert 'OriginalSourcePhysicalImage.developInPlace(' in quick
assert 'OriginalSourcePhysicalImage.developInPlace(' in full
assert 'makeSourceFrame(' in full
assert 'Build139RAWPreviewDownsample' not in full
assert 'selected.cameraInputColorSpace = .acesLinear' in quick
assert 'selected.cameraInputColorSpace = .acesLinear' in full
assert 'maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels' in quick
assert 'Float(v)/Float(65535.0)' in reducer
assert 'CGImage' not in reducer and 'CIImage' not in reducer
assert 'width <= 13_000_000 / height' in reducer
assert 'maxLongEdge >= 256, maxLongEdge <= 2048' in reducer
assert 'let xt=taps(source:width,target:outW)' in reducer
assert 'let yt=taps(source:height,target:outH)' in reducer
assert 'full-sized Float64' in reducer
assert 'precondition(' in test

refresh=app.split("    func refresh() throws {",1)[1].split(
    "    /// Keep the complete eight-stage",1
)[0]
assert 'let fullSourcePreview=rawFullResolutionPreview' in refresh
assert 'if fullSourcePreview {' in refresh
assert 'P1OriginalRawACESIngress.developSourceCandidate(' in refresh
assert 'P1OriginalRawACESIngress.developPreviewCandidate(' in refresh
assert 'maxLongEdge:1280' in refresh
assert 'self.processedPreview=rendered.0' in refresh
assert 'rawFullResolutionPreview=false' in app
assert 'func selectRAWPreview(fullResolution:Bool)' in app
assert 'queueSpectralPreview()' in app

jpeg=app.split("    func exportJPEG(",1)[1].split("    /// Build128:",1)[0]
tiff=app.split("    func exportTIFF16(",1)[1].split(
    "    /// Export a truthful MACHINE-READABLE",1
)[0] if "    /// Export a truthful MACHINE-READABLE" in app.split("    func exportTIFF16(",1)[1] else app.split("    func exportTIFF16(",1)[1]
for name,section in [("JPEG",jpeg),("TIFF16",tiff)]:
    assert 'P1OriginalRawACESIngress.developSourceCandidate(' in section,name
    assert 'P1OriginalRawACESIngress.developPreviewCandidate(' not in section,name
    assert 'Build136RAWOutputResize.resample(' in section,name

assert 'model.selectRAWPreview(fullResolution:false)' in ui
assert 'model.selectRAWPreview(fullResolution:true)' in ui
assert '导出始终重新以 RAW 原尺寸精细冲印' in ui
from build_ci_version_floor import minimum_build,minimum_minor
assert minimum_build(project,139)
assert minimum_minor(project,105)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
print("PASS Build139: bounded genuine RAW preview, full-preview choice, unchanged full optical JPEG/TIFF16 export")
print("NOT CERTIFIED: measured on-device speed, full-size spatial parity, RAW sensor/source rawpy parity")
