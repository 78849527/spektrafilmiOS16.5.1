#!/usr/bin/env python3
"""P1 direct RAW source production topology audit, no numerical certification."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
def read(path): return (root/path).read_text()
app=read("ios/SpektraFilmPort/ContentView.swift")
ui=read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
source=read("ios/SpektraFilmPort/P1OriginalRawACESIngress.swift")
engine=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
writer=read("ios/SpektraFilmPort/Build90NativeOutputWriter.swift")
tokens=[
    "rawOriginalSourceActive && capturedRAWURL != nil && source != nil",
    "if rawOriginalSourceActive {",
    "P1OriginalRawACESIngress.developSourceCandidate(",
    "Build90NativeOutputWriter.write(",
    "format:.jpeg,bitDepth:8,outputSpace:\"sRGB\"",
    "format:.tiff,bitDepth:16,outputSpace:\"sRGB\"",
    "RAW 原片直通精细冲印（P1 真机测试）",
    "preferOriginalSource:true",
    "RAW 原片精细冲印失败（禁止降级）",
]
for token in tokens: assert token in app,token
assert "model.enableDirectRAWSource()" in ui
assert "selected.cameraInputColorSpace = .acesLinear" in source
assert "OriginalSourcePhysicalImage.developInPlace(" in source
assert "guard frame.rgb.allSatisfy({ $0.isFinite })" in engine
assert "Build90GeneratedSourceICC.exactProfile" in writer
assert "sourcePixelIOEnabled && sourcePhysicalDirectEnabled" in app
assert "rawpy" in app
print("PASS P1 raw original direct UI / render / JPEG / TIFF16 fail-closed topology")
print("NOT CERTIFIED: actual camera rawpy pixel parity, macOS arm64 build, 40MP full image and iOS16.5.1 hardware")
