#!/usr/bin/env python3
"""Static guards for the standalone NextLevel camera integration.

Passing this check does not replace compiling the real iPhoneOS app or taking
real photos on physical iOS hardware.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
project = (root / "project.yml").read_text()
model = (root / "SpektraFilmPort/ContentView.swift").read_text()
ui = (root / "SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
camera = (root / "SpektraFilmPort/NextLevelCamera.swift").read_text()

required = {
    "local NextLevel 0.18.0 package": "path: Vendor/NextLevel" in project and "- package: NextLevel" in project and (root / "Vendor/NextLevel/Package.swift").exists() and (root / "Vendor/NextLevel/LICENSE").exists(),
    "deployment target": 'iOS: "16.5"' in project,
    "camera permission": "NSCameraUsageDescription:" in project,
    "no microphone permission": "NSMicrophoneUsageDescription:" not in project,
    "photo-only mode": "engine.captureMode = .photo" in camera,
    "RAW explicit opt-in": "engine.photoConfiguration.isRawCaptureEnabled = false" in camera and "engine.photoConfiguration.isRawCaptureEnabled = captureExpectedRAW" in camera,
    "JPEG capture": "engine.photoConfiguration.codec = .jpeg" in camera,
    "camera authorization": "AVCaptureDevice.requestAccess(for: .video)" in camera,
    "camera source bytes": "NextLevelPhotoFileDataKey" in camera and "photo.fileDataRepresentation()" in camera,
    "real NextLevel preview": "NextLevel.shared.previewLayer" in camera,
    "camera toolbar button": 'toolButton("camera.fill"' in ui,
    "full-screen camera": ".fullScreenCover(isPresented: $cameraPresented)" in model,
    "shared photo importer": "try loadPhoto(capture.processed)" in model and "func loadCapturedPhoto(_ capture: NextLevelCapturedPhoto)" in model,
    "no preview snapshot": "UIImageJPEGRepresentation" not in camera,
    "RAW and processed pairing": "photo.isRawPhoto" in camera and "captureExpectedRAW && pendingRAW == nil" in camera,
    "RAW fail closed": "拒绝仅使用 JPEG" in camera and "未自动回退 JPEG" in camera,
    "durable DNG original": "raw.write(to: output, options: .atomic)" in model,
    "separate DNG share": "onShareRaw" in ui and "activeSheet = .share(url)" in model,
    "manual exposure/focus/WB/zoom/EV": all(k in camera for k in ("proSetManualExposure", "proSetWhiteBalance", "proSetManualFocus", "proSetZoom", "proSetExposureBias")),
    "hardware capability menus": "CaptureFormat.allCases" in camera and "CaptureLens.allCases" in camera,
    "DNG in Files": "UIFileSharingEnabled: true" in project,
}
nextlevel_source = (root / "Vendor/NextLevel/Sources/NextLevel.swift").read_text()
pro = (root / "Vendor/NextLevel/Sources/NextLevelProfessional.swift").read_text()
required.update({
    "native DNG settings": "rawPixelFormatType: rawType, processedFormat: formatDictionary" in nextlevel_source,
    "RAW capability guard": "availableRawPhotoPixelFormatTypes.first" in nextlevel_source,
    "manual AVFoundation exposure": "setExposureModeCustom(" in pro,
    "photo-only no mic": "engine.automaticallyConfiguresApplicationAudioSession = false" in camera,
})
for label, success in required.items():
    if not success:
        raise SystemExit("FAIL: " + label)
    print("PASS: " + label)
