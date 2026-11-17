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
require("专业参数与验证状态")
require("13MP、RAW 与 Python 原版整图仍未认证")
# Historical contracts stay valid across the new Build116 revision.
assert 'MARKETING_VERSION: "1.8.82"' in project
assert 'CURRENT_PROJECT_VERSION: "116"' in project
# The user-facing scanner switch has one owner; advanced retains only parameters.
assert ui.count("value:$model.sourceScannerGlareEnabled")==1
assert 'resetToggle("扫描眩光 · 受控单线程"' in ui
assert "固定 seed=8888 · 单线程受控" in ui
assert "扫描 XYZ 眩光开关：工艺 → 扫描" in ui
# The original enlarger controls now live in the paper process stage.
assert ui.count('morphSlider("青色 C / CC"')==1
assert ui.count('morphSlider("洋红 M / CC"')==1
assert ui.count('morphSlider("黄色 Y / CC"')==1
assert 'DisclosureGroup("滤色片 · C / M / Y")' in ui
# Never confuse the old scanner CAM16 lookup with original Float64 CAM16-UCS.
assert '快速 CAM16 LUT · 查表插值' in ui
assert '快速 ACES RGC · 非原版 Float64 CAM16-UCS' in ui
# The exact two existing physical route switches remain in the untouched model.
require("@Published var sourcePhysicalInputOklchEnabled = false",model)
require("@Published var sourcePhysicalCAM16DefaultGamutEnabled = false",model)
memory=(r/"ios/SpektraFilmPort/SafeExportResolution.swift").read_text()
require("static let intelligentMaximumBudget: UInt64 = 1_300_000_000",memory)
require("static let intelligentBudgetPercent: UInt64 = 90",memory)
require('Button("智能安全分辨率（最高 1200 万像素 · 预算最多 1300 MB）")')
require('resetToggle("快速胶片散射"')
require('resetToggle("快速胶片颗粒"')
require('resetToggle("相纸显影曲线 s023"')
require('resetToggle("黑白场校准"')
require('resetToggle("扫描曝光参考"')
require('resetToggle("印相曝光归一化"')
require('resetToggle("印相曝光补偿"')
require('尚未认证：13MP 全光学、Python 整图、RAW/高位深全链、默认多线程随机。')
print("PASS Build113 fixed overlay, 4 source routes, smart 1300MB max, quick/process controls and separated certification labels")
