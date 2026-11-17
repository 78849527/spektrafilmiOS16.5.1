#!/usr/bin/env python3
"""Build123 iOS16.5.1 native Bayer RAW crash hardening source contract."""
from pathlib import Path
r=Path(__file__).resolve().parents[2]
h=(r/"ios/SpektraFilmPort/Build94LibRawBridge.h").read_text()
m=(r/"ios/SpektraFilmPort/SFNativeCaptureSafety.m").read_text()
c=(r/"ios/SpektraFilmPort/NextLevelCamera.swift").read_text()
project=(r/"ios/project.yml").read_text()
ui=(r/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
def check(v,label):assert v,label
from build_ci_version_floor import minimum_build,minimum_minor
check(minimum_minor(project,89) and minimum_build(project,123) and
      'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project,"Build123 iOS16.5 min")
check("import NextLevel" not in c and "path: Vendor/NextLevel" not in project,
      "only native AVFoundation")
check("@class AVCapturePhotoOutput, AVCapturePhotoSettings;" in h
      and "@protocol AVCapturePhotoCaptureDelegate;" in h
      and "+ (nullable NSString *)startPhotoOutput:" in h,"bridged ObjC wrapper")
check("#import <AVFoundation/AVFoundation.h>" in m and
      '@catch (NSException *exception)' in m and
      "[output capturePhotoWithSettings:settings delegate:delegate]" in m
      and "未回退 JPEG" in m,"real ObjC validation barrier")
check("SFNativeCaptureSafety.startPhotoOutput(" in c
      and "self.captureDelegate=processor" in c
      and "self.finishFailure(problem)" in c,"guarded full native capture")
check("settings.isAutoStillImageStabilizationEnabled=false" in c
      and "settings.isHighResolutionPhotoEnabled=false" in c
      and "wantedFormat == .raw ? .speed : .balanced" in c,
      "legacy iOS16 RAW minimal processed pipeline")
check("settings.flashMode = .off" in c
      and "availableRawPhotoPixelFormatTypes.first" in c
      and "isBayerRAWPixelFormat" in c
      and "rawPixelFormatType:raw,processedFormat:dictionary" in c,
      "supported Bayer RAW and no incompatible flash")
check('self.output.connection(with:.video)?.isEnabled == true' in c
      and "self.videoInput != nil" in c and
      "self.session.isRunning" in c,"video session output connection guard")
check("didFinishProcessingPhoto photo:AVCapturePhoto" in c
      and "didFinishCaptureFor resolvedSettings:AVCaptureResolvedPhotoSettings" in c
      and "if photo.isRawPhoto {" in c,"both native RAW/JPEG delegates")
check('NativeRAWCaptureTrace.mark(' in c
      and "UserDefaults.standard.set(stage,forKey:key)" in c
      and "NativeRAWCaptureTrace.unresolved()" in c
      and "最后阶段" in c,"crash breadcrumb persisted without image payload")
check("if !capturing {NativeRAWCaptureTrace.clear()}" in c
      and "NativeRAWCaptureTrace.clear()" in c
      and "RAW 拍摄未返回 DNG" in c,"clear known errors, not fake crash")
check("self?.captureDelegate=nil" in c and
      "self.sessionQueue.async {[weak self]" in c,"delegate lifecycle on session queue")
check("rawDNG:raw" in c and "NativeCameraAspectCrop.processed(" in c,
      "unchanged DNG and separately cropped JPEG")
check("private func switchInfoButton(" in ui and
      "private struct PrecisionRequest:Identifiable" in ui,
      "Build121/122 UI unchanged")
print("PASS Build123 16.5 Bayer RAW settings guard, synchronous ObjC AVFoundation NSException interception, capture-phase diagnostics, untouched DNG and original iOS16.5 optical/UI base; device crash still unverified")
