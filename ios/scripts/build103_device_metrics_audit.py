#!/usr/bin/env python3
"""Build103 real 28 core-stage metrics, controlled seeded Numba statistics, touched-memory evidence and all earlier source regressions.
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
    "build103_version":minimum_build(spec, 112) and
        minimum_minor(spec, 78),
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
        "StableImageHoldRecognizer(" in ui and
        "isHolding:$originalHeld,onDoubleTap:togglePhotoZoom" in ui and
        "doubleTap.numberOfTapsRequired=2" in ui,
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
    "libraw_native_pre_unpack_guard": "estimatedBytes > (headroom / 100ull) * 70ull" in libraw_bridge and
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
        "return estimate" in raw16 and
        "1_400_000_000" not in raw16,
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
        "bytes <= headroom / 100 * 70" in tiff and
        "width <= 45_000_000 / height" in tiff,
    "tiff16_not_original_float64_fallback":
        "if tiff16 && sourcePixelIOEnabled &&" in main and
        "guard sourcePhysicalDirectEnabled else" in main and
        "try OriginalSourcePixelIO.exportPhysicalOriginalFile(" in main and
        "bytes,parameters:physical,format:.tiff," in main and
        "bitDepth:16,outputSpace:\"sRGB\"" in main and
        "if tiff16 && !sourcePixelIOEnabled" in main,
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
    "build103_app_version":
        minimum_build(spec, 112) and
        minimum_minor(spec, 78) and
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
        "case .original: fraction = originalBudgetPercent" in memory and
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
        ".onChange(of: model.photoSessionRevision)" in ui and
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
    "build103_ios1651_deployment":
        minimum_build(spec, 112) and
        minimum_minor(spec, 78) and
        'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec,
})


# Build99: validate latest-request and correct source/gesture semantics.
rules=(P/"SpektraFilmPort/Build99InteractionRules.swift").read_text()
rule_test=(P/"tests/Build99InteractionRulesValidation.swift").read_text()
checks.update({
    "b99_latest_generation_gate":
        "Build99InteractionRules.acceptsPreview(" in main and
        "generation:generation, current:renderGeneration" in main,
    "b99_wheel_pending_invalidates_old_preview":
        "simulationAwaitingCurrentSettings=true" in main and
        "processedPreview=nil" in main and
        "pendingRender?.cancel()" in main,
    "b99_failed_material_remains_unexportable":
        "当前胶片/相纸模拟失败，导出已锁定" in main and
        "simulationAwaitingCurrentSettings=false" in main,
    "b99_all_export_paths_block_pending":
        main.count("Build99InteractionRules.canExport(")>=3,
    "b99_spectral_transaction_rollback":
        "let oldLUT=lut" in main and
        "let oldDIR=spatialDIRStage" in main and
        "lut=oldLUT" in main and
        "densityGrainStage=oldDensity" in main,
    "b99_cancelled_busy_released":
        "if activeSimulationGeneration != nil {" in main and
        "activeSimulationGeneration=nil" in main,
    "b99_fast_ci_failure_blank":
        "processedPreview = try PhotoProcessor.preview(" in main and
        "processedPreview=nil" in main,
    "b99_same_size_new_photo_resets":
        "@Published private(set) var photoSessionRevision:" in main and
        "photoSessionRevision &+= 1" in main and
        ".onChange(of: model.photoSessionRevision)" in ui,
    "b99_new_session_no_old_zoom":
        "comparisonEnabled=false" in ui and
        "originalHeld=false" in ui and
        "compareFraction=0.5" in ui and
        "photoScale=1" in ui,
    "b99_source_preview_during_pending":
        "model.processedPreview ?? model.originalPreview" in ui and
        "当前效果正在更新 · 按住看原图" in ui,
    "b99_split_drag_and_doubletap":
        "DragGesture(minimumDistance: 8)" in ui and
        "TapGesture(count: 2).onEnded" in ui and
        "togglePhotoZoom()" in ui,
    "b99_export_buttons_disabled_if_dirty":
        ui.count("model.simulationAwaitingCurrentSettings)")>=2,
    "b99_rules_live_in_production":
        "Build99InteractionRules.nextPhotoScale(" in ui and
        "Build99InteractionRules.compareDivider(" in ui and
        "Build99InteractionRules.canExport(" in main,
    "b99_executable_regression":
        "nextPhotoScale(1) == 2" in rule_test and
        "pendingSelectedMaterial:true" in rule_test and
        "generation:9,current:10" in rule_test,
    "b99_keeps_original_distinct":
        "originalPixelInputAvailable" in main and
        "Build99InteractionRules" in rules,
})


# Build100 adds ONLY honest production navigation, explicit not-certified
# runtime reporting, and 12 unperformed real-device/source gates.
readiness=(P/"SpektraFilmPort/Build100Readiness.swift").read_text()
readiness_test=(P/"tests/Build100ReadinessValidation.swift").read_text()
checks.update({
    "b100_main_navigation_production_only":
        "editorTab(.film)" in ui and
        "editorTab(.adjustment)" in ui and
        "editorTab(.workflow)" in ui and
        "editorTab(.laboratory)" not in ui,
    "b100_advanced_lab_preserved":
        'Button("验证概况")' in ui and
        "selectEditorPage(.laboratory)" in ui and
        "case .laboratory: return AnyView(advancedControls)" in ui,
    "b100_no_source_algorithm_deleted":
        "private var activeSettings: AnyView" in ui and
        "private var advancedControls: AnyView" in ui and
        'Text("高级 · 验证与诊断")' in ui and
        ui.count("sourcePhysicalGrainSettings")>=2 and
        ui.count("sourceScannerGlareSettings")>=2,
    "b100_scope_in_status_sheet":
        "source_float64_experimental" in readiness and
        "原版 Float64 光学（受控 PASS，整图未认证）" in ui and
        "源码阶段参考与自动测试 ≠ 真机整图等价认证" in ui,
    "b100_device_evidence_accessible":
        "onShareBuild100Readiness: () -> Void" in ui and
        "onShareBuild100Readiness()" in ui and
        "onShareBuild100Readiness: {" in main and
        "exportBuild100Readiness()" in main,
    "b100_device_os_factual":
        "UIDevice.current.model" in main and
        "UIDevice.current.systemVersion" in main and
        'forInfoDictionaryKey:"CFBundleVersion"' in main,
    "b100_mode_not_disguised":
        '"source_float64_experimental"' in readiness and
        '"source_8bit_direct_limited"' in readiness and
        '"mobile_compatible"' in readiness,
    "b100_all_manual_checks_unperformed":
        'result:.notRun, evidence:""' in readiness and
        'case notRun = "not_run"' in readiness and
        "manualChecklist()" in readiness,
    "b100_12_manual_gates":
        readiness.count('("')>=12 and
        "source_original_parity" in readiness and
        "rng_distribution" in readiness and
        "icc_metadata" in readiness,
    "b100_no_fake_certificate":
        'releaseCertification:"not_certified"' in readiness and
        "runtimeDiagnosticReportExists:Bool" not in readiness and
        "runtimeDiagnosticReportExists: Bool" in readiness,
    "b100_no_user_raw_or_image_in_json":
        "sourceLoaded: Bool" in readiness and
        "processedPreviewAvailable: Bool" in readiness and
        "originalPhotoData" not in readiness and
        "capturedRAWURL" not in readiness,
    "b100_write_docs_not_temp":
        'SpektraFilm Verification' in readiness and
        "FileManager.default.createDirectory(" in readiness and
        'try encode(report).write(to:url,options:.atomic)' in readiness,
    "b100_physical_checks_not_claimed":
        "真机、Python 整图和随机统计测试均明确写为 not_run" in ui and
        "未测试项目保持 not_run" in main,
    "b100_runtime_json_roundtrip":
        'Build100Readiness.write(draft,documents:root)' in readiness_test and
        "Data(contentsOf:url)" in readiness_test and
        "manualChecks.allSatisfy" in readiness_test,
    "b100_old_device_stage_export_preserved":
        "onCaptureBuild77Evidence()" in ui and
        "Build77OneShotEvidence.captureAll(" in main,
    "b100_version_and_minimum_ios":
        minimum_build(spec, 112) and
        minimum_minor(spec, 78) and
        'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec,
})


# Build101: no Python fixture can masquerade as device measurements. A
# button must run the *real production* Swift comparator and save its result.
parity=(P/"SpektraFilmPort/Build101DeviceParityEvidence.swift").read_text()
parity_test=(P/"tests/Build101MeasuredParityEvidenceValidation.swift").read_text()
checks.update({
    "b101_real_source_reference_evaluator":
        "Build92DeviceSourceStageDiagnostic.evaluate()" in main and
        "Build101DeviceParityEvidence.capture(" in main and
        "try Build92DeviceSourceStageDiagnostic.evaluate()" in main,
    "b101_real_device_button":
        "onRunBuild101DeviceParity: () -> Void" in ui and
        "onRunBuild101DeviceParity()" in ui and
        "onRunBuild101DeviceParity: {" in main,
    "b101_explicit_not_full_certified":
        "fullPythonOriginalCertified:false" in parity and
        '"controlled_stage_pass_on_physical_ios1651"' in parity and
        "fullPythonOriginalCertified" in parity_test,
    "b101_uses_physical_device_and_os_gate":
        "physicalDevice && osVersion==\"16.5.1\"" in parity and
        "#if targetEnvironment(simulator)" in main and
        "let hardware=false" in main,
    "b101_original_manifest_sha256":
        "SHA256.hash(data:data)" in parity and
        "referenceManifestSHA256" in parity and
        "generated-physical-v1.8.22" in parity,
    "b101_commit_identity_checked_before_pass":
        "binarySourceCommit.unicodeScalars.allSatisfy" in parity and
        "isTarget && commitValid" in parity and
        "binarySourceCommit:gitCommit" in main and
        '"SFSourceCommit"' in main and
        'SFSourceCommit: "$(SF_SOURCE_COMMIT)"' in spec,
    "b101_missing_reference_fail_closed":
        "Build92 Python 原版源参考清单缺失" in parity and
        "guard let referenceManifest else" in parity and
        'status="controlled_stage_failed_or_reference_missing"' in parity,
    "b101_blank_evaluator_fail_closed":
        "trimmingCharacters(in:.whitespacesAndNewlines)" in parity and
        "原版阶段数值诊断没有返回有效报告" in parity,
    "b101_error_persisted_without_fake_pass":
        "firstFailure:failure" in parity and
        "try Build101DeviceParityEvidence.write(" in main and
        "proof.controlledParityPassOnTargetDevice" in main,
    "b101_machine_report_in_documents":
        'SpektraFilm Verification' in parity and
        "try encode(report).write(to:file,options:.atomic)" in parity and
        "FileManager.default.urls(" in main,
    "b101_no_user_photo_in_report":
        "originalPhotoData" not in parity and
        "processedPreview" not in parity and
        "sourceLoaded" not in parity,
    "b101_share_waits_for_real_sheet_dismiss":
        "onDiagnosticSheetDismissed: () -> Void" in ui and
        "onDismiss: onDiagnosticSheetDismissed" in ui and
        "diagnosticDismissPending=false" in main and
        "enqueueDiagnosticShare(file)" in main,
    "b101_no_hardcoded_share_delay":
        "nanoseconds:350_000_000" not in main and
        "diagnosticPendingShare: URL?" in main,
    "b101_real_failure_injection_test":
        "referenceManifest:nil" in parity_test and
        'binarySourceCommit:"missing"' in parity_test and
        "Data(contentsOf:output)" in parity_test,
    "b101_old_stage_evidence_kept":
        "Build77OneShotEvidence.captureAll(" in main and
        "SourcePhysicalImageParity.evaluate(fixtures:location)" in stages,
    "b101_build100_manual_gates_not_falsified":
        'result:.notRun, evidence:""' in
        (P/"SpektraFilmPort/Build100Readiness.swift").read_text(),
})


# Build102: avoid falsely rejecting the real device's source-equivalent
# float64 same-space 3x3 colour.RGB_to_RGB before nonlinear CCTF.
frame=(P/"tests/SourcePhysicalImageParity.swift").read_text()
prod=(P/"SpektraFilmPort/OriginalSourcePhysicalImage.swift").read_text()
scanner=(P/"SpektraFilmPort/OriginalScannerMath.swift").read_text()
cctf_test=(P/"tests/Build102ScannerCCTFValidation.swift").read_text()
generator=(P/"scripts/generate_scanner_reference.py").read_text()
glare=frame.split("if !checkedProductionGlare &&",1)[1].split(
    "// v1.8.48:",1
)[0]
checks.update({
    "b102_stage_expected_full_matrix_cctf":
        "let expectedEncoded=OriginalScannerMath.sourceCCTFEncoding(" in glare and
        "expectedLinear" in glare,
    "b102_expected_per_channel_uses_3channel_encoded":
        "glared.rgb[k+ch]-expectedEncoded[ch]" in glare and
        "OriginalScannerMath.encodeSRGB(" not in glare,
    "b102_original_colour_matrix_preserved":
        "sourceLinearIdentityRGBMatrix" in scanner and
        "colour.RGB_to_RGB(" in generator and
        "sourceCCTFEncoding(" in prod,
    "b102_no_tolerance_relaxation":
        "deltaXYZ<1e-11,deltaLinear<1e-11" in glare and
        "deltaEncoded<1e-11" in glare,
    "b102_first_failure_has_real_pixel_and_delta":
        r"p=\(pixel) c=\(ch) XYZ=\(deltaXYZ)" in glare and
        r"linear=\(deltaLinear) encoded=\(deltaEncoded)" in glare and
        r"p=\\(pixel)" not in glare,
    "b102_success_error_numeric_visible":
        r"\(maxXYZ)" in frame and r"\(maxLinear)" in frame and
        r"\\(maxXYZ)" not in frame,
    "b102_original_scanner_field_still_tested":
        "OriginalSourceScannerGlare.computeAmount(" in glare and
        "scannerGlareXYZ" in glare and "scannerGlareLinearRGB" in glare,
    "b102_real_color_matrix_native_test":
        "OriginalScannerMath.sourceCCTFEncoding(rgb)" in cctf_test and
        "GeneratedScannerReference.sourceLinearIdentityRGBMatrix" in cctf_test and
        "maxOldScalarDifference>1e-11" in cctf_test,
    "b102_101_actual_device_parity_preserved":
        "Build101DeviceParityEvidence.capture(" in main and
        "SourcePhysicalImageParity.evaluate(fixtures:location)" in stages,
    "b102_ios1651_unchanged":
        minimum_build(spec, 112) and
        minimum_minor(spec, 78) and
        'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec,
})


# Build103 real on-device metrics are emitted only from the existing
# Original Python SHA-verified production source-to-Swift comparisons.
parity=(P/"tests/SourcePhysicalImageParity.swift").read_text()
evidence=(P/"SpektraFilmPort/Build103VerificationEvidence.swift").read_text()
test=(P/"tests/Build103DeviceMetricsValidation.swift").read_text()
doc=(P.parent/"docs/BUILD103-REAL-DEVICE-METRICS-RNG-MEMORY.md").read_text()
checks.update({
    "b103_production_original_numeric_stage_callback":
        "onBuild103StageMetric:" in parity and
        "onBuild103StageMetric?(Build103VerificationEvidence.StageMetric(" in parity and
        "let stageMetrics = try compare(" in parity and
        "expectedPythonStageSHA256:expectedSHA" in parity,
    "b103_28_true_stage_only_metrics":
        "let stageNames = [" in evidence and
        "records.count==28" in evidence and
        "groups.count==4" in evidence and
        "taps.count==7" in evidence,
    "b103_math_fields_in_json":
        all(x in evidence for x in [
            "let mae: Double","let rmse: Double",
            "let maximumAbsoluteError: Double",
            "let worstPixel: Int","let worstChannel: Int",
            "let maximumTolerance: Double","let maeTolerance: Double"
        ]),
    "b103_original_tolerances_unchanged":
        "maxTolerance:outputTolerance," in parity and
        "maeTolerance:meanTolerance," in parity and
        'let outputTolerance:Double=stage=="printed" ? 0.002 : 0.002' in parity and
        'let meanTolerance:Double=stage=="printed" ? 0.0005 : 0.0003' in parity,
    "b103_over_tolerance_rejected":
        "$0.overMaximumTolerance==0" in evidence and
        "$0.mae<=$0.maeTolerance" in evidence and
        "$0.maximumAbsoluteError<=$0.maximumTolerance" in evidence,
    "b103_python_tape_sha_validated":
        "sha:checksum" in parity and
        "SHA256.hash(data:data)" in parity and
        "expectedPythonStageSHA256:expectedSHA" in parity,
    "b103_device_metric_button_real":
        "onRunBuild103Metrics: () -> Void" in ui and
        "onRunBuild103Metrics()" in ui and
        "onRunBuild103Metrics: {" in main,
    "b103_device_calls_legacy_parity_no_fake":
        "SourcePhysicalImageParity.evaluate(" in main and
        "onBuild103StageMetric:observe" in main and
        "Build103VerificationEvidence.capture(" in main,
    "b103_seeded_numba_real_not_multiworker":
        "OriginalSourceNumbaSingleThreadNormal(seed:8888)" in evidence and
        "unseededMultiworkerCertified:false" in evidence and
        "count:Int=8192" in evidence,
    "b103_8mib_physical_touch":
        "Data(count:size)" in evidence and
        "raw[i]=v" in evidence and
        "size=8*1024*1024" in evidence and
        "actuallyTouchedMemory:true" in evidence,
    "b103_no_false_13mp_rss_claim":
        "full13MPOperationMeasured:false" in evidence and
        "fullPythonOriginalCertified:false" in evidence and
        "not_RSS" in evidence,
    "b103_identity_and_os_scope":
        "physicalDevice && osVersion==\"16.5.1\"" in evidence and
        "validHex(commit,40)" in evidence and
        "controlledCoreStagesPassedOnTarget:onTarget" in evidence,
    "b103_first_failure_partial_metric_preserved":
        "metrics.append(metric)" in evidence and
        "catch {stageError=error.localizedDescription}" in evidence and
        "coreStageMetrics:metrics" in evidence,
    "b103_json_documents_and_share":
        'Build103-device-metrics-' in evidence and
        "try encoder.encode(report).write(to:file,options:.atomic)" in evidence and
        "Build103VerificationEvidence.write(" in main and
        "enqueueDiagnosticShare(file)" in main,
    "b103_real_host_negative_runtime":
        "Build103VerificationEvidence.sampleSeededNumba()" in test and
        "sampleBoundedMemory(" in test and
        "Data(contentsOf:file)" in test and
        "Array(good.dropLast())" in test and
        "synthetic first stage error" in test,
    "b103_scope_and_version":
        minimum_build(spec, 112) and
        minimum_minor(spec, 78) and
        'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in spec and
        "full13MPOperationMeasured=false" in doc,
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
print(f"PASS BUILD103 DEVICE STAGE METRICS CONTROLLED RNG AND MEMORY AUDIT {len(checks)}/{len(checks)}; "
      "real-device 16.5.1 test PENDING (not certified).")
