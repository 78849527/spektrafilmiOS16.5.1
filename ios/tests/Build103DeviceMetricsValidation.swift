import Foundation

func require(_ condition:@autoclosure()->Bool,_ note:String) {
    if !condition() { fatalError("Build103 evidence regression: "+note) }
}
let root=FileManager.default.temporaryDirectory.appendingPathComponent(
    "Build103-fixture-"+UUID().uuidString,isDirectory:true
)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer {try? FileManager.default.removeItem(at:root)}
let manifest=root.appendingPathComponent("manifest.json")
try Data("{\"scope\":\"synthetic-host-fixture\"}".utf8).write(to:manifest)
let names=["a","b","c","d"]
var good=[Build103VerificationEvidence.StageMetric]()
for name in names {
    for stage in Build103VerificationEvidence.stageNames {
        good.append(.init(
            caseName:name,stageName:stage,channelCount:192,
            mae:0.000004,rmse:0.000006,
            maximumAbsoluteError:0.00002,
            worstPixel:4,worstChannel:1,
            overMaximumTolerance:0,
            maximumTolerance:0.002,maeTolerance:0.0003,
            expectedPythonStageSHA256:String(repeating:"a",count:64)
        ))
    }
}
require(good.count==28 && Build103VerificationEvidence.validMetrics(good),
        "four source images times seven core stages")
require(!Build103VerificationEvidence.validMetrics(Array(good.dropLast())),
        "27 stages never a false complete pass")
var bad=good
bad[3] = .init(caseName:"a",stageName:"diffused",channelCount:192,
               mae:0.000004,rmse:0.000006,
               maximumAbsoluteError:0.0023,
               worstPixel:3,worstChannel:2,overMaximumTolerance:1,
               maximumTolerance:0.002,maeTolerance:0.0003,
               expectedPythonStageSHA256:String(repeating:"a",count:64))
require(!Build103VerificationEvidence.validMetrics(bad),
        "one out-of-threshold channel blocks entire original parity claim")
let rng=try Build103VerificationEvidence.sampleSeededNumba()
require(rng.count==8192 && rng.finite &&
        rng.controlledSeed==8888 && !rng.unseededMultiworkerCertified,
        "actual single-worker seeded Numba moments are NOT multiworker parity")
let sampled=Build103VerificationEvidence.sampleBoundedMemory(
    physicalBytes:4_000_000_000,available:{1_000_000_000}
)
require(sampled.touchedAllocationBytes==8*1024*1024 &&
        sampled.actuallyTouchedMemory && !sampled.full13MPOperationMeasured,
        "real touched pages are NOT an optical 13MP peak")
let goodRun=Build103VerificationEvidence.capture(
    version:"1.8.70",build:"103",
    commit:String(repeating:"a",count:40),
    device:"synthetic userland",osVersion:"16.5.1",
    physicalDevice:true,manifestURL:manifest,
    evaluate:{ emit in for record in good {emit(record)} },
    rng:{rng},memory:{sampled}
)
require(goodRun.coreStageMetricCount==28 &&
        goodRun.controlledCoreStagesPassedOnTarget &&
        !goodRun.fullPythonOriginalCertified &&
        goodRun.randomFirstFailure==nil,
        "synthetic host pass exercises schema ONLY; not real iPhone evidence")
let file=try Build103VerificationEvidence.write(goodRun,documents:root)
let reopened=try JSONDecoder().decode(
    Build103VerificationEvidence.Report.self,
    from:Data(contentsOf:file)
)
require(reopened.coreStageMetrics.count==28 &&
        reopened.pythonReferenceManifestSHA256 != nil &&
        reopened.fullPythonOriginalCertified==false &&
        reopened.memory?.full13MPOperationMeasured==false,
        "actual persistent file roundtrip maintains strict provenance")
let failed=Build103VerificationEvidence.capture(
    version:"1.8.70",build:"103",
    commit:String(repeating:"a",count:40),
    device:"synthetic userland",osVersion:"16.5.1",
    physicalDevice:true,manifestURL:manifest,
    evaluate:{emit in
        for record in good.prefix(5) {emit(record)}
        throw NSError(domain:"Build103Test",code:7,userInfo:[
            NSLocalizedDescriptionKey:"synthetic first stage error"
        ])
    },
    rng:{rng},memory:{sampled}
)
require(!failed.coreStagesAllPassed &&
        failed.coreStageMetricCount==5 &&
        failed.coreStageFirstFailure?.contains("synthetic first stage error")==true,
        "failure records real partial-stage evidence and first error")
let missing=Build103VerificationEvidence.capture(
    version:"1.8.70",build:"103",
    commit:"missing",device:"synthetic",osVersion:"16.5.1",
    physicalDevice:true,manifestURL:nil,
    evaluate:{_ in fatalError("missing upstream fixture must not run")},
    rng:{rng},memory:{sampled}
)
require(missing.coreStageFirstFailure != nil &&
        missing.coreStageMetricCount==0 &&
        !missing.controlledCoreStagesPassedOnTarget,
        "no upstream manifest must fail closed")
let noIdentity=Build103VerificationEvidence.capture(
    version:"1.8.70",build:"103",commit:"missing",
    device:"synthetic",osVersion:"16.5.1",physicalDevice:true,
    manifestURL:manifest,
    evaluate:{emit in for item in good {emit(item)}},
    rng:{rng},memory:{sampled}
)
require(noIdentity.coreStagesAllPassed &&
        !noIdentity.controlledCoreStagesPassedOnTarget,
        "source SHA missing never certifies on-target output")
let wrongIOS=Build103VerificationEvidence.capture(
    version:"1.8.70",build:"103",
    commit:String(repeating:"a",count:40),
    device:"synthetic",osVersion:"18.7",
    physicalDevice:true,manifestURL:manifest,
    evaluate:{emit in for item in good {emit(item)}},
    rng:{rng},memory:{sampled}
)
require(!wrongIOS.controlledCoreStagesPassedOnTarget,
        "other iOS version can't certify iOS16.5.1")
print("PASS Build103 host negative tests: actual seeded RNG " +
      "8MiB touched memory, 28 synthetic schema records, SHA binding, " +
      "5-stage first failure, JSON roundtrip and strict certification limits; " +
      "NO physical iPhone test or full Python parity claimed")
