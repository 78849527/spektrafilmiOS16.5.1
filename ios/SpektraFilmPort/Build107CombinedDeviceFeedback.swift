import Foundation
import CryptoKit
#if os(iOS)
import Darwin
import os
#endif

/// Build107: one actual physical-device feedback run, with independently
/// identified Build106 budget/lifetime evidence AND Build107 measured
/// bounded-memory evidence. Carries previous 28+20 Python-source taps.
/// No staged result is invented, cached as a PASS or silently skipped.
enum Build107CombinedDeviceFeedback {
    struct Case: Codable {
        let name: String
        let width: Int
        let height: Int
        let estimatedPeakBytes: UInt64
        let allowedByBudget: Bool
        let rejectionReason: String?
    }
    struct Build106Evidence: Codable {
        let status: String
        let scenarioCount: Int
        let cases: [Case]
        let baseBytesPerPixel: UInt64
        let fullFeatureBytesPerPixel: UInt64
        let diagnosticExtraBytesPerPixel: UInt64
        let releasedBeforeMicrostructureTheoreticalBytes: UInt64
        let lowHeadroomRejected: Bool
        let firstFailure: String?
        let measuredResidentPeak: Bool
    }
    struct Build107Evidence: Codable {
        let status: String
        let processAvailableBeforeBytes: UInt64?
        let processAvailableDuringBytes: UInt64?
        let processAvailableAfterBytes: UInt64?
        let residentBeforeBytes: UInt64?
        let residentDuringBytes: UInt64?
        let residentAfterBytes: UInt64?
        let touchedAllocationBytes: Int
        let pageChecksum: Int
        let actuallyTouchedPages: Bool
        let realResidentSampleAvailable: Bool
        let full13MPOperationMeasured: Bool
        let firstFailure: String?
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
        let build103: Build103VerificationEvidence.Report
        let build104: Build104DeviceGrainEvidence.Report
        let build106: Build106Evidence
        let build107: Build107Evidence
        let allControlledChecksPassedOnTarget: Bool
        let firstFailure: String?
        let status: String
        let fullPythonOriginalCertified: Bool
        let limitations: [String]
    }

    private static func shaOK(_ commit:String) -> Bool {
        commit.utf8.count == 40 && commit.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    /// Real Build91 production guard, six sizes x four feature sets.
    /// Never decode, allocate or falsely certify a 13MP optical frame.
    private static func checkBuild106(
        physicalMemory:UInt64, available:UInt64?
    )->Build106Evidence {
        let sizes=[(1000,1000),(1600,1250),(2000,2000),
                   (3000,2400),(4000,3000),(5000,2600)]
        let none=Build106SourceMemoryLedger.additional(
            scannerFinish:false,scannerGlare:false,grain:false,
            cameraLens:false,filmHalation:false,paperDiffusion:false,
            stageObserver:false,paperStageObserver:false)
        let grain=Build106SourceMemoryLedger.additional(
            scannerFinish:false,scannerGlare:false,grain:true,
            cameraLens:false,filmHalation:false,paperDiffusion:false,
            stageObserver:false,paperStageObserver:false)
        let full=Build106SourceMemoryLedger.additional(
            scannerFinish:true,scannerGlare:true,grain:true,
            cameraLens:true,filmHalation:true,paperDiffusion:true,
            stageObserver:false,paperStageObserver:false)
        let tapped=Build106SourceMemoryLedger.additional(
            scannerFinish:true,scannerGlare:true,grain:true,
            cameraLens:true,filmHalation:true,paperDiffusion:true,
            stageObserver:true,paperStageObserver:true)
        let scenarios:[(String,UInt64)]=[
            ("baseline",none),("3x3_grain",grain),
            ("full_source_features",full),("full_with_retained_taps",tapped)
        ]
        var cases=[Case]()
        var failure:String?
        for (w,h) in sizes {
            for (name,additional) in scenarios {
                do {
                    guard let preview=Build106SourceMemoryLedger.preview(
                        width:w,height:h,additionalBytesPerPixel:additional
                    ) else {
                        throw Build91PhysicalMemory.Failure.invalid(
                            "Build106 无法计算合法 1–13MP 工作尺寸")
                    }
                    let plan=try Build91PhysicalMemory.plan(
                        width:w,height:h,
                        baseBytesPerPixel:Build106SourceMemoryLedger.baseBytesPerPixel,
                        additionalBytesPerPixel:additional,
                        physicalMemory:physicalMemory,processAvailable:available
                    )
                    guard plan.estimatedPeakBytes==preview.totalWithFFT else {
                        throw Build91PhysicalMemory.Failure.invalid(
                            "Build106 独立账本与生产预算不一致")
                    }
                    var allowed=true
                    var rejected:String?
                    do {try Build91PhysicalMemory.validate(plan)}
                    catch {allowed=false;rejected=error.localizedDescription}
                    cases.append(Case(
                        name:name,width:w,height:h,
                        estimatedPeakBytes:plan.estimatedPeakBytes,
                        allowedByBudget:allowed,rejectionReason:rejected
                    ))
                } catch {
                    if failure==nil {failure=error.localizedDescription}
                }
            }
        }
        var lowRejected=false
        do {
            let p=try Build91PhysicalMemory.plan(
                width:2000,height:2000,physicalMemory:physicalMemory,
                processAvailable:1
            )
            try Build91PhysicalMemory.validate(p)
        } catch Build91PhysicalMemory.Failure.invalid(_) {
            lowRejected=true
        } catch {
            if failure==nil {failure=error.localizedDescription}
        }
        if !lowRejected && failure==nil {
            failure="Build106 低内存生产预算没有拒绝"
        }
        if none != 0 || grain != 272 || full != 608 ||
            tapped != 1616 || cases.count != 24 {
            if failure==nil {
                failure="Build106 功能预算/24 组矩阵与原版源码不一致"
            }
        }
        let scratch=Build106SourceMemoryLedger.scratch(
            pixels:1_900_000,withDyeCloud:true
        )
        if scratch.releasedBeforeMicrostructureBytes != 228_000_000 &&
           failure==nil {
            failure="Build106 Float64 颗粒生命周期账本错误"
        }
        return Build106Evidence(
            status:failure==nil ? "source_budget_24_cases_pass" :
                "source_memory_budget_failed",
            scenarioCount:cases.count,cases:cases,
            baseBytesPerPixel:120,fullFeatureBytesPerPixel:full,
            diagnosticExtraBytesPerPixel:tapped,
            releasedBeforeMicrostructureTheoreticalBytes:
                scratch.releasedBeforeMicrostructureBytes,
            lowHeadroomRejected:lowRejected,firstFailure:failure,
            measuredResidentPeak:false
        )
    }

    /// task_info measures real current process resident bytes on iPhone.
    /// This is still NOT a high-watermark/Jetsam or 13MP-render proof.
    private static func residentBytes()->UInt64? {
        #if os(iOS)
        var info=mach_task_basic_info()
        var count=mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size /
            MemoryLayout<integer_t>.size
        )
        let result=withUnsafeMutablePointer(to:&info) { ptr in
            ptr.withMemoryRebound(
                to:integer_t.self,capacity:Int(count)
            ) { raw -> kern_return_t in
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          raw,&count)
            }
        }
        guard result==KERN_SUCCESS else {return nil}
        return UInt64(info.resident_size)
        #else
        return nil
        #endif
    }
    private static func availableBytes()->UInt64? {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    /// Physically writes 16MiB of pages, checks checksum and samples real
    /// process resident sizes. An explicit low-headroom gate comes BEFORE
    /// the allocation; no giant 12/13MP image is allocated for diagnostics.
    private static func checkBuild107()->Build107Evidence {
        let before=availableBytes()
        let rssBefore=residentBytes()
        let size=16*1024*1024
        guard let before, before>=256*1024*1024 else {
            return Build107Evidence(
                status:"not_run_insufficient_process_headroom",
                processAvailableBeforeBytes:before,
                processAvailableDuringBytes:nil,
                processAvailableAfterBytes:availableBytes(),
                residentBeforeBytes:rssBefore,residentDuringBytes:nil,
                residentAfterBytes:residentBytes(),touchedAllocationBytes:0,
                pageChecksum:0,actuallyTouchedPages:false,
                realResidentSampleAvailable:false,
                full13MPOperationMeasured:false,
                firstFailure:"Build107 内存不足，安全拒绝实际触页测试"
            )
        }
        var data=Data(count:size)
        var sum=0
        data.withUnsafeMutableBytes { pointer in
            if let raw=pointer.baseAddress?.assumingMemoryBound(to:UInt8.self) {
                for i in stride(from:0,to:size,by:4096) {
                    let value=UInt8(truncatingIfNeeded:i/4096)
                    raw[i]=value
                    sum+=Int(raw[i])
                }
            }
        }
        let during=withExtendedLifetime(data) {availableBytes()}
        let rssDuring=withExtendedLifetime(data) {residentBytes()}
        data.removeAll(keepingCapacity:false)
        let after=availableBytes()
        let rssAfter=residentBytes()
        let measured=rssBefore != nil && rssDuring != nil &&
            rssAfter != nil
        let touched=sum==522_240
        return Build107Evidence(
            status:measured && touched ?
                "bounded_16mib_page_touch_resident_measured" :
                "bounded_touch_failed_or_rss_unavailable",
            processAvailableBeforeBytes:before,
            processAvailableDuringBytes:during,
            processAvailableAfterBytes:after,
            residentBeforeBytes:rssBefore,
            residentDuringBytes:rssDuring,
            residentAfterBytes:rssAfter,
            touchedAllocationBytes:size,
            pageChecksum:sum,actuallyTouchedPages:touched,
            realResidentSampleAvailable:measured,
            full13MPOperationMeasured:false,
            firstFailure:measured && touched ? nil :
                (touched ? "Build107 task_info 未获得进程驻留内存" :
                    "Build107 16MiB 实际触页校验失败")
        )
    }

    static func capture(
        version:String,build:String,commit:String,
        device:String,osVersion:String,physicalDevice:Bool,
        coreManifest:URL?,grainDirectory:URL?,
        now:Date=Date()
    )->Report {
        let core=Build103VerificationEvidence.capture(
            version:version,build:build,commit:commit,device:device,
            osVersion:osVersion,physicalDevice:physicalDevice,
            manifestURL:coreManifest,
            evaluate:{observe in
                guard let coreManifest else {
                    throw NSError(domain:"Build107",code:103,
                        userInfo:[NSLocalizedDescriptionKey:
                            "Build103 Python 核心参考清单缺失"])
                }
                try SourcePhysicalImageParity.evaluate(
                    fixtures:coreManifest.deletingLastPathComponent(),
                    onBuild103StageMetric:observe
                )
            },
            rng:{try Build103VerificationEvidence.sampleSeededNumba()},
            memory:{
                Build103VerificationEvidence.sampleBoundedMemory(
                    physicalBytes:ProcessInfo.processInfo.physicalMemory,
                    available:{availableBytes()}
                )
            }
        )
        let grain=Build104DeviceGrainEvidence.capture(
            version:version,build:build,commit:commit,device:device,
            osVersion:osVersion,physicalDevice:physicalDevice,
            directory:grainDirectory
        )
        let budget=checkBuild106(
            physicalMemory:ProcessInfo.processInfo.physicalMemory,
            available:availableBytes()
        )
        let measured=checkBuild107()
        let target=physicalDevice && osVersion=="16.5.1" && shaOK(commit)
        let passed=target && core.controlledCoreStagesPassedOnTarget &&
            core.randomFirstFailure==nil && core.memoryFirstFailure==nil &&
            grain.passedOnTarget && budget.firstFailure==nil &&
            measured.firstFailure==nil &&
            measured.actuallyTouchedPages && measured.realResidentSampleAvailable
        let firstFailure:String?
        if !target {
            firstFailure="非 iOS 16.5.1 真机或编译 Git SHA 缺失"
        } else {
            firstFailure=core.coreStageFirstFailure ?? core.randomFirstFailure ??
                core.memoryFirstFailure ?? grain.failure ??
                budget.firstFailure ?? measured.firstFailure
        }
        let formatter=ISO8601DateFormatter()
        return Report(
            schema:1,appVersion:version,appBuild:build,
            compiledSourceCommit:commit,
            compiledSourceCommitValid:shaOK(commit),
            deviceModel:device,osVersion:osVersion,
            physicalDevice:physicalDevice,
            generatedUTC:formatter.string(from:now),
            build103:core,build104:grain,
            build106:budget,build107:measured,
            allControlledChecksPassedOnTarget:passed,
            firstFailure:firstFailure,
            status:passed ?
                "build106_107_feedback_controlled_pass_ios1651" :
                "build106_107_feedback_failed_or_incomplete",
            fullPythonOriginalCertified:false,
            limitations:[
                "Build106 memory matrix is a dry-run admission test, NOT measured original 13MP processing",
                "Build106 228MB early release is derived from array lifetimes, not physically measured saved RSS",
                "Build107 resident memory samples use task_info around a bounded 16MiB page touch, not a full-frame rendering/Jetsam benchmark",
                "Build103 and Build104 use small controlled Python fixtures, not default unseeded multiworker Numba prange",
                "RAW/ICC/EXIF/XMP/high-bit-depth/full-resolution original equivalence remains unverified"
            ]
        )
    }

    static func logText(_ report:Report)->String {
        func fmt(_ value:UInt64?)->String {
            value.map {String($0)} ?? "not_measured"
        }
        var lines=[
            "SpektraFilm｜Build106 + Build107 真机反馈 LOG",
            "Schema: \(report.schema)",
            "App: \(report.appVersion) / Build\(report.appBuild)",
            "Commit: \(report.compiledSourceCommit)",
            "Physical device: \(report.physicalDevice)  iOS: \(report.osVersion)",
            "Generated UTC: \(report.generatedUTC)",
            "RESULT: \(report.status)",
            "FIRST FAILURE: \(report.firstFailure ?? "none")",
            "",
            "[Build103 | independent Python 28 Float64 core stages]",
            "Status: \(report.build103.status)",
            "Stages: \(report.build103.coreStageMetricCount)/28",
            "First failure: \(report.build103.coreStageFirstFailure ?? "none")"
        ]
        for v in report.build103.coreStageMetrics {
            lines.append("\(v.caseName)/\(v.stageName) MAE=\(v.mae) RMSE=\(v.rmse) Max=\(v.maximumAbsoluteError) Over=\(v.overMaximumTolerance)")
        }
        lines += [
            "",
            "[Build104 | independent Python 20 Float64 grain stages]",
            "Status: \(report.build104.status)",
            "Stages: \(report.build104.stageMetricCount)/20",
            "SciPy single-layer flag ignored: \(report.build104.singleLayerFlagIgnoredMatchesSource)",
            "First failure: \(report.build104.failure ?? "none")"
        ]
        for v in report.build104.stageMetrics {
            lines.append("\(v.caseName)/\(v.stageName) MAE=\(v.mae) RMSE=\(v.rmse) Max=\(v.maximumAbsoluteError)")
        }
        lines += [
            "",
            "[Build106 | full-source memory ledger and scratch lifetime]",
            "Status: \(report.build106.status)",
            "Budget matrix: \(report.build106.scenarioCount)/24",
            "Base B/px: \(report.build106.baseBytesPerPixel)",
            "Full-feature extra B/px: \(report.build106.fullFeatureBytesPerPixel)",
            "With diagnostic retained stages extra B/px: \(report.build106.diagnosticExtraBytesPerPixel)",
            "Scratch eligible to release before microstructure (theoretical B): \(report.build106.releasedBeforeMicrostructureTheoreticalBytes)",
            "Low headroom rejected: \(report.build106.lowHeadroomRejected)",
            "RSS measured for this ledger: \(report.build106.measuredResidentPeak)",
            "First failure: \(report.build106.firstFailure ?? "none")"
        ]
        for v in report.build106.cases {
            lines.append("\(v.name) \(v.width)x\(v.height) predicted=\(v.estimatedPeakBytes) allowed=\(v.allowedByBudget) reason=\(v.rejectionReason ?? "none")")
        }
        lines += [
            "",
            "[Build107 | actual bounded page touch and live process RSS]",
            "Status: \(report.build107.status)",
            "Touched B: \(report.build107.touchedAllocationBytes)",
            "Page checksum: \(report.build107.pageChecksum)",
            "Headroom before/during/after B: \(fmt(report.build107.processAvailableBeforeBytes)) / \(fmt(report.build107.processAvailableDuringBytes)) / \(fmt(report.build107.processAvailableAfterBytes))",
            "RSS before/during/after B: \(fmt(report.build107.residentBeforeBytes)) / \(fmt(report.build107.residentDuringBytes)) / \(fmt(report.build107.residentAfterBytes))",
            "Full 13MP operation actually measured: \(report.build107.full13MPOperationMeasured)",
            "First failure: \(report.build107.firstFailure ?? "none")",
            "",
            "[CERTIFICATION BOUNDARY]",
            "fullPythonOriginalCertified=false"
        ]
        lines += report.limitations.map {"- "+$0}
        return lines.joined(separator:"\n")+"\n"
    }

    /// One UUID binds BOTH files; share sheet exports both attachments.
    static func write(_ report:Report,documents:URL)throws->(log:URL,json:URL) {
        let folder=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true)
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true
        )
        let prefix="Build106-107-device-feedback-"+UUID().uuidString
        let json=folder.appendingPathComponent(prefix+".json")
        let log=folder.appendingPathComponent(prefix+".log")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:json,options:.atomic)
        do {
            try logText(report).write(
                to:log,atomically:true,encoding:.utf8
            )
        } catch {
            try? FileManager.default.removeItem(at:json)
            throw error
        }
        return (log,json)
    }
}
