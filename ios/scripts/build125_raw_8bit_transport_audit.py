#!/usr/bin/env python3
"""Build125 explicit Apple RAW -> certified 8-bit sRGB transport source contract.

This verifies that the new optional transport does not silently relabel Apple
RAW as source-equivalent Python rawpy or replace the preserved original DNG.
The physical-device sensor-to-image result still requires a real iPhone test.
"""
from pathlib import Path
from build_ci_version_floor import minimum_build, minimum_minor

root=Path(__file__).resolve().parents[2]
app=(root/"ios/SpektraFilmPort/ContentView.swift").read_text()
ui=(root/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
renderer=(root/"ios/SpektraFilmPort/Build125RAW8BitTransport.swift").read_text()
profile=(root/"ios/SpektraFilmPort/Build111PhotoInputProfile.swift").read_text()
project=(root/"ios/project.yml").read_text()

assert minimum_minor(project,91) and minimum_build(project,125)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project

for proof in [
    "enum Build125RAW8BitTransport",
    "static func makeCertifiedCopy(_ rawImage:CIImage) throws -> Data",
    "bounds.width*bounds.height<=16_000_000",
    "context.createCGImage(",
    "from:bounds,format:.RGBA8,colorSpace:srgb",
    "UTType.jpeg.identifier",
    "kCGImageDestinationLossyCompressionQuality:0.98",
    "Build111PhotoInputProfile.inspect(",
    "check.directCompatible",
    "check.color == .sRGB",
]:
    assert proof in renderer,proof
assert ".resize(" not in renderer and "scaleTransform" not in renderer
assert "DNG" in renderer and "not sensor" in renderer

for proof in [
    "func convertActiveRAWTo8BitSRGBCopy()",
    "guard !busy,rawFastModeActive,",
    "let preservedDNG=capturedRAWURL",
    "Build125RAW8BitTransport.makeCertifiedCopy(rawImage)",
    "entry:.converted",
    "guard profile.directCompatible",
    "rawURL:preservedDNG,rawCompatible:false",
    "inputProfile:profile",
    "保持 RAW 冲印与原始 DNG",
]:
    assert proof in app,proof

assert "if rawFastModeActive && capturedRAWURL != nil" in app
assert "旧 8-bit 副本仍为可选" in app
assert "可直接进行兼容光学处理并最终导出 TIFF16" in app
assert "兼容：生成 RAW 的 8-bit sRGB JPEG（保留 DNG）" in ui
assert "model.convertActiveRAWTo8BitSRGBCopy()" in ui
assert "RAW 可直接冲印；精确直连优先选 Float32 TIFF 副本" in ui
assert "if rawCompatible || inputProfile?.directCompatible != true" in app
assert "rawFastModeActive=rawCompatible" in app
assert "rawDNG" in (root/"ios/SpektraFilmPort/NextLevelCamera.swift").read_text()
assert "directCompatible" in profile and "declaredDepth==8" in profile

raw_capture=app[app.index("func loadCapturedPhoto("):app.index("func loadPhotoFile(")]
assert "convertActiveRAWTo8BitSRGBCopy()" not in raw_capture
assert "data:nil,rawURL:rawFile,rawCompatible:true" in raw_capture
assert "JPEG 伴随片没有进入编辑器" in raw_capture
print("PASS Build125: real Apple RAW remains editable, explicit JPEG8 copy passes Build111; sensor DNG retained, no automatic downgrade")
print("NOT CERTIFIED: RAW->sRGB output equals original Python rawpy processing; iPhone16.5.1 whole-frame photo/precision parity")
