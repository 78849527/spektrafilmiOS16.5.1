#!/usr/bin/env python3
"""Build98 UI state / async / diagnostics / temporary exports, preserving Build97 and all prior regressions.
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
    "build98_version":minimum_build(spec, 98) and
        minimum_minor(spec, 65),
    "real_camera_capture":"engine.capturePhoto()" in camera and
        "NextLevelCapturedPhoto" in camera,
    "raw_dng_not_jpeg_fallback":"pendingRAW" in camera and
        '拒绝静默拍成 JPEG' in camera,
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
    "raw_fast_only_explicit_mode":"if rawCompatible {" in main and "sourcePixelIOEnabled=false" in main and "rawFastModeActive=rawCompatible" in main,
    "raw_full_original_retained":"pendingImportedRAWURL=saved.url" in main,
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
    "libraw_never_precision_fallback": "if rawCompatible {" in main and
        "sourcePixelIOEnabled=false" in main and
        "originalPhotoData=data" in main,
    "libraw_bridge_header": "SFBuild94LibRaw" in libraw_header and
        "Build94LibRawBridge.h" in spec,
    "libraw_gcc_link": '-lraw' in spec and '-lz' in spec and '-lc++' in spec,
    "raw_storage_kept": "pendingImportedRAWURL=saved.url" in main and
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
    "libraw_16bit_original_bytes_retained": "pendingImportedRAWURL=saved.url" in main and
        "capturedRAWURL=rawURL" in main,
    "libraw_16bit_native_sanity": "PASS Build95 macOS 16-bit" in rgb16_test and
        "recovered == data" in rgb16_test and "RGBAf" in rgb16_test,
    "libraw_memory_limit": "45_000_000 / height" in raw16 and
        "estimate <= 1_400_000_000" in raw16,
    "libraw_ios16_5": 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec,
})
# Build96: code surface checks are NOT substitutes for macOS real-file
# TIFF verification, ARM64 iPhoneOS compilation, or iOS16.5.1 device tests.
tiff=(P/"SpektraFilmPort/Build96TIFF16Writer.swift").read_text()
tiff_test=(P/"tests/Build96TIFF16Validation.swift").read_text()
processor=(P/"SpektraFilmPort/PhotoProcessor.swift").read_text()
checks.update({
    "tiff16_actual_ci_file_write":
        "writeTIFFRepresentation(" in tiff and
        "format: .RGBA16" in tiff and
        'appendingPathExtension("tiff")' in tiff,
    "tiff16_real_ifd_bits":
        "readU16(entries,offset,little) == 258" in tiff and
        "readU16(bits,$0 * 2,little) == 16" in tiff and
        "CGImageSourceCreateWithURL" in tiff,
    "tiff16_no_fake_jpeg":
        "CGImageDestinationCreateWithURL" not in tiff and
        "writeTIFFRepresentation" in tiff,
    "tiff16_livesafe":
        "SafeExportResolution.currentProcessHeadroom()" in tiff and
        "bytes <= available / 100 * 70" in tiff and
        "width <= 45_000_000 / height" in tiff,
    "tiff16_not_original_float64_fallback":
        "tiff16 && sourcePixelIOEnabled" in main and
        "guard !sourcePixelIOEnabled else" in main,
    "tiff16_processed_existing_chain":
        "static func exportTIFF16(" in processor and
        "let image = try apply(" in processor and
        "Build96TIFF16Writer.write(image)" in processor,
    "tiff16_original_resolution_explicit":
        "confirmedPlan != nil" in processor and
        "SafeExportResolution.validateBeforeRender(plan)" in processor,
    "tiff16_ui_export_three":
        "onExportTIFF16(.original)" in ui and
        "onExportTIFF16(.safe)" in ui and
        "onExportTIFF16(.economy)" in ui,
    "tiff16_confirm_first":
        "proposal.tiff16" in main and
        "confirm" in main.lower() and
        "model.exportTIFF16(" in main and
        "activeSheet = .share(file)" in main,
    "tiff16_photos_stay_jpeg":
        "PhotoLibrarySaver.saveJPEG(at: file)" in main and
        "guard !saveToPhotos || !tiff16" in main,
    "libraw_real_process_headroom_gate":
        "#include <os/proc.h>" in libraw_bridge and
        "os_proc_available_memory()" in libraw_bridge and
        "estimatedBytes > (headroom / 100ull) * 70ull" in libraw_bridge,
    "tiff16_real_file_validation_test":
        "verifyFile(url,width:16,height:12)" in tiff_test and
        "image.bitsPerComponent == 16" in tiff_test,
    "tiff16_mac_no_device_claim":
        "DOES NOT use RAF" in tiff_test,
    "build98_app_version":
        minimum_build(spec, 98) and
        minimum_minor(spec, 65) and
        'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec,
})

# Build97 checks for production failure contracts rather than previous
# one-line token aliases. Static audit cannot certify a real iPhone.
filter_contract=(P/"SpektraFilmPort/Build97FilterContract.swift").read_text()
optics=(P/"SpektraFilmPort/SpatialOptics.swift").read_text()
scanner=(P/"SpektraFilmPort/ScannerFinishing.swift").read_text()
memory=(P/"SpektraFilmPort/SafeExportResolution.swift").read_text()
safety_test=(P/"tests/Build97P0SafetyValidation.swift").read_text()
raw_import=main.split("func loadPhotoFile(_ url: URL)",1)[1].split(
    "func openPreservedRAWWithApple()",1)[0]
source_commit=main.split("private func commitDecodedPhoto(",1)[1].split(
    "var hasPhoto: Bool",1)[0]
checks.update({
    "p0_filter_stage_error_contract":
        "static func required(" in filter_contract and
        "throw Failure.stage(stage)" in filter_contract,
    "p0_no_plain_lut_fallback":
        # No LUT or strength=0 intentionally returns the optical identity.
        # Only a failed requested CIColorCube may NOT return optical.
        "guard let output = cube.outputImage else { return optical }" not in processor and
        "禁止静默输出原片" in processor,
    "p0_grain_nonfallback":
        "密度颗粒：所选显影效果未生成图像" in processor,
    "p0_scanner_throw":
        "settings: ScannerFinishSettings) throws" in scanner and
        "printGlareKernel?.apply" in scanner and
        "unsharpKernel?.apply" in scanner and
        "outputImage ??" not in scanner,
    "p0_optics_throw":
        "settings: SpatialOpticsSettings) throws" in optics and
        "radiometricSumKernel?.apply" in optics and
        "return lhs" not in optics and
        "outputImage ??" not in optics,
    "p0_processing_propagation":
        "try SpatialOptics.apply(" in processor and
        processor.count("try ScannerFinishing.apply(")==2 and
        "blend.outputImage, stage:" in processor,
    "p0_raw_pending_separate":
        "pendingImportedRAWURL=saved.url" in raw_import and
        "capturedRAWURL=saved.url" not in raw_import and
        "source=nil" not in raw_import and
        "originalPhotoData=nil" not in raw_import and
        "originalPreview=nil" not in raw_import,
    "p0_raw_atomic_rollback":
        "let prior=snapshotEditing()" in source_commit and
        "restoreEditing(prior)" in source_commit and
        "pendingImportedRAWURL=nil" in source_commit and
        main.count("try commitDecodedPhoto(")>=4,
    "p0_raw_explicit_cancel":
        "model.dismissPendingRAWChoice()" in main and
        "func dismissPendingRAWChoice()" in main,
    "p0_photo_preview_before_commit":
        "let preview = try PhotoProcessor.preview(" in main and
        "data:data," in main,
    "p0_original_ram_preflight":
        "case .original: fraction = 70" in memory and
        "plan.estimatedPeakBytes <= plan.allocationAllowanceBytes" in memory and
        "validateForHeadroom(" in memory,
    "p0_original_ram_recheck":
        "try SafeExportResolution.validateBeforeRender(plan)" in processor and
        "try SafeExportResolution.validateBeforeRender(confirmedPlan)" in main,
    "p0_tests_failure_injection":
        "required(nil,stage:" in safety_test and
        "original JPEG now rejects low live RAM" in safety_test,
    "p0_not_real_iphone":
        "NOT an iPhone16.5.1" in safety_test,
})


# Build98: scope only the visible production toolbar; diagnostics must remain
# callable in the separately opened report sheet, not silently deleted.
temp=(P/"SpektraFilmPort/Build98ExportTemporaryFiles.swift").read_text()
temp_test=(P/"tests/Build98TemporaryExports.swift").read_text()
toolbar=ui.split("private var bottomToolbar: some View",1)[1].split(
    "private func toolButton(",1
)[0]
report=ui.split("private var statusReportSheet: some View",1)[1].split(
    "private func unifiedEditorDock(",1
)[0]
checks.update({
    "a05_photo_latest_wins":
        "photoTransferToken &+= 1" in main and
        "photoTransferTask?.cancel()" in main and
        "token == photoTransferToken" in main and
        "guard !Task.isCancelled" in main,
    "a05_lut_snapshot_rollback":
        "let previousLUT=lut" in main and
        "lut=previousLUT" in main and
        "processedPreview=previousPreview" in main and
        "try refresh()" in main,
    "a06_generation_belongs_to_task":
        "activeSimulationGeneration=generation" in main and
        "if activeSimulationGeneration == generation" in main,
    "a06_failed_metal_dir_clear_preview":
        'self.processedPreview=nil' in main and
        'self.status="原版空间 DIR 失败' in main and
        "originalMetalPreviewVersion &+= 1" in main,
    "a07_no_raw_false_precise_claim":
        "var originalPixelInputAvailable: Bool" in main and
        "model.originalPixelInputAvailable" in ui and
        "guard model.lut != nil, model.originalPixelInputAvailable" in ui,
    "a08_diag_moved_off_bottom_toolbar":
        "probeBuild81OriginalGeometry()" not in toolbar and
        "probePreservedRAWBackend()" not in toolbar and
        "probePreservedRAWDevelopment(" not in toolbar,
    "a08_diagnostics_still_accessible":
        "probeBuild81OriginalGeometry()" in report and
        "probePreservedRAWBackend()" in report and
        "probePreservedRAWDevelopment(" in report,
    "a09_fast_snapshot_and_recovery":
        "struct FastSettingsSnapshot" in ui and
        "savedFastSettings=FastSettingsSnapshot(model)" in ui and
        "savedFastSettings.restore(model)" in ui and
        "savedFastSettings=nil" in ui,
    "a09_new_document_resets_snapshot":
        ".onChange(of: model.photoDimensions)" in ui and
        "self.savedFastSettings=nil" in ui,
    "a14_temp_uuid_owner_and_directory_check":
        "UUID(uuidString:" in temp and
        "deletingLastPathComponent() == directory" in temp and
        "outputExtensions.contains(" in temp,
    "a14_temp_preserves_recent_source":
        "now.timeIntervalSince(modified) >= staleAfter" in temp and
        "static let staleAfter: TimeInterval = 24 * 60 * 60" in temp,
    "a14_share_waits_for_dismissal":
        ".sheet(item: $activeSheet, onDismiss:" in main and
        "temporarySharedExport=nil" in main,
    "a14_photos_waits_until_save":
        "defer {" in main and
        "try await PhotoLibrarySaver.saveJPEG(at: file)" in main and
        "removeAfterUse(file)" in main,
    "a14_stale_crash_sweep":
        "Build98ExportTemporaryFiles.removeStale()" in main and
        "Build98ExportTemporaryFiles.removeAfterUse(output)" in main,
    "a14_real_file_test":
        "Build98ExportTemporaryFiles.removeStale(" in temp_test and
        "source RAW" not in temp_test and
        "external RAW safety" in temp_test,
    "build98_ios1651_deployment":
        minimum_build(spec, 98) and
        minimum_minor(spec, 65) and
        'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec,
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
    "ios16_5_tiff16_real_device_verified":False,
    "x_t5_40mp_real_memory_peak_measured":False,
    "tiff16_exact_source_icc_verified":False,
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
print(f"PASS BUILD98 STATE + DIAGNOSTICS + TEMP STATIC AUDIT {len(checks)}/{len(checks)}; "
      "real-device 16.5.1 test PENDING (not certified).")
