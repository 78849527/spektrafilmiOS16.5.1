#!/usr/bin/env python3
"""Build92 #46 fail-closed STATIC GUI/API surface regression.
Validates current source UI integration & iOS16.5 deployment target.
This deliberately does NOT pretend that an Xcode build exercises gestures,
hardware camera, actual Photos permissions, Files sharing, or real device.
Real-device scripted checklist remains REQUIRED for certification.
"""
from pathlib import Path
from build_ci_version_floor import minimum_build, minimum_minor
import json
import hashlib
import sys

ROOT=Path(__file__).resolve().parents[2]
P=ROOT/"ios"
ui=(P/"SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
main=(P/"SpektraFilmPort/ContentView.swift").read_text()
camera=(P/"SpektraFilmPort/NextLevelCamera.swift").read_text()
spec=(P/"project.yml").read_text()
stages=(P/"SpektraFilmPort/Build92DeviceSourceStageDiagnostic.swift").read_text()

checks={
    "ios16_deployment_min":"iOS: \"16.5\"" in spec and
        'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec,
    "build92_version":minimum_build(spec, 92) and
        minimum_minor(spec, 59),
    "real_camera_capture":"output.capturePhoto(with:settings,delegate:processor)" in camera and
        "NextLevelCapturedPhoto" in camera,
    "raw_dng_not_jpeg_fallback":"photo.isRawPhoto" in camera and
        'RAW 拍摄未返回 DNG' in camera,
    "camera_auth":"AVCaptureDevice.requestAccess" in camera,
    "photo_picker":"PhotosPickerItem" in main and
        "func selectFromPhotos(" in main,
    "file_import":"func loadPhotoFile(" in main,
    "lut_import":"func loadLUTFile(" in main,
    "floating_editor_suspended_original":
        "StableImageHoldRecognizer(isHolding: $originalHeld)" in ui,
    "floating_edit_doubletap":ui.count(".onTapGesture(count: 2)")>=6,
    "film_paper_wheels":"compactFilmStock" in main and
        "compactPaperStock" in main,
    "one_bottom_editor":"private func openUnifiedEditor()" in ui and
        "private func closeUnifiedEditor()" in ui,
    "source_modes_confirm_first":
        "pendingSourceMode" in ui and
        'primaryButton: .default(Text("确认并切换"))' in ui,
    "reset_default_by_doubletap":"private func resetToggle(" in ui and
        "resetTo" in ui,
    "export_file_three_modes":"onExport(.original)" in ui and
        "onExport(.safe)" in ui and
        "onExport(.economy)" in ui,
    "photos_three_modes":"onSaveToPhotos(.original)" in ui and
        "onSaveToPhotos(.safe)" in ui and
        "onSaveToPhotos(.economy)" in ui,
    "save_to_photos":"PhotoLibrarySaver.saveJPEG(at: file)" in main,
    "save_file_sharing":'UIFileSharingEnabled: true' in spec and
        'LSSupportsOpeningDocumentsInPlace: true' in spec,
    "original_fullframe_fixture":
        "verification/generated-physical-v1.8.22" in spec and
        "tests/SourcePhysicalImageParity.swift" in spec,
    "ondevice_stage_diagnostic":
        "Build92DeviceSourceStageDiagnostic.evaluate()" in main and
        "SourcePhysicalImageParity.evaluate(fixtures:location)" in stages,
    "exception_not_silent":
        "附录【Build92 Python→Swift 原版整图对照｜失败／未认证】" in main,
}
failed=[k for k,v in checks.items() if not v]
if failed:
    raise SystemExit("FAIL static GUI regressions: "+", ".join(failed))
evidence={
    "scope":"STATIC Xcode source/GUI API integration only",
    "ios_requirement":"iOS16.5.1, build minimum 16.5",
    "source_sha256":{
        "editor":hashlib.sha256(ui.encode()).hexdigest(),
        "model":hashlib.sha256(main.encode()).hexdigest(),
        "camera":hashlib.sha256(camera.encode()).hexdigest(),
        "project":hashlib.sha256(spec.encode()).hexdigest(),
    },
    "static_checks":checks,
    "num_static_checks":len(checks),
    "all_static_checks_passed":True,
    "actual_ios16_5_1_device_test_completed":False,
    "required_manual_checks":[
        "physical iPhone iOS16.5.1 cold-start and 5x repeated navigation",
        "camera permission JPEG/HEIC/AppleRAW DNG with nonfallback",
        "Photos/file/LUT import and reject non-sRGB silently",
        "floating preview original hold and split comparison",
        "film/paper wheel and switching with image loaded",
        "all 3 menu tiers switch consistency and slider single-tap reset",
        "export original/safe/economy JPEG and file sharing",
        "Photos permission, real save, Files open/share, metadata",
        "12 stage original source optical NumPy/Numba measured app diagnostic",
        "large-image peak memory via iOS 16.5.1 Instruments",
    ],
}
out=Path(sys.argv[1]) if len(sys.argv)>1 else Path("/tmp/build92-ui-static-report.json")
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(evidence,indent=2,sort_keys=True)+"\n")
print(f"PASS BUILD92 GUI API STATIC AUDIT {len(checks)}/{len(checks)}; "
      "real-device 16.5.1 test PENDING (not certified).")
