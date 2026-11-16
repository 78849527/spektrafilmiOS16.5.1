import Foundation
#if os(iOS)
import Darwin
import os
#endif

/// Build110 phone-only evidence. Preserve the independently certified
/// Build106-108 report and add FOUR real source Float64 optical executions.
/// This is a controlled synthetic test, not RAW or real-photo output parity.
enum Build110SourceGamutDeviceEvidence {
    struct SwitchSnapshot: Codable {
        let hasPhoto: Bool
        let pixelIOEnabled: Bool
        let fullPhysicalEnabled: Bool
        let originalHanatosDoubleEnabled: Bool
        let originalScannerEnabled: Bool
        let cameraRawMethod: String
        let inputOklchToggle: Bool
        let outputCAM16Toggle: Bool
        /// Build111: actual selected file transport metadata, NOT the fixed
        /// synthetic 512² input run by this diagnostic.
        let selectedPhotoInputSummary: String
        let selectedPhotoDirectCompatible: Bool
        let selectedPhotoP3ColorSyncConverted: Bool
        var effectiveInputOklch: Bool {
            hasPhoto && pixelIOEnabled && fullPhysicalEnabled &&
            originalHanatosDoubleEnabled &&
            cameraRawMethod == "hanatos2025" && inputOklchToggle
        }
        var effectiveOutputCAM16: Bool {
            hasPhoto && pixelIOEnabled && fullPhysicalEnabled &&
            originalHanatosDoubleEnabled && originalScannerEnabled &&
            outputCAM16Toggle
        }
    }

    struct GamutCase: Codable {
        let name: String
        let width: Int
        let height: Int
        let inputAlgorithm: String
        let outputAlgorithm: String
        let actualFloat64OpticalRender: Bool
        let status: String
        let elapsedSeconds: Double?
        let beforeResidentBytes: UInt64?
        let sampledPeakResidentBytes: UInt64?
        let afterResidentBytes: UInt64?
        let residentSampleCount: Int
        let estimatedProductionBudgetBytes: UInt64?
        let outputChannelCount: Int
        let finiteOutput: Bool
        let outputFingerprintFNV64: String?
        let outputSampleChecksum: Double?
        let meanAbsoluteDeltaFromBaseline: Double?
        let changedChannelsFromBaseline: Int?
        let firstFailure: String?
    }

    struct Report: Codable {
        let schema: Int
        let appVersion: String
        let appBuild: String
        let compiledSourceCommit: String
        let generatedUTC: String
        let deviceModel: String
        let osVersion: String
        let physicalDevice: Bool
        let userSwitchSnapshot: SwitchSnapshot
        let inheritedBuild106To108: Build108SourceOpticalDeviceStress.Report
        let gamutCases: [GamutCase]
        let allFourRealCasesPassed: Bool
        let switchesEnabledAndPathActiveAtCapture: Bool
        let effectiveUserInputOklch: Bool
        let effectiveUserOutputCAM16: Bool
        let firstFailure: String?
        let status: String
        let fullPythonWholeImageCertified: Bool
        let full13MPOperationMeasured: Bool
        let limitations: [String]
    }

    private static let width=512
    private static let height=512

    private static func resident()->UInt64? {
        #if os(iOS)
        var info=mach_task_basic_info()
        var count=mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size /
            MemoryLayout<integer_t>.size
        )
        let ret=withUnsafeMutablePointer(to:&info) { ptr in
            ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
            }
        }
        return ret==KERN_SUCCESS ? UInt64(info.resident_size) : nil
        #else
        return nil
        #endif
    }
    private static func available()->UInt64? {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }
    private final class RSSSampler {
        private let lock=NSLock()
        private var peak:UInt64?
        private var samples=0
        private var timer:DispatchSourceTimer?
        func sample() {
            let value=Build110SourceGamutDeviceEvidence.resident()
            lock.lock()
            defer {lock.unlock()}
            if let value {
                peak=max(peak ?? value,value)
                samples+=1
            }
        }
        func start() {
            sample()
            let timer=DispatchSource.makeTimerSource(
                queue:DispatchQueue.global(qos:.utility)
            )
            timer.schedule(deadline:.now(),repeating:.milliseconds(25),
                           leeway:.milliseconds(5))
            timer.setEventHandler {[weak self] in self?.sample()}
            self.timer=timer
            timer.resume()
        }
        func finish()->(UInt64?,Int) {
            timer?.cancel()
            timer=nil
            sample()
            lock.lock()
            defer {lock.unlock()}
            return (peak,samples)
        }
    }
    private struct Mode {
        let name:String
        let oklch:Bool
        let cam16:Bool
    }
    private static let modes=[
        Mode(name:"00_xy_legacy_output",oklch:false,cam16:false),
        Mode(name:"10_oklch_only",oklch:true,cam16:false),
        Mode(name:"01_cam16_only",oklch:false,cam16:true),
        Mode(name:"11_oklch_and_cam16",oklch:true,cam16:true)
    ]
    private static func params(for mode:Mode)
        ->OriginalSourcePhysicalImage.Parameters {
        var print=OriginalPrintOptics.Settings(enabled:true)
        print.normalizePrintExposure=false
        print.printExposureCompensation=false
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        dir.diffusionRadiusScale=1
        dir.tailWeight=0.06
        var p=OriginalSourcePhysicalImage.Parameters(
            filmID:"kodak_portra_400",
            paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,
            dir:dir,print:print,
            morph:OriginalPrintMorph.Settings()
        )
        p.cameraRawMethod = .hanatos2025
        p.sourceInputGamutAlgorithm = mode.oklch ? .oklch : .xy
        p.sourceOutputGamut = mode.cam16
            ? Build89OriginalOutputGamut.Settings() : nil
        return p
    }
    private static func inputFrame()->OriginalSourcePixelIO.Frame {
        var frame=OriginalSourcePixelIO.Frame(
            width:width,height:height,
            rgb:[Double](repeating:0,count:width*height*3)
        )
        for y in 0..<height {
            for x in 0..<width {
                let k=(y*width+x)*3
                frame.rgb[k]=Double((x*17+y*3)%251)/250.0
                frame.rgb[k+1]=Double((x*5+y*11)%241)/240.0
                frame.rgb[k+2]=Double((x*13+y*7)%239)/238.0
            }
        }
        return frame
    }
    private static func execute(
        _ mode:Mode,baseline:[Double]?
    )->(GamutCase,[Double]?) {
        let before=resident()
        var peak:UInt64?
        var count=0
        var budget:UInt64?
        var elapsed:Double?
        var fingerprint:String?
        var checksum:Double?
        var delta:Double?
        var changed:Int?
        var outputCount=0
        var firstFailure:String?
        var result:[Double]?
        do {
            let plan=try Build91PhysicalMemory.plan(
                width:width,height:height,
                baseBytesPerPixel:Build106SourceMemoryLedger.baseBytesPerPixel,
                additionalBytesPerPixel:0,
                physicalMemory:ProcessInfo.processInfo.physicalMemory,
                processAvailable:available()
            )
            budget=plan.estimatedPeakBytes
            try Build91PhysicalMemory.validate(plan)
            let p=params(for:mode)
            try p.validate()
            var frame=inputFrame()
            let sampler=RSSSampler()
            sampler.start()
            let start=ProcessInfo.processInfo.systemUptime
            var processingFailure:Error?
            do {
                try OriginalSourcePhysicalImage.developInPlace(
                    &frame,parameters:p,stageDoubleObserver:nil
                )
            } catch {
                processingFailure=error
            }
            elapsed=ProcessInfo.processInfo.systemUptime-start
            let sampling=sampler.finish()
            peak=sampling.0
            count=sampling.1
            if let processingFailure {throw processingFailure}
            guard frame.rgb.count==width*height*3,
                  frame.rgb.allSatisfy({$0.isFinite}) else {
                throw NSError(domain:"Build110",code:1,userInfo:[
                    NSLocalizedDescriptionKey:
                      "Float64 实际源光学输出维度错误或存在非有限值"
                ])
            }
            outputCount=frame.rgb.count
            var hash:UInt64=14695981039346656037
            var sample=0.0
            for i in frame.rgb.indices {
                let value=frame.rgb[i]
                hash=(hash ^ value.bitPattern) &* 1099511628211
                if i%997==0 {sample+=value}
            }
            fingerprint=String(hash,radix:16)
            checksum=sample
            if let baseline {
                guard baseline.count==frame.rgb.count else {
                    throw NSError(domain:"Build110",code:2,userInfo:[
                        NSLocalizedDescriptionKey:"基线尺寸不一致"
                    ])
                }
                var difference=0.0
                var modified=0
                for i in frame.rgb.indices {
                    let change=abs(frame.rgb[i]-baseline[i])
                    difference+=change
                    if change>1e-12 {modified+=1}
                }
                delta=difference/Double(outputCount)
                changed=modified
                if modified==0 {
                    firstFailure="算法已执行，但与默认模式没有可测输出差异；禁止认证"
                }
            }
            if before==nil || peak==nil || resident()==nil {
                firstFailure=firstFailure ?? "真机进程 RSS 未能采样"
            }
            result=frame.rgb
        } catch {
            firstFailure=error.localizedDescription
        }
        let passed=result != nil && firstFailure==nil
        return (
            GamutCase(
                name:mode.name,width:width,height:height,
                inputAlgorithm:mode.oklch ? "oklch" : "xy",
                outputAlgorithm:mode.cam16 ? "cam16ucs" : "legacy_source_output",
                actualFloat64OpticalRender:result != nil,
                status:passed ? "real_source_float64_pass" :
                    "failed_or_not_distinguishable",
                elapsedSeconds:elapsed,beforeResidentBytes:before,
                sampledPeakResidentBytes:peak,
                afterResidentBytes:resident(),
                residentSampleCount:count,
                estimatedProductionBudgetBytes:budget,
                outputChannelCount:outputCount,
                finiteOutput:result != nil,
                outputFingerprintFNV64:fingerprint,
                outputSampleChecksum:checksum,
                meanAbsoluteDeltaFromBaseline:delta,
                changedChannelsFromBaseline:changed,
                firstFailure:firstFailure
            ),result
        )
    }
    private static func skipped(_ mode:Mode,_ why:String)->GamutCase {
        GamutCase(
            name:mode.name,width:width,height:height,
            inputAlgorithm:mode.oklch ? "oklch" : "xy",
            outputAlgorithm:mode.cam16 ? "cam16ucs" : "legacy_source_output",
            actualFloat64OpticalRender:false,
            status:"not_run",
            elapsedSeconds:nil,beforeResidentBytes:nil,
            sampledPeakResidentBytes:nil,afterResidentBytes:nil,
            residentSampleCount:0,estimatedProductionBudgetBytes:nil,
            outputChannelCount:0,finiteOutput:false,
            outputFingerprintFNV64:nil,outputSampleChecksum:nil,
            meanAbsoluteDeltaFromBaseline:nil,
            changedChannelsFromBaseline:nil,firstFailure:why
        )
    }
    static func capture(
        version:String,build:String,commit:String,
        device:String,osVersion:String,physicalDevice:Bool,
        coreManifest:URL?,grainDirectory:URL?,
        switches:SwitchSnapshot
    )->Report {
        let old=Build108SourceOpticalDeviceStress.capture(
            version:version,build:build,commit:commit,
            device:device,osVersion:osVersion,
            physicalDevice:physicalDevice,
            coreManifest:coreManifest,grainDirectory:grainDirectory
        )
        let correctDevice=physicalDevice && osVersion=="16.5.1" &&
            old.previousBuild106107.compiledSourceCommitValid
        var actual=[GamutCase]()
        var reference:[Double]?
        for mode in modes {
            if !correctDevice {
                actual.append(skipped(mode,
                    "非源码匹配的 iOS16.5.1 真机，禁止记录为实际渲染"))
                continue
            }
            if mode.name=="00_xy_legacy_output" {
                let (record,pixels)=execute(mode,baseline:nil)
                actual.append(record)
                reference=pixels
            } else if let reference {
                let (record,_)=execute(mode,baseline:reference)
                actual.append(record)
            } else {
                actual.append(skipped(mode,
                    "默认 xy 基线渲染失败，后续输出差异不可证明"))
            }
        }
        let newPassed=correctDevice && actual.count==4 &&
            actual.allSatisfy {
                $0.status=="real_source_float64_pass" &&
                $0.outputFingerprintFNV64 != nil &&
                $0.sampledPeakResidentBytes != nil
            }
        let switchesActive=switches.effectiveInputOklch &&
            switches.effectiveOutputCAM16
        let firstFailure=old.firstFailure ??
            actual.compactMap{$0.firstFailure}.first ??
            (switchesActive ? nil :
                "手机当时未同时处于 Oklch 与 CAM16 有效生产模式，已单独执行四组受控测试")
        return Report(
            schema:1,appVersion:version,appBuild:build,
            compiledSourceCommit:commit,
            generatedUTC:ISO8601DateFormatter().string(from:Date()),
            deviceModel:device,osVersion:osVersion,
            physicalDevice:physicalDevice,userSwitchSnapshot:switches,
            inheritedBuild106To108:old,gamutCases:actual,
            allFourRealCasesPassed:newPassed,
            switchesEnabledAndPathActiveAtCapture:switchesActive,
            effectiveUserInputOklch:switches.effectiveInputOklch,
            effectiveUserOutputCAM16:switches.effectiveOutputCAM16,
            firstFailure:firstFailure,
            status:old.allControlledChecksPassedOnTarget &&
                newPassed && switchesActive
                ? "build110_legacy_and_four_gamut_cases_pass_ios1651"
                : "build110_incomplete_or_switches_not_active",
            fullPythonWholeImageCertified:false,
            full13MPOperationMeasured:false,
            limitations:[
                "Build106-108 controlled 28+20, memory, 1MP and 2MP results preserved in this report",
                "Four new 512x512 synthetic sRGB real Float64 film+paper+scanner renders, same input and Kodak stocks; no RAW, ImageIO import, or metadata transport",
                "User toggles are captured separately from the four controlled renders; the test does NOT render the user's imported photo",
                "Mean absolute output delta/FNV64 is an effect check, not independent original Python whole-frame parity",
                "Sampled RSS interval 25ms; not an OS Jetsam high watermark",
                "No complete 13MP full-optics or unseeded multiworker RNG certification"
            ]
        )
    }
    static func logText(_ report:Report)->String {
        var s=Build108SourceOpticalDeviceStress.logText(
            report.inheritedBuild106To108
        )
        s+="\n[Build110 | FOUR real Float64 input/output gamut combinations]\n"
        s+="Build \(report.appBuild) source \(report.compiledSourceCommit)\n"
        s+="User photo loaded=\(report.userSwitchSnapshot.hasPhoto)\n"
        s+="User direct pixel=\(report.userSwitchSnapshot.pixelIOEnabled) full optics=\(report.userSwitchSnapshot.fullPhysicalEnabled)\n"
        s+="User HanatosDouble=\(report.userSwitchSnapshot.originalHanatosDoubleEnabled) scanner=\(report.userSwitchSnapshot.originalScannerEnabled) method=\(report.userSwitchSnapshot.cameraRawMethod)\n"
        s+="User switches Oklch=\(report.userSwitchSnapshot.inputOklchToggle) CAM16=\(report.userSwitchSnapshot.outputCAM16Toggle)\n"
        s+="Build111 selected file=\(report.userSwitchSnapshot.selectedPhotoInputSummary) directCompatible=\(report.userSwitchSnapshot.selectedPhotoDirectCompatible) explicitP3ToSRGB=\(report.userSwitchSnapshot.selectedPhotoP3ColorSyncConverted)\n"
        s+="Effective production Oklch=\(report.userSwitchSnapshot.effectiveInputOklch) CAM16=\(report.userSwitchSnapshot.effectiveOutputCAM16)\n"
        for c in report.gamutCases {
            s+="\n\(c.name) sourceInput=\(c.inputAlgorithm) sourceOutput=\(c.outputAlgorithm) status=\(c.status)\n"
            s+="Size=\(c.width)x\(c.height) elapsed=\(c.elapsedSeconds.map{String($0)} ?? "not_run")\n"
            s+="RSS before/peak/after=\(c.beforeResidentBytes.map{String($0)} ?? "not_run") / \(c.sampledPeakResidentBytes.map{String($0)} ?? "not_run") / \(c.afterResidentBytes.map{String($0)} ?? "not_run") samples=\(c.residentSampleCount)\n"
            s+="Channels=\(c.outputChannelCount) fingerprint=\(c.outputFingerprintFNV64 ?? "not_run") checksum=\(c.outputSampleChecksum.map{String($0)} ?? "not_run")\n"
            s+="Mean absolute difference vs xy baseline=\(c.meanAbsoluteDeltaFromBaseline.map{String($0)} ?? "baseline_or_not_run") changed channels=\(c.changedChannelsFromBaseline.map{String($0)} ?? "baseline_or_not_run")\n"
            s+="Failure=\(c.firstFailure ?? "none")\n"
        }
        s+="\nStatus=\(report.status) First failure=\(report.firstFailure ?? "none")\n"
        s+="[BOUNDARY] Source numerical 96/4038/216 validated in prior CI. No 512² independent Python image parity, RAW, 13MP, or Jetsam certification.\n"
        return s
    }
    static func write(_ report:Report,documents:URL)throws
        ->(log:URL,json:URL) {
        let directory=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:directory,withIntermediateDirectories:true
        )
        let stem="Build106-107-108-110-gamut-four-mode-"+UUID().uuidString
        let json=directory.appendingPathComponent(stem+".json")
        let log=directory.appendingPathComponent(stem+".log")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:json,options:.atomic)
        do {
            try logText(report).write(to:log,atomically:true,encoding:.utf8)
        } catch {
            try? FileManager.default.removeItem(at:json)
            throw error
        }
        return (log,json)
    }
}
