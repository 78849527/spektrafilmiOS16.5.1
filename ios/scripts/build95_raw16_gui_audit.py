#!/usr/bin/env python3
"""Build95 LibRaw RGB16 + Build94/93/92 regression fail-closed STATIC GUI/API surface regression.
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
    "build95_version":minimum_build(spec, 95) and
        minimum_minor(spec, 62),
    "real_camera_capture":"SFNativeCaptureSafety.startPhotoOutput(" in camera and
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
# Build93: actual RAW path must exist separately from source Float64.
raw=(P/"SpektraFilmPort/Build93AppleRAWImport.swift").read_text()
storage=(P/"SpektraFilmPort/Build79RAWStorage.swift").read_text()
signature=(P/"SpektraFilmPort/Build79RAWSignature.swift").read_text()
# A forbidden API named in a warning COMMENT is not executable code.
raw_code="\n".join(line for line in raw.splitlines()
                   if not line.lstrip().startswith("//"))
checks.update({
    "xt5_raf_signature":"FUJIFILMCCD-RAW " in signature and "case dng,raf,cr3,nef,cr2,arw" in signature,
    "raw_preserved_with_sha":"SHA256()" in storage and "copied.hash==source.hash" in storage,
    "raw_picker_all_files":"forOpeningContentTypes: [.item]" in main,
    "raw_requires_explicit_mode_choice":'rawNeedsChoice=true' in main and 'isPresented: $model.rawNeedsChoice' in main,
    "raw_apple_compat_preview":"Build93AppleRAWImport.open(url)" in main and "PhotoProcessor.preview(" in main,
    "raw_decoder_not_embedded_jpeg":"CIRAWFilter(imageURL: url)" in raw_code and "CIImage(contentsOf:" not in raw_code and "CIImage(data:" not in raw_code,
    "raw_actual_float32_pixel_proof":"format: .RGBAf" in raw and "values.allSatisfy" in raw,
    "raw_fast_only_explicit_mode":"sourcePixelIOEnabled=false" in main and "rawFastModeActive=true" in main and "originalPhotoData=nil" in main,
    "raw_full_original_retained":"capturedRAWURL=saved.url" in main,
    "raw_unsupported_is_error":"原始文件已完整保存" in raw and "不回退 JPEG" in raw,
    "minimum_os_unchanged":'iOS: "16.5"' in spec,
})
libraw_swift=(P/"SpektraFilmPort/Build94LibRawIngress.swift").read_text()
libraw_header=(P/"SpektraFilmPort/Build94LibRawBridge.h").read_text()
libraw_bridge=(P/"SpektraFilmPort/Build94LibRawBridge.mm").read_text()
libraw_build=(P/"scripts/build94_compile_libraw_ios.sh").read_text()
checks.update({
    "libraw_pinned_tag": "0b56545a4f828743f28a4345cdfdd4c49f9f9a2a" in libraw_build,
    "libraw_actual_arm64_compile": "lib/libraw.a" in libraw_build and
        "miphoneos-version-min=16.5" in libraw_build,
    "libraw_fuji_compressed_present": "fuji_compressed.o" in libraw_build and
        "xtrans_demosaic.o" in libraw_build,
    "libraw_native_cpp_bridge": "libraw_open_file" in libraw_bridge and
        "libraw_unpack(raw)" in libraw_bridge and
        "libraw_dcraw_process(raw)" in libraw_bridge and
        "libraw_dcraw_make_mem_image" in libraw_bridge,
    "libraw_no_jpeg_thumbnail": "libraw_dcraw_make_mem_thumb" not in libraw_bridge and
        "libraw_unpack_thumb" not in libraw_bridge,
    "libraw_explicit_8_or_16": "libraw_set_output_bps(raw, (int)bits)" in libraw_bridge and
        "image->bits != (unsigned)bits" in libraw_bridge and
        "decodeURL:url bitsPerComponent:8 error:error" in libraw_bridge,
    "libraw_camera_wb": "raw->params.use_camera_wb = 1" in libraw_bridge,
    "libraw_real_rgba_transport": "CGImage(" in libraw_swift and
        "Build79RAWSignature.probeFile" in libraw_swift,
    "libraw_user_opt_in": "openPreservedRAWWithLibRaw()" in main and
        "model.openPreservedRAWWithLibRaw()" in main,
    "libraw_never_precision_fallback": "sourcePixelIOEnabled=false" in main and
        "originalPhotoData=nil" in main,
    "libraw_bridge_header": "SFBuild94LibRaw" in libraw_header and
        "Build94LibRawBridge.h" in spec,
    "libraw_gcc_link": '-lraw' in spec and '-lz' in spec and '-lc++' in spec,
    "raw_storage_kept": "capturedRAWURL=saved.url" in main and
        "libraw_close(raw)" in libraw_bridge,
})
# High-depth tests MUST be separate from source exact-float/rawpy evidence.
raw16=(P/"SpektraFilmPort/Build95LibRaw16Ingress.swift").read_text()
rgb16_test=(P/"tests/Build95RGB16Transport.swift").read_text()
checks.update({
    "libraw_16bit_objc_api": "bitsPerComponent:(NSInteger)bits" in libraw_header and
        "decode(_:bitsPerComponent:)" in libraw_header,
    "libraw_16bit_native_requested": "libraw_set_output_bps(raw, (int)bits)" in libraw_bridge and
        "image->bits != (unsigned)bits" in libraw_bridge,
    "libraw_precise_bytes": "required != (uint64_t)image->data_size" in libraw_bridge and
        "(uint64_t)(bits / 8)" in libraw_bridge,
    "libraw_native_pre_unpack_guard": "estimatedBytes > 1400000000ull" in libraw_bridge and
        "libraw_unpack(raw)" in libraw_bridge,
    "libraw_8bit_kept": "decodeURL:url bitsPerComponent:8 error:error" in libraw_bridge and
        "Build94LibRawIngress.open(url)" in main,
    "libraw_16bit_swift_in_use": "SFBuild94LibRaw.decode(url, bitsPerComponent: 16)" in raw16 and
        "bitsPerComponent: 16" in raw16,
    "libraw_rgb48": "bitsPerPixel: 48" in raw16 and "bytesPerRow: w * 6" in raw16 and
        "CGBitmapInfo.byteOrder16Little" in raw16,
    "libraw_no_8bit_fallback": "actual == 16" in raw16 and
        "拒绝冒用 8-bit" in raw16,
    "libraw_user_opt_in_high_depth": "model.openPreservedRAW16Bit()" in main and
        "func openPreservedRAW16Bit()" in main,
    "libraw_16bit_original_bytes_retained": "capturedRAWURL=saved.url" in main and
        "originalPhotoData = nil" in main,
    "libraw_16bit_native_sanity": "PASS Build95 macOS 16-bit" in rgb16_test and
        "recovered == data" in rgb16_test and "RGBAf" in rgb16_test,
    "libraw_memory_limit": "45_000_000 / height" in raw16 and
        "estimate <= 1_400_000_000" in raw16,
    "libraw_ios16_5": 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec,
})
failed=[k for k,v in checks.items() if not v]
if failed:
    raise SystemExit("FAIL static GUI regressions: "+", ".join(failed))
evidence={
    "scope":"STATIC Build93 RAW selection+Apple RAW path and Build92 GUI invariants only; NOT device proof",
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
    "xt5_uncompressed_raf_iphone_verified":False,
    "xt5_lossless_raf_libraw_integrated":True,
    "xt5_lossless_raf_physical_iphone_verified":False,
    "xt5_16bit_rgb48_physical_iphone_verified":False,
    "xt5_lossy_raf_libraw_integrated":True,
    "xt5_lossy_raf_physical_iphone_verified":False,
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
print(f"PASS BUILD95 RGB16 LIBRAW + RAW + GUI STATIC AUDIT {len(checks)}/{len(checks)}; "
      "real-device 16.5.1 test PENDING (not certified).")
