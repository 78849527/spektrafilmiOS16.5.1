import Foundation
#if os(iOS)
import Darwin
import os
#endif

/// Build108 diagnostic ONLY. No optical algorithm or default parameter
/// change. The original full-frame Float64 source renderer is called on
/// actual 1MP and 2MP synthetic sRGB frames, with NO stage observer and
/// NO hidden Float32/CI fallback. Not equivalent to real 13MP/RAW ingress.
enum Build108SourceOpticalDeviceStress {
    struct OpticalCase: Codable {
        let label: String
        let width: Int
        let height: Int
        let measuredFrame: Bool
        let original3x3GrainActive: Bool
        let status: String
        let estimatedProductionBudgetBytes: UInt64?
        let beforeResidentBytes: UInt64?
        let sampledPeakResidentBytes: UInt64?
        let afterResidentBytes: UInt64?
        let minimumAvailableBytes: UInt64?
        let residentSampleCount: Int
        let elapsedSeconds: Double?
        let actualOutputSampleCount: Int
        let outputSampleChecksum: Double?
        let firstFailure: String?
    }
    struct Report: Codable {
        let schema: Int
        let appVersion: String
        let appBuild: String
        let compiledSourceCommit: String
        let deviceModel: String
        let osVersion: String
        let physicalDevice: Bool
        let generatedUTC: String
        let previousBuild106107: Build107CombinedDeviceFeedback.Report
        let opticalCases: [OpticalCase]
        let allControlledChecksPassedOnTarget: Bool
        let firstFailure: String?
        let status: String
        let full13MPOperationMeasured: Bool
        let largeImagePythonNumericParityCertified: Bool
        let fullPythonOriginalCertified: Bool
        let limitations: [String]
    }

    private static func resident()->UInt64? {
        #if os(iOS)
        var info=mach_task_basic_info()
        var count=mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size /
            MemoryLayout<integer_t>.size
        )
        let status=withUnsafeMutablePointer(to:&info) { ptr in
            ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(
                    mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,&count
                )
            }
        }
        return status==KERN_SUCCESS ? UInt64(info.resident_size) : nil
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

    /// Sampled peak is genuinely sampled process RSS, NOT a Jetsam high-water
    /// counter. Sampling interval is 25ms and may miss shorter spikes.
    private final class ResidentSampler {
        private let lock=NSLock()
        private var peak:UInt64?
        private var minimumHeadroom:UInt64?
        private var number=0
        private var timer:DispatchSourceTimer?
        func sample() {
            let rss=Build108SourceOpticalDeviceStress.resident()
            let free=Build108SourceOpticalDeviceStress.available()
            lock.lock()
            defer {lock.unlock()}
            if let rss {
                peak=max(peak ?? rss,rss)
                number+=1
            }
            if let free {minimumHeadroom=min(minimumHeadroom ?? free,free)}
        }
        func start() {
            sample()
            let t=DispatchSource.makeTimerSource(
                queue:DispatchQueue.global(qos:.utility)
            )
            t.schedule(deadline:.now(),repeating:.milliseconds(25),
                       leeway:.milliseconds(5))
            t.setEventHandler { [weak self] in self?.sample() }
            timer=t
            t.resume()
        }
        func finish()->(peak:UInt64?,minimum:UInt64?,samples:Int) {
            timer?.cancel()
            timer=nil
            sample()
            lock.lock()
            defer {lock.unlock()}
            return (peak,minimumHeadroom,number)
        }
    }

    private struct Geometry {
        let label:String
        let width:Int
        let height:Int
        let grain:Bool
    }
    private static let geometries=[
        Geometry(label:"1MP_Kodak_Portra_Endura_3x3_grain",
                 width:1000,height:1000,grain:true),
        Geometry(label:"2MP_Kodak_Portra_Endura_no_grain",
                 width:1600,height:1250,grain:false)
    ]

    private static func settings(grain:Bool)
        ->OriginalSourcePhysicalImage.Parameters {
        // Same native stock pair and enlarger configuration used by the
        // independent Python "kodak_neutral_fir" reference family.
        var enlarger=OriginalPrintOptics.Settings(enabled:true)
        enlarger.normalizePrintExposure=false
        enlarger.printExposureCompensation=false
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        dir.diffusionRadiusScale=1.0
        dir.tailWeight=0.06
        var result=OriginalSourcePhysicalImage.Parameters(
            filmID:"kodak_portra_400",
            paperID:"kodak_portra_endura",
            cameraEV:0,paperEV:0,
            dir:dir,print:enlarger,
            morph:OriginalPrintMorph.Settings()
        )
        if grain {
            var original=OriginalSourcePhysicalGrain.Settings()
            original.active=true
            original.sublayersActive=true
            original.numbaSeed=8888
            result.sourceGrain=original
        }
        return result
    }

    /// Own only ONE Float64 frame at a time. Never keep the previous
    /// 1MP/2MP buffer in the report or in a stage-observer closure.
    /// This is the actual production per-pixel Hanatos→H-D→spatial DIR→
    /// measured source grain (when enabled)→optical paper→scanner.
    private static func render(
        _ geometry:Geometry,with parameters:OriginalSourcePhysicalImage.Parameters
    ) throws ->(samples:Int,checksum:Double) {
        let w=geometry.width,h=geometry.height,pixels=w*h
        var frame=OriginalSourcePixelIO.Frame(
            width:w,height:h,
            rgb:[Double](repeating:0,count:pixels*3)
        )
        for y in 0..<h {
            for x in 0..<w {
                let k=(y*w+x)*3
                frame.rgb[k]=0.12+Double((x*17+y*3)%200)/255.0
                frame.rgb[k+1]=0.08+Double((x*5+y*11)%211)/255.0
                frame.rgb[k+2]=0.15+Double((x*13+y*7)%190)/255.0
            }
        }
        try OriginalSourcePhysicalImage.developInPlace(
            &frame,parameters:parameters,stageDoubleObserver:nil
        )
        guard frame.rgb.count==pixels*3,
              frame.rgb.allSatisfy({$0.isFinite}) else {
            throw NSError(domain:"Build108",code:8,userInfo:[
                NSLocalizedDescriptionKey:"真实整图源 Float64 输出尺寸或有限性检查失败"
            ])
        }
        var checksum=0.0,number=0
        for index in stride(from:0,to:frame.rgb.count,by:997) {
            checksum+=frame.rgb[index]
            number+=1
        }
        guard checksum.isFinite,number>0 else {
            throw NSError(domain:"Build108",code:9,userInfo:[
                NSLocalizedDescriptionKey:"源图像抽样输出统计不合法"
            ])
        }
        return (number,checksum)
    }

    private static func skipped(_ g:Geometry,_ why:String)->OpticalCase {
        OpticalCase(
            label:g.label,width:g.width,height:g.height,
            measuredFrame:false,original3x3GrainActive:g.grain,
            status:"not_run",estimatedProductionBudgetBytes:nil,
            beforeResidentBytes:nil,sampledPeakResidentBytes:nil,
            afterResidentBytes:nil,minimumAvailableBytes:nil,
            residentSampleCount:0,elapsedSeconds:nil,
            actualOutputSampleCount:0,outputSampleChecksum:nil,
            firstFailure:why
        )
    }

    private static func measure(_ g:Geometry)->OpticalCase {
        let bpp:UInt64=g.grain
            ? OriginalSourcePhysicalGrain.extraBytesPerPixel : 0
        var budget:UInt64?
        do {
            // SAME pre-allocation source memory admission as production.
            let p=try Build91PhysicalMemory.plan(
                width:g.width,height:g.height,
                baseBytesPerPixel:OriginalSourcePhysicalImage.estimatedPeakBytesPerPixel,
                additionalBytesPerPixel:bpp,
                physicalMemory:ProcessInfo.processInfo.physicalMemory,
                processAvailable:available()
            )
            budget=p.estimatedPeakBytes
            try Build91PhysicalMemory.validate(p)
            // The renderer repeats its own production preflight. No bypass.
        } catch {
            return OpticalCase(
                label:g.label,width:g.width,height:g.height,
                measuredFrame:false,original3x3GrainActive:g.grain,
                status:"refused_by_production_memory_gate",
                estimatedProductionBudgetBytes:budget,
                beforeResidentBytes:resident(),sampledPeakResidentBytes:nil,
                afterResidentBytes:resident(),
                minimumAvailableBytes:available(),residentSampleCount:0,
                elapsedSeconds:nil,actualOutputSampleCount:0,
                outputSampleChecksum:nil,firstFailure:error.localizedDescription
            )
        }
        let before=resident()
        let sampler=ResidentSampler()
        sampler.start()
        let start=ProcessInfo.processInfo.systemUptime
        var count=0
        var sum:Double?
        var firstFailure:String?
        do {
            let actual=try render(g,with:settings(grain:g.grain))
            count=actual.samples
            sum=actual.checksum
        } catch {
            firstFailure=error.localizedDescription
        }
        let elapsed=ProcessInfo.processInfo.systemUptime-start
        let peak=sampler.finish()
        let after=resident()
        if firstFailure==nil && (before==nil || peak.peak==nil || after==nil) {
            firstFailure="Build108 无法获得真实进程 RSS 采样"
        }
        return OpticalCase(
            label:g.label,width:g.width,height:g.height,
            measuredFrame:sum != nil,
            original3x3GrainActive:g.grain,
            status:firstFailure==nil ? "real_source_float64_render_pass" :
                "real_source_render_failed_or_unmeasured",
            estimatedProductionBudgetBytes:budget,
            beforeResidentBytes:before,
            sampledPeakResidentBytes:peak.peak,
            afterResidentBytes:after,
            minimumAvailableBytes:peak.minimum,
            residentSampleCount:peak.samples,
            elapsedSeconds:elapsed,
            actualOutputSampleCount:count,
            outputSampleChecksum:sum,
            firstFailure:firstFailure
        )
    }

    static func capture(
        version:String,build:String,commit:String,
        device:String,osVersion:String,physicalDevice:Bool,
        coreManifest:URL?,grainDirectory:URL?
    )->Report {
        let previous=Build107CombinedDeviceFeedback.capture(
            version:version,build:build,commit:commit,device:device,
            osVersion:osVersion,physicalDevice:physicalDevice,
            coreManifest:coreManifest,grainDirectory:grainDirectory
        )
        let target=physicalDevice && osVersion=="16.5.1" &&
            previous.compiledSourceCommitValid
        var optical=[OpticalCase]()
        var stopReason:String?
        for g in geometries {
            if !target {
                optical.append(skipped(g,"非 iOS 16.5.1 真实设备，禁止声明实测"))
            } else if let stopReason {
                optical.append(skipped(g,
                    "前一张光学测试未通过，后续任务已停止："+stopReason))
            } else {
                let value=measure(g)
                optical.append(value)
                stopReason=value.firstFailure
            }
        }
        let passed=target && previous.allControlledChecksPassedOnTarget &&
            optical.count==geometries.count && optical.allSatisfy {
                $0.status=="real_source_float64_render_pass" &&
                $0.sampledPeakResidentBytes != nil &&
                $0.actualOutputSampleCount>0
            }
        let error=previous.firstFailure ?? stopReason ??
            (target ? nil : "未在已认证的 iOS 16.5.1 真机运行")
        return Report(
            schema:1,appVersion:version,appBuild:build,
            compiledSourceCommit:commit,deviceModel:device,
            osVersion:osVersion,physicalDevice:physicalDevice,
            generatedUTC:ISO8601DateFormatter().string(from:Date()),
            previousBuild106107:previous,
            opticalCases:optical,allControlledChecksPassedOnTarget:passed,
            firstFailure:error,
            status:passed ? "build106_107_108_real_1m_2m_pass_ios1651" :
                "build108_real_frame_failed_or_incomplete",
            full13MPOperationMeasured:false,
            largeImagePythonNumericParityCertified:false,
            fullPythonOriginalCertified:false,
            limitations:[
                "1MP/2MP synthetic sRGB, native full optical CPU Float64 only; NOT an ImageIO import, RAW or metadata end-to-end",
                "1MP test includes original controlled SciPy 3x3 grain; 2MP tests true optical film+paper+scanner without grain. Not all optional optics toggles exercised.",
                "Measured sampled process RSS at 25ms, not exact high-watermark/Jetsam",
                "No independent original Python 1MP/2MP image reference; 28+20 small controlled original stages remain separately certified",
                "No 13MP full-frame render, unsupported original multiworker RNG and RAW/ICC/EXIF/XMP paths"
            ]
        )
    }


    // Build114: explicitly requested only. The previous 1/2MP combined
    // diagnostics remain unchanged. On iPhone the full 13MP baseline still
    // goes through the SAME preflight + same source renderer. Never claim
    // success from geometry or memory budget alone.
    struct Build114FourGateReport: Codable {
        let schema:Int
        let appVersion:String
        let appBuild:String
        let compiledSourceCommit:String
        let osVersion:String
        let physicalDevice:Bool
        let generatedUTC:String
        let thirteenMegapixel:OpticalCase
        let thirteenMegapixelMemoryMeasured:Bool
        let originalPythonWholeImageCertified:Bool
        let raw16ICCEndToEndCertified:Bool
        let defaultNumbaUnseededParallelCertified:Bool
        let limitations:[String]
    }

    static func captureBuild114FourGates(
        version:String,build:String,commit:String,
        osVersion:String,physicalDevice:Bool
    )->Build114FourGateReport {
        let target=physicalDevice && osVersion=="16.5.1" &&
            commit.count==40 && commit.allSatisfy {
                "0123456789abcdef".contains($0)
            }
        let geometry=Geometry(
            label:"13MP_5000x2600_Float64_Hanatos_DIR_Print_Scan_NoGrain",
            width:5000,height:2600,grain:false
        )
        let result=target ? measure(geometry) : skipped(
            geometry,"非绑定有效 Git SHA 的真实 iOS 16.5.1，禁止执行 13MP"
        )
        return Build114FourGateReport(
            schema:1,appVersion:version,appBuild:build,
            compiledSourceCommit:commit,osVersion:osVersion,
            physicalDevice:physicalDevice,
            generatedUTC:ISO8601DateFormatter().string(from:Date()),
            thirteenMegapixel:result,
            thirteenMegapixelMemoryMeasured:target &&
                result.status=="real_source_float64_render_pass" &&
                result.sampledPeakResidentBytes != nil,
            originalPythonWholeImageCertified:false,
            raw16ICCEndToEndCertified:false,
            defaultNumbaUnseededParallelCertified:false,
            limitations:[
                "13MP only base no-grain synthetic sRGB; sampled RSS at 25ms may miss Jetsam high-watermark",
                "Does not certify enabled grain/halation/FFT or 13MP colour-route variants",
                "Python original 13MP whole-image output not present; do not claim complete source parity",
                "RAW camera sensor to output/ICC/metadata reference corpus absent; high-bit ingress and container tests are partial",
                "Default Numba unseeded multithread prange field not bit reproducible; seeded single-worker only"
            ]
        )
    }

    static func writeBuild114FourGates(
        _ report:Build114FourGateReport,documents:URL
    ) throws -> (log:URL,json:URL) {
        let dir=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:dir,withIntermediateDirectories:true
        )
        let prefix="Build114-four-gate-"+UUID().uuidString
        let json=dir.appendingPathComponent(prefix+".json")
        let log=dir.appendingPathComponent(prefix+".log")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:json,options:.atomic)
        let test=report.thirteenMegapixel
        let logText="""
        Build114 four certification gates
        App \(report.appVersion) Build\(report.appBuild) SHA \(report.compiledSourceCommit)
        iOS \(report.osVersion), physical device \(report.physicalDevice)
        13MP status: \(test.status)
        13MP first error: \(test.firstFailure ?? "none")
        13MP estimated bytes: \(test.estimatedProductionBudgetBytes.map{String($0)} ?? "not_run")
        13MP sampled RSS: \(test.sampledPeakResidentBytes.map{String($0)} ?? "not_run")
        13MP actual checksum: \(test.outputSampleChecksum.map{String($0)} ?? "not_run")
        Python full-image certification: \(report.originalPythonWholeImageCertified)
        RAW/16-bit/ICC end-to-end certification: \(report.raw16ICCEndToEndCertified)
        Default unseeded multithread Numba certification: \(report.defaultNumbaUnseededParallelCertified)
        \(report.limitations.joined(separator:"\n"))
        """
        try logText.write(to:log,atomically:true,encoding:.utf8)
        return (log,json)
    }

    static func logText(_ report:Report)->String {
        var log=Build107CombinedDeviceFeedback.logText(
            report.previousBuild106107
        )
        log+="\n[Build108 | ACTUAL source optical 1MP + 2MP / sampled RSS]\n"
        log+="App: \(report.appVersion) Build\(report.appBuild) SHA \(report.compiledSourceCommit)\n"
        log+="Status: \(report.status)\n"
        log+="First failure: \(report.firstFailure ?? "none")\n"
        for c in report.opticalCases {
            log+="\n\(c.label) \(c.width)x\(c.height) status=\(c.status)\n"
            log+="True full-frame processing: \(c.measuredFrame), measured grain=\(c.original3x3GrainActive)\n"
            log+="Elapsed seconds=\(c.elapsedSeconds.map{String($0)} ?? "not_run")\n"
            log+="Production budget bytes=\(c.estimatedProductionBudgetBytes.map{String($0)} ?? "not_run")\n"
            log+="RSS before/peak sampled/after bytes=\(c.beforeResidentBytes.map{String($0)} ?? "not_run") / \(c.sampledPeakResidentBytes.map{String($0)} ?? "not_run") / \(c.afterResidentBytes.map{String($0)} ?? "not_run")\n"
            log+="RSS sample count=\(c.residentSampleCount) min available=\(c.minimumAvailableBytes.map{String($0)} ?? "not_run")\n"
            log+="Output sample count/checksum=\(c.actualOutputSampleCount)/\(c.outputSampleChecksum.map{String($0)} ?? "not_run")\n"
            log+="First failure: \(c.firstFailure ?? "none")\n"
        }
        log+="\n[BOUNDARY] 13MP full optical NOT RUN; 1/2MP Python full-frame numeric parity NOT CERTIFIED.\n"
        return log
    }

    static func write(_ report:Report,documents:URL)throws->(log:URL,json:URL) {
        let dir=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:dir,withIntermediateDirectories:true
        )
        let prefix="Build106-107-108-device-feedback-"+UUID().uuidString
        let json=dir.appendingPathComponent(prefix+".json")
        let log=dir.appendingPathComponent(prefix+".log")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
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
