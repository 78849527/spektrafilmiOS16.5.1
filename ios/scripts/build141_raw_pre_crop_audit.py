#!/usr/bin/env python3
"""Build141 source contracts: true RAW crop ahead of Float64, one geometry."""
from pathlib import Path
base=Path(__file__).resolve().parents[2]
read=lambda name:(base/name).read_text()
ingress=read("ios/SpektraFilmPort/P1OriginalRawACESIngress.swift")
crop=read("ios/SpektraFilmPort/Build141RAWPreCrop.swift")
alg=read("ios/SpektraFilmPort/Build81OriginalCrop.swift")
ui=read("ios/SpektraFilmPort/Build141RAWCropSheet.swift")
workspace=read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
app=read("ios/SpektraFilmPort/ContentView.swift")
tests=read("ios/tests/Build141RAWPreCropValidation.swift")
project=read("ios/project.yml")
from build_ci_version_floor import minimum_build,minimum_minor
assert minimum_build(project,141) and minimum_minor(project,107)

# The source-only pixel crop must use existing original Python/NumPy
# nearest-even geometry, and never build full source Float64 pixels first.
assert "Build81OriginalCrop.region(" in crop
assert "withUnsafeMutableBytes" in crop and "copyMemory(" in crop
assert "sourceWidth==selection.sourceWidth" in crop
assert "sourceHeight==selection.sourceHeight" in crop
assert "data.count==sourceWidth*sourceHeight*6" in crop
assert "isWholeSource" in crop
assert "Float(" not in crop and "CIImage" not in crop
assert "sizeRounded=size.rounded(.toNearestOrEven)" in alg

source=ingress.split("static func developSourceCandidate(",1)[1].split(
    "/// Build139:",1
)[0]
assert "let working=try selectedSource(decoded,crop:crop)" in source
assert source.index("let working=try selectedSource") < source.index(
    "try OriginalSourcePhysicalImage.validateMemoryBudget("
) < source.index("var frame = try makeSourceFrame(") < source.index(
    "OriginalSourcePhysicalImage.developInPlace("
)
assert "width:working.width,height:working.height,parameters:selected" in source
quick=ingress.split("static func developPreviewWithGeometry(",1)[1].split(
    "/// Match original rawpy:",1
)[0]
assert quick.index("let working=try selectedSource") < quick.index(
    "Build139RAWPreviewDownsample.frame("
) < quick.index("OriginalSourcePhysicalImage.developInPlace(")
assert "sourceWidth:decoded.width,sourceHeight:decoded.height" in quick
assert "frame:frame,sourceWidth:sourceWidth,sourceHeight:sourceHeight" in quick
assert "sourceWidth=decoded.width" in quick and "sourceHeight=decoded.height" in quick
assert "sourceWidth = cached.sourceWidth" in quick and "sourceHeight = cached.sourceHeight" in quick

# The modal's uncropped reference comes from the identical LibRaw optic
# preview, never from Apple JPEG or already cropped working geometry.
assert "rawCropReferencePreview=rendered.0" in app
assert "if selectedCrop==nil" in app
assert "rawCropReferenceWidth=rendered.3" in app
assert "rawCropReferenceHeight=rendered.4" in app
assert "func setRAWCrop(" in app and "func clearRAWCrop()" in app
assert "queueSpectralPreview()" in app
assert "rawCropSelection=nil" in app
assert "let selectedCrop=rawCropSelection" in app
assert "crop:selectedCrop" in app
assert "let crop=rawCropSelection" in app
assert app.count("crop:crop")>=2

# The same crop working geometry determines memory and confirmed output.
prepare=app.split("func prepareExport(",1)[1].split("func exportJPEG(",1)[0]
assert "let opticalWidth=inputCrop?.width ?? Int(bounds.width)" in prepare
assert "let opticalHeight=inputCrop?.height ?? Int(bounds.height)" in prepare
assert "width: opticalWidth, height: opticalHeight" in prepare
assert "width:opticalWidth,height:opticalHeight" in prepare
assert "decoderOverhead" in prepare
jpeg=app.split("func exportJPEG(",1)[1].split("func exportTIFF16(",1)[0]
tiff=app.split("func exportTIFF16(",1)[1]
for name,x in [("JPEG",jpeg),("TIFF16",tiff)]:
    assert "let crop=rawCropSelection" in x,name
    assert "crop:crop" in x,name
    assert "(crop?.width ?? Int(imageSource.extent.integral.width))" in x,name
    assert "(crop?.height ?? Int(imageSource.extent.integral.height))" in x,name
    assert "Build136RAWOutputResize.resample(" in x,name
    assert "P1OriginalRawACESIngress.developPreviewWithGeometry(" not in x,name
assert "model.setRAWCrop(" in ui
assert "model.clearRAWCrop()" in ui
for title in ("自由","原比例","3:4","4:3","1:1","9:16","16:9"):
    assert title in ui,title
assert "DragGesture" in ui and ".accessibilityLabel(" in ui
assert 'toolButton("crop.rotate"' in workspace
assert 'rawCropEditorPresented' in workspace
assert 'Build141RAWCropSheet(model:model)' in workspace
assert "model.rawCropReferencePreview == nil" in workspace

assert "for ch in 0..<3" in tests
assert "source==baseline" in tests
assert "sourceWidth:384,sourceHeight:512" in tests
print("PASS Build141 crop source gates: native LibRaw / Build81 geometry, pre-Float64 crop, synced RAM/preview/JPEG/TIFF16, original source file unchanged")
print("NOT CERTIFIED: device UX, peak memory, optics boundary parity")
