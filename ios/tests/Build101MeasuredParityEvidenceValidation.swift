import Foundation
import CryptoKit

func ensure(_ value: @autoclosure () -> Bool, _ note: String) {
    if !value() { fatalError("Build101 evidence FAIL: "+note) }
}

struct FakeFailure: Error {}
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent(
    "Build101-evidence-test-"+UUID().uuidString,isDirectory:true
)
try fm.createDirectory(at:root,withIntermediateDirectories:true)
defer {try? fm.removeItem(at:root)}
let manifest=root.appendingPathComponent("manifest.json")
let sample=Data("{\"scope\":\"controlled-fixture-only\"}".utf8)
try sample.write(to:manifest)

let fixed=Date(timeIntervalSince1970:1_700_000_000)
let simulated=Build101DeviceParityEvidence.capture(
    version:"1.8.68",build:"101",
    binarySourceCommit:String(repeating:"a",count:40),deviceModel:"Host Unit Test",
    osVersion:"16.5.1",physicalDevice:false,now:fixed,
    referenceManifest:manifest,evaluate:{"synthetic comparator success"}
)
ensure(simulated.status=="controlled_stage_pass_non_target_environment",
       "host test may not promote itself to iPhone")
ensure(!simulated.controlledParityPassOnTargetDevice &&
       !simulated.fullPythonOriginalCertified,
       "macOS never certifies source or iPhone")
let expected=SHA256.hash(data:sample).map {
    String(format:"%02x",$0)
}.joined()
ensure(simulated.referenceManifestSHA256==expected,
       "reference manifest SHA-256 must use actual file bytes")
let failed=Build101DeviceParityEvidence.capture(
    version:"1.8.68",build:"101",
    binarySourceCommit:String(repeating:"a",count:40),deviceModel:"iPhone fixture",
    osVersion:"16.5.1",physicalDevice:true,now:fixed,
    referenceManifest:manifest,evaluate:{throw FakeFailure()}
)
ensure(failed.status=="controlled_stage_failed_or_reference_missing" &&
       failed.firstFailure != nil &&
       !failed.controlledParityPassOnTargetDevice,
       "failed physical run MUST persist first failure")
var count=0
let missing=Build101DeviceParityEvidence.capture(
    version:"1.8.68",build:"101",
    binarySourceCommit:String(repeating:"a",count:40),deviceModel:"iPhone fixture",
    osVersion:"16.5.1",physicalDevice:true,now:fixed,
    referenceManifest:nil,evaluate:{count+=1;return "invalid"}
)
ensure(count==0 && missing.firstFailure != nil,
       "missing upstream reference must fail BEFORE test executes")
let invalid=Build101DeviceParityEvidence.capture(
    version:"1.8.68",build:"101",
    binarySourceCommit:String(repeating:"a",count:40),deviceModel:"iPhone fixture",
    osVersion:"16.5.1",physicalDevice:true,now:fixed,
    referenceManifest:manifest,evaluate:{"  "}
)
ensure(invalid.firstFailure != nil &&
       !invalid.controlledParityPassOnTargetDevice,
       "empty evaluator report cannot count")
let otherOS=Build101DeviceParityEvidence.capture(
    version:"1.8.68",build:"101",
    binarySourceCommit:String(repeating:"a",count:40),deviceModel:"iPhone fixture",
    osVersion:"18.7",physicalDevice:true,now:fixed,
    referenceManifest:manifest,evaluate:{"synthetic test success"}
)
ensure(otherOS.status=="controlled_stage_pass_non_target_environment",
       "non16.5.1 cannot claim targeted device scope")
let inTargetFixture=Build101DeviceParityEvidence.capture(
    version:"1.8.68",build:"101",
    binarySourceCommit:String(repeating:"a",count:40),deviceModel:"SIMULATED ONLY",
    osVersion:"16.5.1",physicalDevice:true,now:fixed,
    referenceManifest:manifest,evaluate:{"synthetic only"}
)
ensure(inTargetFixture.status=="controlled_stage_pass_on_physical_ios1651" &&
       inTargetFixture.controlledParityPassOnTargetDevice &&
       inTargetFixture.binarySourceCommitVerified &&
       !inTargetFixture.fullPythonOriginalCertified,
       "status contract tests only; fake arguments are never a device proof")

let missingIdentity=Build101DeviceParityEvidence.capture(
    version:"1.8.68",build:"101",
    binarySourceCommit:"missing",deviceModel:"synthetic iPhone",
    osVersion:"16.5.1",physicalDevice:true,now:fixed,
    referenceManifest:manifest,evaluate:{"synthetic success"}
)
ensure(missingIdentity.status=="controlled_stage_pass_missing_binary_commit" &&
       !missingIdentity.controlledParityPassOnTargetDevice &&
       !missingIdentity.binarySourceCommitVerified,
       "unidentifiable installed IPA cannot earn identity-bound PASS")

let output=try Build101DeviceParityEvidence.write(failed,documents:root)
ensure(output.deletingLastPathComponent().lastPathComponent == "SpektraFilm Verification",
       "per-device result must remain in persistent verification Documents")
let reopened=try JSONDecoder().decode(
    Build101DeviceParityEvidence.Report.self,
    from:Data(contentsOf:output)
)
ensure(reopened.firstFailure != nil &&
       reopened.status=="controlled_stage_failed_or_reference_missing",
       "on-disk failure must not be discarded")
ensure(reopened.fullPythonOriginalCertified==false,
       "disk evidence must never claim full upstream default certification")
ensure(reopened.limitations.count>=5,
       "unverified scope must be present even for pass")
print("PASS Build101 11 REAL evidence serialization/negative tests; " +
      "synthetic comparator ONLY, no physical iPhone or Python parity proof")
