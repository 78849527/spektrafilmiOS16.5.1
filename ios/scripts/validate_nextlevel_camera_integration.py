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
    "not falsely claiming RAW": "engine.photoConfiguration.isRawCaptureEnabled = false" in camera,
    "JPEG capture": "engine.photoConfiguration.codec = .jpeg" in camera,
    "camera authorization": "AVCaptureDevice.requestAccess(for: .video)" in camera,
    "NextLevel original JPEG": "NextLevelPhotoJPEGKey" in camera and "photo.fileDataRepresentation()" in camera,
    "real NextLevel preview": "NextLevel.shared.previewLayer" in camera,
    "camera toolbar button": 'toolButton("camera.fill"' in ui,
    "full-screen camera": ".fullScreenCover(isPresented: $cameraPresented)" in model,
    "shared photo importer": "try loadPhoto(data)" in model and "func loadCapturedPhoto(_ data: Data)" in model,
    "no preview snapshot": "UIImageJPEGRepresentation" not in camera,
}
for label, success in required.items():
    if not success:
        raise SystemExit("FAIL: " + label)
    print("PASS: " + label)
