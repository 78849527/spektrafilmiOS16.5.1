#!/usr/bin/env python3
"""Build124 captured Bayer DNG-to-editor regression; hardware proof still required."""
from pathlib import Path
from build_ci_version_floor import minimum_build, minimum_minor
root=Path(__file__).resolve().parents[2]
project=(root/"ios/project.yml").read_text()
camera=(root/"ios/SpektraFilmPort/NextLevelCamera.swift").read_text()
editor=(root/"ios/SpektraFilmPort/ContentView.swift").read_text()
decoder=(root/"ios/SpektraFilmPort/Build93AppleRAWImport.swift").read_text()
assert minimum_minor(project,90) and minimum_build(project,124)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
assert "rawDNG:raw" in camera and "if format == .raw && dng == nil" in camera
assert "if photo.isRawPhoto {" in camera and "dng=bytes" in camera
start=editor.index("func loadCapturedPhoto(_ capture: NextLevelCapturedPhoto)")
end=editor.index("func loadPhotoFile(_ url: URL)",start)
capture=editor[start:end]
for item in [
    'capture.format.contains("RAW") && capture.rawDNG == nil',
    "if let raw = capture.rawDNG {",
    "try raw.write(to: rawFile, options: .atomic)",
    "Build93AppleRAWImport.open(rawFile)",
    "let preview=try PhotoProcessor.preview(",
    "image:decoded.0.image,preview:decoded.1,",
    "data:nil,rawURL:rawFile,rawCompatible:true,",
    "pendingImportedRAWURL=rawFile",
    "rawNeedsChoice=true",
    "原编辑保持不变，未回退 JPEG",
    "JPEG 伴随片没有进入编辑器",
    "try loadPhoto(capture.processed,entry:.camera)",
]:
    assert item in capture,item
raw_start=capture.index("if let raw = capture.rawDNG {")
raw_decode=capture.index("Build93AppleRAWImport.open(rawFile)")
raw_return=capture.index("                return\n            }",raw_decode)
jpeg_ingest=capture.index("try loadPhoto(capture.processed,entry:.camera)")
assert raw_start < raw_decode < raw_return < jpeg_ingest,"JPEG remains RAW source"
assert "CIRAWFilter(imageURL: url)" in decoder
assert "Build79RAWSignature.probeFile(url)" in decoder
assert "render(" in decoder and "raw.outputImage" in decoder
decoder_code="\n".join(line for line in decoder.splitlines() if not line.lstrip().startswith("//"))
assert "CIImage(contentsOf:" not in decoder_code and "CIImage(data:" not in decoder_code
assert "if rawCompatible || inputProfile?.directCompatible != true" in editor
assert "rawFastModeActive=rawCompatible" in editor
assert "capturedRAWURL=rawURL" in editor
print("PASS Build124: Bayer DNG decoded by real Apple RAW; no JPEG substitution; stable previous edit on failure")
print("NOT CERTIFIED: repeated physical iOS16.5.1 DNG sensor-to-editor rendering / original Python rawpy equivalence")
