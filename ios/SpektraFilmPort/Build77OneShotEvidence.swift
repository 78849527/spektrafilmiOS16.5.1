#if os(iOS)
import Foundation
import UIKit
import CryptoKit

/// ONE device operation for all Build77 source stage tape branches.
/// Three actual production runs receive the exact same 6×4×3 source
/// original NumPy reference input. No synthesized Python results.
/// The Files app exposes the resulting one-shot folder under
/// "On My iPhone / SpektraFilm Port".
///
/// This is EVIDENCE CAPTURE, not proof of numeric equivalence.
/// Swift source-controlled settings below are explicit and may differ
/// from Python's original defaults. A Python-vs-device report MUST
/// compare params and 5/7 taps before accepting any branch.
enum Build77OneShotEvidence {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let s)=self { return s }
            return nil
        }
    }

    private struct Case {
        let name:String
        let film:String
        let paper:String
        let spatialPrint:Bool
    }

    static func captureAll(deviceModel:String,systemVersion:String) throws -> URL {
        guard Build77ReferenceInput.bits.count==
                Build77ReferenceInput.width*Build77ReferenceInput.height*3
        else {
            throw Failure.invalid("Build77 原版测试输入数据损坏")
        }
        var sourceBytes=Data()
        for bit in Build77ReferenceInput.bits {
            var little=bit.littleEndian
            withUnsafeBytes(of:&little) {
                sourceBytes.append(contentsOf:$0)
            }
        }
        let actualInputSHA=SHA256.hash(data:sourceBytes)
            .map { String(format:"%02x",$0) }.joined()
        guard actualInputSHA ==
                Build77ReferenceInput.originalSourceInputSHA256 else {
            throw Failure.invalid(
                "Build77 真实 iPhone 输入 Float64 SHA 与原版 NumPy 不一致，禁止采集"
            )
        }
        let frame=OriginalSourcePixelIO.Frame(
            width:Build77ReferenceInput.width,
            height:Build77ReferenceInput.height,
            rgb:Build77ReferenceInput.values
        )
        guard let documents=FileManager.default.urls(
            for:.documentDirectory,in:.userDomainMask
        ).first else {
            throw Failure.invalid("Build77 无法找到文件应用诊断导出目录")
        }
        let folder=documents.appendingPathComponent(
            "Build77-ONE-SHOT-" +
            ISO8601DateFormatter().string(from:Date())
                .replacingOccurrences(of:":",with:"-"),
            isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true,attributes:nil
        )
        var finished=false
        defer { if !finished { try? FileManager.default.removeItem(at:folder) } }

        let scenarios:[Case]=[
            .init(name:"negative-print",film:"kodak_portra_400",
                  paper:"kodak_portra_endura",spatialPrint:false),
            .init(name:"direct-scan",film:"fujifilm_provia_100f",
                  paper:"kodak_portra_endura",spatialPrint:false),
            .init(name:"negative-print-diffusion",film:"kodak_portra_400",
                  paper:"kodak_portra_endura",spatialPrint:true)
        ]
        var results=[[String:Any]]()
        for test in scenarios {
            var dir=SpatialDIRSettings(enabled:true)
            dir.diffusionRadiusScale=1.0
            dir.tailWeight=0.06
            dir.referencePixelSizeUM=35000.0/Double(max(
                Build77ReferenceInput.width,Build77ReferenceInput.height
            ))
            dir.sourceConvolutionEnabled=true
            var printSettings=OriginalPrintOptics.Settings(enabled:true)
            // Strict deterministic audit scope; the Python source
            // default pipeline's autoexposure/RNG/gamut differences MUST
            // be identified, not hidden by presumed equal defaults.
            printSettings.normalizePrintExposure=false
            printSettings.printExposureCompensation=false
            let morph=OriginalPrintMorph.Settings()
            var physical=OriginalSourcePhysicalImage.Parameters(
                filmID:test.film,paperID:test.paper,
                cameraEV:0.0,paperEV:0.0,
                dir:dir,print:printSettings,morph:morph
            )
            if test.spatialPrint {
                physical.printDiffusion.active=true
                physical.printDiffusion.strength=0.5
                physical.printDiffusion.spatialScale=1.0
            }
            let destination=folder.appendingPathComponent(
                test.name,isDirectory:true
            )
            try FileManager.default.createDirectory(
                at:destination,
                withIntermediateDirectories:true,attributes:nil
            )
            let started=CFAbsoluteTimeGetCurrent()
            _=try Build77StageTapeRecorder.capturePhysical(
                frame,parameters:physical,into:destination
            )
            results.append([
                "name":test.name,
                "film":test.film,
                "paper":test.paper,
                "elapsed_s":CFAbsoluteTimeGetCurrent()-started,
                "spatial_print":test.spatialPrint,
                "dir_spatial_convolution":true,
                "source_grain_active":false,
                "scanner_glare_active":false,
                "camera_metering_active":false,
                "print_normalize_exposure":false,
                "print_reference_compensation":false,
                "print_diffusion_strength":test.spatialPrint ? 0.5 : 0.0,
                "stage_tapes":test.name+"/manifest.json",
                "source_mapping":
                    test.name+"/candidate-source-tap-mapping.json"
            ])
        }
        #if targetEnvironment(simulator)
        let isSimulator=true
        #else
        let isSimulator=false
        #endif
        let manifest:[String:Any]=[
            "status":"REAL_IPHONE_STAGED_EVIDENCE_NOT_PYTHON_CERTIFIED",
            "source_sha":"3bb2c2d2801ff68b92019cf1dbcbb133d60832bc",
            "input_source_sha256":Build77ReferenceInput.originalSourceInputSHA256,
            "input_provenance":"NumPy PCG64 default_rng(771), .15 + .55 * rng.random((6,4,3))",
            "input_shape":[6,4,3],
            "input_type":"Float64_IEEE754_exact_bits",
            "app_source_commit":Bundle.main.object(forInfoDictionaryKey:"Build77SourceCommit") as? String ?? "unknown",
            "app_build":Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "app_version":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "device_model":deviceModel,
            "actual_hardware_device":!isSimulator,
            "system_version":systemVersion,
            "cases":results,
            "certification_note":
                "Captured from iPhone original Swift production, not Python "
                + "source, and not a numeric equivalence claim. Exact Python "
                + "RuntimePhotoParams/default gamut/stochastic/autoexposure "
                + "settings must be matched before comparing tap values; "
                + "source original random-state default is still unverified."
        ]
        let json=try JSONSerialization.data(
            withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]
        )
        try json.write(to:folder.appendingPathComponent("one-shot-manifest.json"),
                       options:.atomic)
        finished=true
        return folder
    }
}
#endif
