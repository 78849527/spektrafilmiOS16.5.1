import Foundation
import CryptoKit

/// Build103: append-only evidence, not a new image-processing algorithm.
/// A real Python .f64le vs Swift compare is executed by the existing
/// SourcePhysicalImageParity harness. This struct stores ACTUAL resulting
/// per-stage errors; it cannot synthesize missing stages as PASS.
enum Build103VerificationEvidence {
    struct StageMetric: Codable {
        let caseName: String
        let stageName: String
        let channelCount: Int
        let mae: Double
        let rmse: Double
        let maximumAbsoluteError: Double
        let worstPixel: Int
        let worstChannel: Int
        let overMaximumTolerance: Int
        let maximumTolerance: Double
        let maeTolerance: Double
        let expectedPythonStageSHA256: String
    }
    struct RandomSummary: Codable {
        let algorithm: String
        let controlledSeed: UInt32
        let count: Int
        let mean: Double
        let variance: Double
        let lagOneCorrelation: Double
        let maximumAbsoluteValue: Double
        let finite: Bool
        let unseededMultiworkerCertified: Bool
    }
    struct MemorySummary: Codable {
        let method: String
        let devicePhysicalBytes: UInt64
        let processAvailableBeforeBytes: UInt64?
        let processAvailableDuringBytes: UInt64?
        let processAvailableAfterBytes: UInt64?
        let touchedAllocationBytes: Int
        let checksum: Int
        let actuallyTouchedMemory: Bool
        let full13MPOperationMeasured: Bool
    }
    struct Report: Codable {
        let schema: Int
        let appVersion: String
        let appBuild: String
        let compiledSourceCommit: String
        let compiledSourceCommitValid: Bool
        let deviceModel: String
        let osVersion: String
        let physicalDevice: Bool
        let generatedUTC: String
        let pythonReferenceManifestSHA256: String?
        let pythonReferenceScope: String
        let coreStageMetricCount: Int
        let coreStagesAllPassed: Bool
        let controlledCoreStagesPassedOnTarget: Bool
        let coreStageFirstFailure: String?
        let coreStageMetrics: [StageMetric]
        let controlledRandom: RandomSummary?
        let randomFirstFailure: String?
        let memory: MemorySummary?
        let memoryFirstFailure: String?
        let status: String
        let fullPythonOriginalCertified: Bool
        let limitations: [String]
    }
    static let stageNames = [
        "logRaw","initial","inhibitors","diffused",
        "correctedLog","density","printed"
    ]
    static let limitations = [
        "Only 4 upstream controlled small-image fixtures and 28 core-stage comparisons; additional SourcePhysicalImageParity checks run but are not individually quantified here",
        "Not the default Python complete full-resolution Float64 pipeline",
        "Seeded one-worker Numba RNG moments, NOT unseeded/multithread prange equivalence",
        "Real 8MiB touched allocation is NOT a measured 13MP optical render or Jetsam stress test",
        "RAW/16bit/ICC/EXIF/XMP/Wide-Gamut end-to-end equivalence is not certified",
        "Build77 three-branch Python original parameter/default source tap equivalence remains independent"
    ]
    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
    private static func validHex(_ s:String,_ size:Int) -> Bool {
        s.utf8.count==size && s.utf8.allSatisfy {
            ($0>=48 && $0<=57) || ($0>=97 && $0<=102)
        }
    }
    static func validMetrics(_ records:[StageMetric]) -> Bool {
        guard records.count==28 else {return false}
        let groups=Set(records.map{$0.caseName})
        guard groups.count==4 else{return false}
        for group in groups {
            let taps=records.filter{$0.caseName==group}
            guard taps.count==7,
                  Set(taps.map{$0.stageName})==Set(stageNames) else {
                return false
            }
        }
        return records.allSatisfy {
            $0.channelCount>0 &&
            $0.mae.isFinite && $0.rmse.isFinite &&
            $0.maximumAbsoluteError.isFinite &&
            $0.maximumAbsoluteError>=0 && $0.mae>=0 &&
            $0.rmse>=0 && $0.maeTolerance>0 &&
            $0.maximumTolerance>0 && $0.mae<=$0.maeTolerance &&
            $0.maximumAbsoluteError<=$0.maximumTolerance &&
            $0.overMaximumTolerance==0 &&
            $0.worstPixel>=0 && (0...2).contains($0.worstChannel) &&
            validHex($0.expectedPythonStageSHA256,64)
        }
    }

    /// Actual single-thread legacy MT19937/Numba sequence, never a
    /// replacement for Python's unseeded prange worker scheduling.
    static func sampleSeededNumba(count:Int=8192) throws -> RandomSummary {
        guard count>=128 && count<=65536 else {
            throw NSError(domain:"Build103",code:1,
                          userInfo:[NSLocalizedDescriptionKey:"RNG sample count outside safe diagnostic bounds"])
        }
        var gen=OriginalSourceNumbaSingleThreadNormal(seed:8888)
        var samples=[Double]()
        samples.reserveCapacity(count)
        for _ in 0..<count {
            let value=try gen.nextNormal()
            guard value.isFinite else {
                throw NSError(domain:"Build103",code:2,
                    userInfo:[NSLocalizedDescriptionKey:"Numba seeded stream nonfinite"])
            }
            samples.append(value)
        }
        let n=Double(count)
        let mean=samples.reduce(0,+)/n
        let variance=samples.reduce(0){$0+($1-mean)*($1-mean)}/n
        var autocov=0.0
        if count>1 {
            for i in 1..<count {
                autocov+=(samples[i]-mean)*(samples[i-1]-mean)
            }
            autocov/=Double(count-1)
        }
        let corr=variance>0 ? autocov/variance : 0
        guard mean.isFinite && variance.isFinite && corr.isFinite,
              abs(mean)<0.12,variance>0.8,variance<1.2,
              abs(corr)<0.12 else {
            throw NSError(domain:"Build103",code:3,
                 userInfo:[NSLocalizedDescriptionKey:"Controlled Numba seeded moment sanity check failed; not unseeded multiworker evidence"])
        }
        return RandomSummary(
            algorithm:"legacy_Numba_MT19937_Marsaglia_seeded_single_worker",
            controlledSeed:8888,count:count,
            mean:mean,variance:variance,lagOneCorrelation:corr,
            maximumAbsoluteValue:samples.map{abs($0)}.max() ?? 0,
            finite:true,unseededMultiworkerCertified:false
        )
    }

    /// Touches 8MiB of real physical process pages. os_proc_available_memory
    /// is a process headroom indicator, NOT Resident Set Size / Jetsam peak.
    static func sampleBoundedMemory(
        physicalBytes:UInt64,available:()->UInt64?
    ) -> MemorySummary {
        let before=available()
        let size=8*1024*1024
        var data=Data(count:size)
        var checksum=0
        data.withUnsafeMutableBytes { ptr in
            guard let raw=ptr.baseAddress?.assumingMemoryBound(to:UInt8.self)
            else{return}
            for i in stride(from:0,to:size,by:4096) {
                let v=UInt8(truncatingIfNeeded:i/4096)
                raw[i]=v
                checksum+=Int(raw[i])
            }
        }
        let during=withExtendedLifetime(data) {available()}
        data.removeAll(keepingCapacity:false)
        let after=available()
        return MemorySummary(
            method:"8MiB_real_page_touch_plus_process_headroom_not_RSS",
            devicePhysicalBytes:physicalBytes,
            processAvailableBeforeBytes:before,
            processAvailableDuringBytes:during,
            processAvailableAfterBytes:after,
            touchedAllocationBytes:size,checksum:checksum,
            actuallyTouchedMemory:true,
            full13MPOperationMeasured:false
        )
    }

    static func capture(
        version:String,build:String,commit:String,device:String,
        osVersion:String,physicalDevice:Bool,
        manifestURL:URL?,now:Date=Date(),
        evaluate:((_ observe:@escaping (StageMetric)->Void) throws -> Void),
        rng:() throws -> RandomSummary,
        memory:() throws -> MemorySummary
    )->Report {
        var metrics=[StageMetric]()
        var referenceHash:String?
        var stageError:String?
        var stageCompleted=false
        do {
            guard let url=manifestURL else {
                throw NSError(domain:"Build103",code:4,
                    userInfo:[NSLocalizedDescriptionKey:"原版 Python manifest 缺失"])
            }
            let bytes=try Data(contentsOf:url)
            guard !bytes.isEmpty else {
                throw NSError(domain:"Build103",code:5,
                    userInfo:[NSLocalizedDescriptionKey:"原版 Python manifest 为空"])
            }
            referenceHash=sha256(bytes)
            try evaluate {metric in metrics.append(metric)}
            guard validMetrics(metrics) else {
                throw NSError(domain:"Build103",code:6,
                    userInfo:[NSLocalizedDescriptionKey:"实际四张参考图的28个 Float64 阶段误差记录不完整或越界"])
            }
            stageCompleted=true
        } catch {stageError=error.localizedDescription}
        var randomSummary:RandomSummary?
        var randomFailure:String?
        do {randomSummary=try rng()}
        catch {randomFailure=error.localizedDescription}
        var memorySummary:MemorySummary?
        var memoryFailure:String?
        do {memorySummary=try memory()}
        catch {memoryFailure=error.localizedDescription}
        let target=physicalDevice && osVersion=="16.5.1"
        let commitValid=validHex(commit,40)
        let onTarget=target && commitValid && stageCompleted
        let status:String
        if !stageCompleted {status="core_stage_failed_or_missing"}
        else if !target {status="core_stages_pass_non_target_environment"}
        else if !commitValid {status="core_stages_pass_missing_binary_identity"}
        else {status="controlled_28_core_stages_pass_on_ios1651"}
        let formatter=ISO8601DateFormatter()
        formatter.formatOptions=[.withInternetDateTime]
        return Report(
            schema:1,appVersion:version,appBuild:build,
            compiledSourceCommit:commit,
            compiledSourceCommitValid:commitValid,
            deviceModel:device,osVersion:osVersion,
            physicalDevice:physicalDevice,
            generatedUTC:formatter.string(from:now),
            pythonReferenceManifestSHA256:referenceHash,
            pythonReferenceScope:"Build92_original_4_images_7_core_taps_per_image",
            coreStageMetricCount:metrics.count,
            coreStagesAllPassed:stageCompleted,
            controlledCoreStagesPassedOnTarget:onTarget,
            coreStageFirstFailure:stageError,
            coreStageMetrics:metrics,
            controlledRandom:randomSummary,
            randomFirstFailure:randomFailure,
            memory:memorySummary,
            memoryFirstFailure:memoryFailure,
            status:status,fullPythonOriginalCertified:false,
            limitations:limitations
        )
    }
    static func write(_ report:Report,documents:URL) throws->URL {
        let folder=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true
        )
        let filename="Build103-device-metrics-"+UUID().uuidString+".json"
        let file=folder.appendingPathComponent(filename)
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:file,options:.atomic)
        return file
    }
}
