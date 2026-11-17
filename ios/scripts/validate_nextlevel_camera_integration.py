#!/usr/bin/env python3
"""Build122 native AVFoundation Camera. Historical CI entry point is retained.
This is a source-level integration audit, not hardware RAW success evidence.
"""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
project=(root/"project.yml").read_text()
main=(root/"SpektraFilmPort/ContentView.swift").read_text()
ui=(root/"SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
camera=(root/"SpektraFilmPort/NextLevelCamera.swift").read_text()
required={
    "deployment iOS16.5":'iOS: "16.5"' in project,
    "native only": "import NextLevel" not in camera and
        "path: Vendor/NextLevel" not in project and
        "- package: NextLevel" not in project,
    "photo-only camera permission": "NSCameraUsageDescription:" in project
        and "NSMicrophoneUsageDescription:" not in project,
    "capture session": "AVCaptureSession()" in camera and
        "sessionQueue" in camera and ".sessionPreset = .photo" in camera,
    "image preview real session": "AVCaptureVideoPreviewLayer" in camera and
        ".resizeAspectFill" in camera,
    "native hardware lens selection":
        all(token in camera for token in [
            ".builtInWideAngleCamera",".builtInUltraWideCamera",
            ".builtInTelephotoCamera","case front=",
            "self.session.removeInput(old)","self.session.addInput(next)"
        ]),
    "native four ratios": all(x in camera for x in [
        'case fourThree="4:3"','case threeTwo="3:2"',
        'case sixteenNine="16:9"','case square="1:1"',
        "ratio.portraitAspect"
    ]),
    "RAW real Bayer only": "availableRawPhotoPixelFormatTypes" in camera
        and "isBayerRAWPixelFormat" in camera,
    "RAW paired companion": "rawPixelFormatType:raw,processedFormat:dictionary"
        in camera and "photo.isRawPhoto" in camera,
    "RAW explicit stabilization off":
        "settings.isAutoStillImageStabilizationEnabled=false" in camera,
    "RAW exact no-silent-fallback": "RAW 拍摄未返回 DNG" in camera and
        "不支持 Bayer RAW" in camera,
    "native delegate complete/error":
        "didFinishProcessingPhoto photo:AVCapturePhoto" in camera and
        "didFinishCaptureFor resolvedSettings:AVCaptureResolvedPhotoSettings"
        in camera and "if let firstError" in camera,
    "retain per-capture delegate": "captureDelegate=processor" in camera,
    "codec capability guard": "availablePhotoCodecTypes.contains(.jpeg)"
        in camera and "availablePhotoCodecTypes.contains(.hevc)" in camera,
    "no RAW crop": "if ratio == .fourThree {return data}" in camera and
        "NativeCameraAspectCrop.processed(" in camera and
        "rawDNG:raw" in camera,
    "background processed crop": "DispatchQueue.global(qos:.userInitiated).async"
        in camera,
    "JPEG/HEIC actual crop": "CGImageDestinationFinalize" in camera and
        "CIImage(data:data" in camera,
    "main app native camera": "NativeCameraScreen(" in main and
        "func loadCapturedPhoto(_ capture: NextLevelCapturedPhoto)" in main,
    "DNG separate durable write": "raw.write(to: output, options: .atomic)" in main,
    "unchanged optical ingest": "try loadPhoto(capture.processed,entry:.camera)" in main,
    "file RAW share": "activeSheet = .share(url)" in main and
        "onShareRaw" in ui,
    "preview from camera not snapshot": "UIImageJPEGRepresentation" not in camera,
}
failed=[key for key,value in required.items() if not value]
if failed: raise SystemExit("FAIL native AVFoundation camera: "+", ".join(failed))
for label in required: print("PASS "+label)
print("PASS Build122 native AVFoundation-only camera source audit; actual RAW DNG iPhoneOS16.5.1 hardware capture pending")
