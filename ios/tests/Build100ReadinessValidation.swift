import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("Build100 acceptance FAIL: " + message) }
}

let fixed=Date(timeIntervalSince1970:1_700_000_000)
let draft=Build100Readiness.capture(
    version:"1.8.67", build:"100", date:fixed,
    platform:"iPhone test fixture", osVersion:"16.5.1",
    sourceLoaded:true, processedPreviewAvailable:false,
    selectedMaterialPending:true, runtimeDiagnosticReportExists:false,
    sourcePixelMode:true, fullPhysicalMode:true
)
require(draft.version=="1.8.67" && draft.build=="100",
        "exact version source metadata")
require(draft.platform=="iPhone test fixture" &&
        draft.osVersion=="16.5.1", "runtime identity preserved")
require(draft.mode=="source_float64_experimental",
        "Float64 must be experimental, never certified")
require(draft.releaseCertification=="not_certified",
        "global full-source release cannot be auto-certified")
require(draft.manualChecks.count==12,
        "all twelve physical/algorithm gate IDs present")
require(Set(draft.manualChecks.map(\.id)).count==12,
        "stable gate IDs unique")
require(draft.manualChecks.allSatisfy {
    $0.result == .notRun && $0.evidence == ""
}, "no simulated source/device test PASS")
require(draft.selectedMaterialPending &&
        !draft.processedPreviewAvailable,
        "actual dirty material status represented")

let raw=try Build100Readiness.encode(draft)
let decoded=try JSONDecoder().decode(Build100Readiness.Report.self,from:raw)
require(decoded.schema==1 && decoded.manualChecks.count==12,
        "typed JSON Codable roundtrip")
require(decoded.releaseCertification=="not_certified",
        "persisted JSON still unverified")
let root=FileManager.default.temporaryDirectory.appendingPathComponent(
    "Build100-fixture-" + UUID().uuidString,isDirectory:true
)
try FileManager.default.createDirectory(
    at:root,withIntermediateDirectories:true
)
defer { try? FileManager.default.removeItem(at:root) }
let url=try Build100Readiness.write(draft,documents:root)
require(FileManager.default.fileExists(atPath:url.path),"real JSON file saved")
require(url.deletingLastPathComponent().lastPathComponent=="SpektraFilm Verification",
        "evidence belongs in Documents verification folder, not temp exports")
let reopened=try JSONDecoder().decode(
    Build100Readiness.Report.self,from:Data(contentsOf:url)
)
require(reopened.manualChecks.allSatisfy {$0.result == .notRun},
        "true on-disk JSON never pretends iPhone testing completed")
let mobile=Build100Readiness.capture(
    version:"1.8.67",build:"100",date:fixed,platform:"iPhone",
    osVersion:"16.5.1",sourceLoaded:false,
    processedPreviewAvailable:false,selectedMaterialPending:false,
    runtimeDiagnosticReportExists:true,sourcePixelMode:false,
    fullPhysicalMode:false
)
require(mobile.mode=="mobile_compatible","daily mobile path separate")
require(mobile.releaseCertification=="not_certified",
        "hardware diagnostic report alone never certifies full parity")
let direct=Build100Readiness.capture(
    version:"1.8.67",build:"100",date:fixed,platform:"iPhone",
    osVersion:"16.5.1",sourceLoaded:true,
    processedPreviewAvailable:false,selectedMaterialPending:false,
    runtimeDiagnosticReportExists:false,sourcePixelMode:true,
    fullPhysicalMode:false
)
require(direct.mode=="source_8bit_direct_limited",
        "8-bit direct limited branch distinct from full Float64")
print("PASS Build100 acceptance JSON 14 checks: real write/read, " +
      "12 not_run manual gates, explicit experimental Float64, mode separation")
