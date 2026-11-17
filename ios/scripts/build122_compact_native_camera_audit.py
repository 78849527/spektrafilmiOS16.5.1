#!/usr/bin/env python3
"""Build122 compact slider + native AVFoundation camera strict UI and safety audit."""
from pathlib import Path
r=Path(__file__).resolve().parents[2]
ui=(r/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
camera=(r/"ios/SpektraFilmPort/NextLevelCamera.swift").read_text()
main=(r/"ios/SpektraFilmPort/ContentView.swift").read_text()
project=(r/"ios/project.yml").read_text()
def check(condition,why):
    assert condition,why
from build_ci_version_floor import minimum_build,minimum_minor
check(minimum_build(project,122) and minimum_minor(project,88),"Build122 version floor")
check('IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project,"min iOS 16.5")
check("import NextLevel" not in camera and "path: Vendor/NextLevel" not in project
      and "- package: NextLevel" not in project,"no NextLevel package")
check("NativeCameraScreen(" in main and
      "struct NextLevelCapturedPhoto" in camera and
      "func loadCapturedPhoto(_ capture: NextLevelCapturedPhoto)" in main,
      "preserved app capture data contract")
check("let session=AVCaptureSession()" in camera and
      "private let sessionQueue=DispatchQueue(" in camera,"native session queue")
check("AVCaptureDevice.requestAccess(for:.video)" in camera,"permission handling")
check("availableRawPhotoPixelFormatTypes.first" in camera and
      "isBayerRAWPixelFormat" in camera,"actual supported Bayer RAW formats")
check("rawPixelFormatType:raw,processedFormat:dictionary" in camera,
      "RAW+processed pair")
check("settings.isAutoStillImageStabilizationEnabled=false" in camera and
      "wantedFormat == .raw ? .speed : .balanced" in camera,
      "safe RAW settings (and max quality set prior to start)")
check("private var captureDelegate:NativePhotoCaptureDelegate?" in camera and
      "self.captureDelegate=processor" in camera and
      "didFinishCaptureFor resolvedSettings" in camera and
      "didFinishProcessingPhoto photo:AVCapturePhoto" in camera,
      "correct lifetime/completion delegate")
check("if format == .raw && dng == nil" in camera and
      "RAW 拍摄未返回 DNG" in camera,"no silent JPEG RAW substitution")
check("raw.write(to: output, options: .atomic)" in main and
      "try loadPhoto(capture.processed,entry:.camera)" in main,
      "DNG archival and same optical ingress")
for s in ['case fourThree="4:3"','case threeTwo="3:2"',
          'case sixteenNine="16:9"','case square="1:1"']:
    check(s in camera,s)
check("ratio.portraitAspect" in camera and
      "NativeCameraAspectCrop.processed(" in camera,
      "real crop output and ratio preview")
check("let raw=dng" in camera and "rawDNG:raw" in camera,
      "unmodified DNG bytes preserved")
for lens in [".builtInUltraWideCamera",".builtInWideAngleCamera",
             ".builtInTelephotoCamera"]:
    check(lens in camera,lens)
check("private struct PrecisionRequest:Identifiable" in ui and
      "@State private var precisionEdit:PrecisionRequest?" in ui and
      ".sheet(item:$precisionEdit)" in ui,
      "numeric sheet owner iOS16.5.1")
check("Double(input.trimmingCharacters" in ui and
      "n.isFinite && request.range.contains(n)" in ui,
      "finite exact numeric input with bounds")
check("request.apply(value)" in ui and
      "error=\"数值无效或超过参数范围；未修改照片\"" in ui,
      "explicit numeric failure handling")
check("Button(\"恢复默认\")" in ui and
      "request.increment" in ui,"+/- and original defaults")
check("UIGraphicsImageRenderer(size:CGSize(width:12,height:12))" in ui and
      "CompactOpticalUISlider:UISlider" in ui and
      "bounds.insetBy(dx:-8,dy:-10)" in ui,
      "compact 12pt knob with retained touch target")
check("isContinuous=true" in ui and
      "@objc func finished(_ slider:UISlider)" in ui,
      "continuous visual scrub, renderer commit only on release")
check("private func exposureControl(" in ui and
      "increment:0.01,resetTo:0,unit:\"EV\"" in ui,
      "exposure fine 0.01EV")
check("private func morphSlider(" in ui and
      "let increment:Double =" in ui and
      "title:title,value:value,range:range" in ui,
      "original source range and dynamic fine increment")
check("private func strengthControl(" in ui and
      "increment:0.01,resetTo:resetTo,unit:suffix" in ui,
      "strength fine 0.01")
check('title:"效果强度",value:Binding(' in ui and
      "set:{model.strength=$0/100}" in ui and
      "range:0...100,increment:1" in ui,
      "percent inputs do not change internal 0...1 range")
check("Text(\"点右侧数值精确输入 · 双击左侧名称复原\")" in ui,
      "explicit new numeric semantics")
check('primaryButton: .default(Text("确认并切换"))' in ui and
      "sourcePhysicalDirectEnabled" in main,"original precision mode confirmation unchanged")
check("private func switchInfoButton(" in ui and
      "private func resetToggle(" in ui,"Build121 ! preserved")
check("private var photoFloatingNotices:some View" in ui and
      "adjustmentDetailReady" in ui,"staged editor and preview")
print("PASS Build122 native AVCapture session + Bayer RAW companion and 4-ratio output, compact slider/finite Double entry, legacy source modes and Build121 status preserved; hardware RAW proof pending")
