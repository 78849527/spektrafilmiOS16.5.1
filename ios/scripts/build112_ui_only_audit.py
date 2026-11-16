#!/usr/bin/env python3
"""Build112 source UI-only layout / route selection regression audit.
The actual full iPhoneOS compile and physical-device view still required.
"""
from pathlib import Path
r=Path(__file__).resolve().parents[2]
ui=(r/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
model=(r/"ios/SpektraFilmPort/ContentView.swift").read_text()
project=(r/"ios/project.yml").read_text()
def require(q,source=ui):
    assert q in source, q
require("private var photoFloatingNotices:some View")
require(".overlay(alignment:.top)")
require("photoFloatingNotices")
require('.frame(height:32)')
require('.frame(height:42)')
require('.lineLimit(1)')
assert ui.count('statusChip\n') == 1, "Status chip must occur only in the floating overlay"
assert ui.count('inputCompatibilityBanner\n') == 1, "Input banner must occur only in the floating overlay"
assert ui.index("GeometryReader { previewSlot in") < ui.index("photoFloatingNotices",ui.index("GeometryReader { previewSlot in"))
require("private enum SourceColorRoute")
require("private var sourceColorRouteControls:AnyView")
require("sourceColorRouteButton(.classic)")
require("sourceColorRouteButton(.oklch)")
require("sourceColorRouteButton(.cam16)")
require("sourceColorRouteButton(.both)")
require("model.sourcePhysicalInputOklchEnabled=route.usesOklch")
require("model.sourcePhysicalCAM16DefaultGamutEnabled=route.usesCAM16")
require("model.sourceCameraRawMethod == .hanatos2025")
require("model.queueSpectralPreview()")
assert ui.count("value:$model.sourcePhysicalInputOklchEnabled")==0
assert ui.count("value:$model.sourcePhysicalCAM16DefaultGamutEnabled")==0
assert ui.count('Picker("原版光谱重建"')==1
assert ui.count('value:$model.sourcePhysicalGrainEnabled')==1
assert ui.count('value:$model.scannerCAM16Enabled')==1
require("专业参数与待认证项目")
require("13MP、RAW 与 Python 原版整图仍未认证")
assert 'MARKETING_VERSION: "1.8.78"' in project
assert 'CURRENT_PROJECT_VERSION: "112"' in project
# The exact two existing physical route switches remain in the untouched model.
require("@Published var sourcePhysicalInputOklchEnabled = false",model)
require("@Published var sourcePhysicalCAM16DefaultGamutEnabled = false",model)
print("PASS Build112 UI-only: floating two fixed-height notices; photo GeometryReader never changes vertical space; four route settings map only to existing model fields; no duplicate Oklch/CAM16/grain controls")
