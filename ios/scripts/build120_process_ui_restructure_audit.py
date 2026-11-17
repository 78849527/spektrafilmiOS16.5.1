#!/usr/bin/env python3
"""Build120 iOS16.5.1: stage-owner UI; no renderer or parameter defaults changed."""
from pathlib import Path

root=Path(__file__).resolve().parents[2]
ui=(root/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
project=(root/"ios/project.yml").read_text()
def contains(fragment,body,label):
    assert fragment in body,(label,fragment)
def between(text,begin,end):
    assert text.count(begin)==1 and text.count(end)==1,(begin,end)
    a=text.index(begin);b=text.index(end,a)
    return text[a:b]
advanced=between(ui,"    private var advancedControls: AnyView {",
                 "    private var adjustmentDetailContent: AnyView {")
camera=between(ui,"    private var processCameraSettings: some View {",
               "    private var processFilmSettings: some View {")
film=between(ui,"    private var processFilmSettings: some View {",
             "    private var processPaperSettings: some View {")
paper=between(ui,"    private var processPaperSettings: some View {",
              "    private var processScannerSettings: some View {")
scanner=between(ui,"    private var processScannerSettings: some View {",
                "    // First row: only features with parameter panels.")
workflow=between(ui,"    private var processControls: AnyView {",
                 "    private var processSettings: AnyView {")
contains('Text("高级 · 验证与诊断")',advanced,"advanced diagnostic only")
contains("statusReportPresented=true",advanced,"advanced open diagnostic")
for forbidden in ["featureRow","simpleSwitchRow","activeSettings",
                  "morphSlider(", "strengthControl(", "resetToggle(",
                  "sourceModeControl(", "onRefresh()", "queueSpectralPreview()"]:
    assert forbidden not in advanced,("advanced cannot change image",forbidden)
contains('Button("验证状态与诊断")',ui,"advanced menu direct diagnostics")
contains('Button("验证概况")',ui,"advanced overview")
contains('case .laboratory: return AnyView(advancedControls)',ui,
         "preserve lazy-mounted diagnostic overview")
contains('editorTab(.film)',ui,"film page")
contains('editorTab(.adjustment)',ui,"adjustment page")
contains('editorTab(.workflow)',ui,"workflow page")
contains('sourceModeControl("8-bit 原版 DIR 像素直连（实验）",mode:.pixel)',
         workflow,"pixel-mode root not nested DIR")
contains('processingModeBar.padding(.horizontal,10)',workflow,
         "mode selection remains in workflow")
contains("requestSourceMode(.physical)",ui,"physical mode confirm")
contains('DisclosureGroup("原版色域路线 · Oklch / CAM16-UCS")',camera,
         "source gamut on demand in camera stage")
contains('sourceColorRouteControls',camera,"source gamut bound in camera")
assert 'sourceColorRouteControls\n                        .padding(.horizontal,10)' not in workflow, "large gamut selector must not occupy fixed dock header"
contains('primaryButton: .default(Text("确认并切换"))',ui,
         "existing confirmation dependencies")
for label in ["光谱重建 · UV / IR 参数","摄影扩散 · 原版 PSF 参数",
              "高光恢复与摄影镜头参数"]:
    contains(label,camera,"camera proper owner")
for parameter in ["sourceCameraSpectralSettings",
                  "sourceCameraOpticsDetailSettings",
                  "sourceCameraDiffusionSettings"]:
    contains(parameter,camera,"camera actual parameter binding")
for label in ["层间扩散 · 原版 FIR/YVV 参数",
              "乳剂散射＋背反射 · 专业参数",
              "三亚层颗粒 · 染料云与微结构参数",
              "快速颗粒 · 专业参数"]:
    contains(label,film,"film proper owner")
for parameter in ["processDIRDetailSettings","sourceFilmHalationDetailSettings",
                  "sourcePhysicalGrainSettings","grainSettings"]:
    contains(parameter,film,"film source binding")
for label in ["相纸 s023 · 显影曲线参数","放大机 · 光源与滤色数据库",
              "预闪光 · 曝光与 M / Y 滤色","印相扩散 · 原版 PSF 参数"]:
    contains(label,paper,"paper proper owner")
for parameter in ["morphologySettings","enlargerSettings","preflashSettings",
                  "sourcePrintDiffusionSettings"]:
    contains(parameter,paper,"paper source binding")
for label in ["原版扫描 XYZ 眩光参数","原版扫描镜头与 Unsharp 参数"]:
    contains(label,scanner,"scanner proper owner")
for parameter in ["sourceScannerGlareSettings","sourceScannerOpticalDetailSettings"]:
    contains(parameter,scanner,"scanner source binding")
for item in ["processTab(.camera)","processTab(.film)","processTab(.paper)",
             "processTab(.scanner)"]:
    contains(item,workflow,"4 stages remain visible")
contains("if isReversal && selectedProcessStage == .paper",ui,
         "reversal skips paper")
contains("adjustmentDetailReady",ui,"iOS16.5.1 staged mounting")
contains("private var processDIRDetailSettings: AnyView",ui,
         "source FIR controls not deleted")
contains("private var sourceCameraSpectralSettings: AnyView",ui,
         "UV/IR original controls not deleted")
contains("private var sourcePhysicalGrainSettings: AnyView",ui,
         "microstructure controls not deleted")
assert ui.count("value:$model.sourcePhysicalGrainEnabled")==2
assert ui.count("value:$model.sourceScannerGlareEnabled")==1
assert ui.count('Picker("原版光谱重建"')==1
from build_ci_version_floor import minimum_build,minimum_minor
assert minimum_build(project,120) and minimum_minor(project,86)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
print("PASS Build120 Advanced diagnostic-only; process modes, camera/film/paper/scanner stage-owned optical controls; unchanged source bindings, user confirmations, lazy SwiftUI mounting and iOS16.5 min")
