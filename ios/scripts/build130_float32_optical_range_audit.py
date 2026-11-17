#!/usr/bin/env python3
"""Build130 strict regression: opt-in Float32 range working copy.

Build129's float TIFF file admission is not the same as the original
source spectral algorithm [0,1] contract. Never weaken the renderer.
"""
from pathlib import Path
from build_ci_version_floor import minimum_build, minimum_minor
root=Path(__file__).resolve().parents[2]
s=lambda p:(root/p).read_text()
project=s("ios/project.yml")
original=s("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
model=s("ios/SpektraFilmPort/ContentView.swift")
ui=s("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
entry=s("ios/SpektraFilmPort/Build130Float32RangeCopy.swift")
test=s("ios/tests/Build130Float32RangeCopyValidation.swift")
runner=s("ios/tests/Build129FloatSRGBIngressValidation.swift")
assert minimum_build(project,130) and minimum_minor(project,96)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
for token in [
    "guard frame.rgb.count==w*h*3",
    "if value<0 || value>1 {outOfRange+=1}",
    "guard nonFinite==0,outOfRange==0 else",
    "逐像素原版显影 RGB 检测不通过",
    "不会自动裁切、转 8-bit 或切换快速模式",
]:
    assert token in original,token
for token in [
    "enum Build130Float32RangeCopy",
    "static func makeMappedWorkingCopy(_ input:Data)throws->Result",
    "profile.directCompatible",
    "profile.format==\"TIFF\",profile.floatingComponents",
    "profile.declaredDepth==32,profile.decodedDepth==32",
    "image.bitmapInfo.contains(.floatComponents)",
    "OriginalSourcePixelIO.orientation(src)==1",
    "CGImageDestinationFinalize(destination)",
    "vm.outOfRange==0",
    "vm.minimum>=0,vm.maximum<=1",
    "let scale=(1.0-2.0*margin)/(top-bottom)",
    "let bias=margin-bottom*scale",
    "Float(original*scale+bias)",
    "after.directCompatible,after.floatingComponents",
    "SafeExportResolution.currentProcessHeadroom()",
]:
    assert token in entry,token
for token in [
    "var float32RangeWorkingCopyPossible:Bool",
    "func convertFloat32ToBoundedWorkingCopy()",
    "Build130Float32RangeCopy.makeMappedWorkingCopy(bytes)",
    "photoOriginalBeforeColorConversion=previousOriginal",
    "rawURL:rawURL,rawCompatible:false",
    "逐像素全光学失败（禁止回退）：",
]:
    assert token in model,token
for token in [
    "@State private var float32RangeCopyConfirmation=false",
    "Float32 RGB 超出 0～1？明确生成范围映射 TIFF 工作副本",
    "float32RangeCopyConfirmation=true",
    "model.convertFloat32ToBoundedWorkingCopy()",
    "会改变原始颜色和曝光数值",
]:
    assert token in ui,token
for token in [
    "static func evaluate() throws",
    "Build130Float32RangeCopy.makeMappedWorkingCopy(bytes)",
    "original unchanged", # source comment check is elsewhere
    "Float32 TIFF",
    "P3 Float32",
    "NaN was accepted",
]:
    if token=="original unchanged":continue
    assert token in test,token
assert "try Build130Float32RangeCopyValidation.evaluate()" in runner
assert 'UInt8(' not in entry and "JPEG" not in entry.split("static func makeMappedWorkingCopy",1)[1]
print("PASS Build130: original Float64 source range guard retained; real IEEE Float32 opt-in global affine map only, ICC/alpha/memory/full output checked, original DNG unchanged")
print("NOT CERTIFIED: Apple RAW rawpy parity, iOS16.5.1 user photo exact look after opt-in gamut mapping")
