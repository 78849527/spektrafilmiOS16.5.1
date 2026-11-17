#!/usr/bin/env python3
"""Build121: clear closed/locked state with tappable !. UI-only source audit."""
from pathlib import Path
r=Path(__file__).resolve().parents[2]
ui=(r/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
version=(r/"ios/project.yml").read_text()
def expect(s,part=ui):
    assert s in part,repr(s)
def segment(a,b):
    assert ui.count(a)==1 and ui.count(b)==1
    return ui[ui.index(a):ui.index(b,ui.index(a))]
mode=segment("    private func sourceModeControl(","    /// Change top titles")
simple=segment("    private func simpleToggle(","    // Top feature row")
reset=segment("    private func resetToggle(","    private func exposureControl(")
guidance=segment("    private struct SwitchExplanation:Identifiable","    private var directPixelMode")
dock=segment("    var body: some View {","    private func togglePhotoZoom()")
texture=segment("    private var dailyTextureSettings: some View {",
                "    private var dailyDetailSettings: some View {")
assert ui.count("private func switchInfoButton(")==1
assert ui.count("private func switchGuidance(")==1
expect("@State private var switchExplanation:SwitchExplanation?")
expect("let id=UUID()",guidance)
for func,name in [(reset,"resetToggle"),(simple,"simpleToggle"),
                  (mode,"sourceModeControl")]:
    expect("switchGuidance(",func)
    expect("switchInfoButton(title,guidance:note)",func)
    expect("Text(note.summary)",func)
    expect("if let note {",func)
    assert ".disabled(!enabled)\n    }" not in func,(name,"entire row disabled, ! cannot tap")
    assert ".disabled(!ready)\n    }" not in func,(name,"entire row disabled, ! cannot tap")
expect(".alert(item:$switchExplanation)",dock)
expect("dismissButton:.default(Text(\"知道了\"))",dock)
expect("title:title,summary:guidance.summary,",guidance)
expect("details:guidance.details",guidance)
expect('summary:"当前关闭 · 点击开关即可开启"',guidance)
expect('let state=isOn ? "已开启并锁定" : "当前不可操作"',guidance)
expect("explicitReason:String?=nil",guidance)
expect("if !model.hasPhoto",guidance)
expect("if model.busy",guidance)
expect("switchExplanation=SwitchExplanation(",guidance)
expect('Image(systemName:"exclamationmark.circle")',guidance)
expect(".frame(width:30,height:32)",guidance)
expect("只显示条件说明，不会自动切换开关",guidance)
for reason in [
    "原版像素直连依赖 DIR",
    "原版像素路径不运行旧版快速随机颗粒",
    "需要先在「工艺 → 拍摄」开启「测光与镜头处理」",
    "彩色负片的精细冲印依赖原版放大机",
    "精细冲印依赖原版光谱扫描",
    "8-bit 原版 DIR 像素直连不支持旧版背反射光晕",
    "当前原版像素路线不允许独立切换旧版 s023",
    "精细冲印强制要求 Hanatos Float64",
]:
    expect(reason,guidance)
for path in [
    "工艺 → 拍摄","工艺 → 胶片","工艺 → 扫描",
]:
    expect(path,guidance)
expect("model.spatialDIREnabled",mode)
expect("model.spatialDIRSourceConvolutionEnabled",mode)
expect("model.originalPixelInputAvailable",mode)
expect("model.photoDirectInputReady",mode)
expect("sourceInputCompatibilityAlert=true",mode)
expect("requestSourceMode(mode)",mode)
expect(".disabled(blocked)",mode)
expect("model.hasPhoto && !model.busy && allowed",simple)
expect("confirmedSimpleLock(title)",simple)
expect(".disabled(!ready)",simple)
expect("guard enabled else{return}",reset)
expect(".disabled(!enabled)",reset)
expect('resetToggle("原版三亚层颗粒",',texture)
expect("value:$model.sourcePhysicalGrainEnabled",texture)
expect("if fullPhysicalMode {",texture)
expect('resetToggle("胶片颗粒",',texture)
expect("if model.grainEnabled && !directPixelMode",texture)
assert ui.count("value:$model.sourcePhysicalGrainEnabled")==2
# An active ON but unlocked item keeps compact height. Locked ON stays
# inspectable even when the actual switch button is disabled.
expect("guard !enabled || !isOn else {return nil}",guidance)
# Preserve original confirmation / fail-closed algorithms and preview size.
expect("requiredChanges(for: mode)",ui)
expect("commitSourceMode(mode)",ui)
expect('primaryButton: .default(Text("确认并切换"))',ui)
expect("selectedProcessStage",ui)
expect("private var photoFloatingNotices:some View",ui)
expect('IPHONEOS_DEPLOYMENT_TARGET: "16.5"',version)
expect('MARKETING_VERSION: "1.8.87"',version)
expect('CURRENT_PROJECT_VERSION: "121"',version)
print("PASS Build121 3 visible switch types, locked/on + off reasons, tappable independent !, exact mode dependency help, same original grain binding, no automatic setting mutation and iOS16.5 source scope")
