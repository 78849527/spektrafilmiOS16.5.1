#!/usr/bin/env python3
"""Build129 additional UI & ordinary-photo precise mode regression.

A failed input *must not* disable Precise mode; tap should open the
specific RAW / ICC-verified ordinary photo conversion choices.
No blind rawpy claim or silent JPEG8 downgrade.
"""
from pathlib import Path
from build_ci_version_floor import minimum_build,minimum_minor
p=Path(__file__).resolve().parents[2]
ui=(p/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
app=(p/"ios/SpektraFilmPort/ContentView.swift").read_text()
project=(p/"ios/project.yml").read_text()
assert minimum_build(project,129) and minimum_minor(project,95)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
bar=ui.split("    private var processingModeBar: some View {",1)[1].split("    // Build112:",1)[0]
assert 'if !fullPhysicalMode { requestSourceMode(.physical) }' in bar
assert '.disabled(!model.hasPhoto || model.busy)' in bar
assert 'model.lut == nil || !model.originalPixelInputAvailable)' not in bar
assert '点「精细冲印」打开输入检测' in bar
mode=ui.split("    private func requestSourceMode(",1)[1].split("    private func commitSourceMode(",1)[0]
assert 'sourceInputCompatibilityAlert=true' in mode
assert '!model.photoDirectInputReady' in mode
# Build138 source RAW precision is not a compatibility LUT operation.
# Ordinary images still require their validated LUT/input prerequisites.
assert 'let sourceRAWReady=model.rawOriginalSourceActive &&' in mode
assert '(model.lut != nil || (mode == .physical && sourceRAWReady))' in mode
assert 'model.originalPixelInputAvailable' in mode
assert "if mode == .pixel &&" not in mode or "spatialDIREnabled" not in mode
changes=ui.split("    private func requiredChanges(",1)[1].split("    private func requestSourceMode(",1)[0]
assert 'changes.append("启用胶片层间扩散")' in changes
assert 'changes.append("启用原版 FIR/YVV 空间扩散计算")' in changes
control=ui.split("    private func sourceModeControl(",1)[1].split("    /// Change top titles",1)[0]
assert 'let blocked = model.busy || !model.hasPhoto' in control
assert 'model.originalPixelInputAvailable' in control
assert 'sourceInputCompatibilityAlert=true' in control
dialog=ui.split('.confirmationDialog("原版像素输入检测"',1)[1].split('.alert(item: $pendingSourceMode)',1)[0]
assert 'model.rawFastModeActive && model.capturedRAWURL != nil' in dialog
assert 'model.convertActiveRAWToFloat32ExtendedSRGBCopy()' in dialog
assert 'model.photoHighDepthCopyPossible && !model.busy' in dialog
assert 'model.convertActivePhotoToFloat32Copy()' in dialog
assert 'model.convertCurrentP3ToSRGB()' in dialog
assert 'func convertActivePhotoToFloat32Copy()' in app
assert 'var photoHighDepthCopyPossible:Bool' in app
assert 'originalPhotoData != nil,source != nil' in app
assert 'p.color == .sRGB' in app
assert 'p.color == .displayP3' in app
assert 'p.color == .extendedSRGB' in app
ordinary=app.split("    func convertActivePhotoToFloat32Copy() {",1)[1].split("    // Build126 recipes",1)[0]
assert 'let originalBytes=originalPhotoData' in ordinary
assert 'let result=try await Task.detached' in ordinary
assert 'Build128RAWFloat32Transport.makeVerifiedCopy(image)' in ordinary
assert 'try commitDecodedPhoto(' in ordinary
assert 'inputProfile:result.admission' in ordinary
assert 'photoOriginalBeforeColorConversion=originalBytes' in ordinary
assert 'status="普通照片 Float32 副本生成失败' in ordinary
assert 'JPEG8' in ordinary
commit=ui.split("    private func commitSourceMode(",1)[1].split("    private func sourceModeControl(",1)[0]
assert 'model.spatialDIREnabled = true' in commit
assert 'model.spatialDIRSourceConvolutionEnabled = true' in commit
assert 'model.sourcePhysicalDirectEnabled = true' in commit
print("PASS Build129: precise UI remains tappable for RAW/ordinary images; diagnostic repair opens; Float32 optional; DIR/full source opt-in confirmation; no JPEG8 fallback")
print("HARDWARE PENDING: actual iOS16.5.1 ordinary P3/HEIC + RAW user workflow and device memory")
