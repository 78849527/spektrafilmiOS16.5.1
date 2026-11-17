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
    struct StageRSS:Codable {
        let stage:String
        let elapsedSeconds:Double
        let residentBytes:UInt64?
        let processAvailableBytes:UInt64?
    }
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
        // Build116 real 4-worker optional fast_stats particles.
        var parallelFastStats:Bool=false
    }
    private static let geometries=[
        Geometry(label:"1MP_Kodak_Portra_Endura_3x3_grain",
                 width:1000,height:1000,grain:true),
        Geometry(label:"2MP_Kodak_Portra_Endura_no_grain",
                 width:1600,height:1250,grain:false)
    ]

    private static func settings(
        grain:Bool,parallelFastStats:Bool=false
    )->OriginalSourcePhysicalImage.Parameters {
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
            if parallelFastStats {
                original.useFastStats=true
                original.useUnseededParallel=true
                original.parallelWorkerCount=4
                original.numbaSeed=nil
                original.fastStatsSeed=nil
            } else {
                original.numbaSeed=8888
            }
            result.sourceGrain=original
        }
        return result
    }

    /// Own only ONE Float64 frame at a time. Never keep the previous
    /// 1MP/2MP buffer in the report or in a stage-observer closure.
    /// This is the actual production per-pixel Hanatos→H-D→spatial DIR→
    /// measured source grain (when enabled)→optical paper→scanner.
    private static func render(
        _ geometry:Geometry,with parameters:OriginalSourcePhysicalImage.Parameters,
        phaseObserver:((String)->Void)?=nil
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
            &frame,parameters:parameters,stageDoubleObserver:nil,
            phaseMemoryObserver:phaseObserver
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

    private static func measure(
        _ g:Geometry,phaseSink:((StageRSS)->Void)?=nil
    )->OpticalCase {
        // Same baseline knobs as settings(); never bypass real renderer gate.
        let bpp=Build106SourceMemoryLedger.productionAdditional(
            scannerFinish:false,scannerGlare:false,grain:g.grain,
            grainSublayers:true,cameraActive:false,cameraLens:false,
            filmHalation:false,paperDiffusion:false,stageObserver:false,
            paperStageObserver:false,outputGamut:false,
            parallelGrain:g.parallelFastStats
        )
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
            let callback:((String)->Void)? = phaseSink.map { sink in
                return { (name:String) in
                    sink(StageRSS(
                        stage:name,
                        elapsedSeconds:ProcessInfo.processInfo.systemUptime-start,
                        residentBytes:resident(),
                        processAvailableBytes:available()
                    ))
                }
            }
            let actual=try render(
                g,with:settings(
                    grain:g.grain,parallelFastStats:g.parallelFastStats
                ),phaseObserver:callback
            )
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


    /// Build116: opt-in real-device memory measurements.
    /// Build116: one tap runs the WHOLE 8-size x 2-source-grain route matrix.
    /// Each permitted size is rendered once; denied sizes have explicit
    /// pre-allocation refusal entries. No reduced-resolution substitution.
    struct Build116GrainMemoryReport:Codable {
        let schema:Int
        let appVersion:String
        let appBuild:String
        let compiledSourceCommit:String
        let osVersion:String
        let physicalDevice:Bool
        let generatedUTC:String
        let matrixCases:[OpticalCase]
        let plannedCaseCount:Int
        let measuredCaseCount:Int
        let refusedCaseCount:Int
        let failedCaseCount:Int
        let notRunCaseCount:Int
        let allAdmittedCasesPassed:Bool
        let thirteenMegapixelGrainBudgetBytes:UInt64
        let thirteenMegapixelGrainAdmissionRefused:Bool
        let thirteenMegapixelGrainActuallyRendered:Bool
        let sampledRSSIsExactJetsamPeak:Bool
        let firstFailure:String?
        let limitations:[String]
    }

    static func captureBuild116GrainMemory(
        version:String,build:String,commit:String,
        osVersion:String,physicalDevice:Bool,
        checkpointURL:URL?=nil
    )->Build116GrainMemoryReport {
        let target=physicalDevice && osVersion=="16.5.1" &&
            commit.count==40 && commit.allSatisfy {
                "0123456789abcdef".contains($0)
            }

        // Full-size source grain test matrix, ordered low-to-high:
        // 1 / 2 / 3 / 4 / 6 / 8 / 10 / 13 million pixels.
        // Each real shape is tested via the original fixed-seed SciPy
        // layer path AND optional 4-worker unseeded Numba fast_stats.
        // The production Build91 budget decides which cases may execute.
        let shapes:[(name:String,width:Int,height:Int)]=[
            ("1MP",1000,1000),
            ("2MP",1600,1250),
            ("3MP",2000,1500),
            ("4MP",2000,2000),
            ("6MP",3000,2000),
            ("8MP",4000,2000),
            ("10MP",4000,2500),
            ("13MP",5000,2600)
        ]
        var cases=[Geometry]()
        for shape in shapes {
            for parallel in [false,true] {
                let route=parallel ? "Numba4WorkerFastStats" : "SciPySeeded"
                cases.append(Geometry(
                    label:"Build116_\(shape.name)_\(route)_3x3_Float64",
                    width:shape.width,height:shape.height,grain:true,
                    parallelFastStats:parallel
                ))
            }
        }

        var results=[OpticalCase]()
        var executionFailure:String?
        var persistenceFailure:String?
        func saveCheckpoint(_ phase:String)->Bool {
            guard let checkpointURL else {return true}
            var text="status=IN_PROGRESS\napp=\(version) build=\(build) sha=\(commit)\n"
            text+="phase=\(phase)\n"
            text+="completed=\(results.count)/\(cases.count)\n"
            for item in results {
                text+="\(item.label) | \(item.status) | RSS="
                text+="\(item.sampledPeakResidentBytes.map{String($0)} ?? "none")"
                text+=" | error=\(item.firstFailure ?? "none")\n"
            }
            do {
                try text.write(to:checkpointURL,atomically:true,encoding:.utf8)
                return true
            } catch {
                persistenceFailure="Build116 无法更新真机矩阵检查点："+error.localizedDescription
                return false
            }
        }

        for geometry in cases {
            if !saveCheckpoint("BEFORE_\(geometry.label)") {break}
            let result:OpticalCase
            if !target {
                result=skipped(geometry,
                    "非绑定有效 SHA 的 iOS 16.5.1 真机，禁止宣称实测")
            } else if let executionFailure {
                // After a real execution error, continue recording all
                // remaining rows as not-run, but no further allocations.
                // Memory-admission refusal alone is NOT execution failure.
                result=skipped(geometry,
                    "前一真实颗粒渲染失败，安全停止后续执行："+executionFailure)
            } else {
                result=measure(geometry)
                if result.status=="real_source_render_failed_or_unmeasured" {
                    executionFailure=result.firstFailure ?? "颗粒执行失败"
                }
            }
            results.append(result)
            if !saveCheckpoint("AFTER_\(geometry.label)") {break}
        }
        if results.count<cases.count {
            for geometry in cases.dropFirst(results.count) {
                results.append(skipped(geometry,
                    persistenceFailure ?? "矩阵提前结束，未执行"))
            }
        }

        let measured=results.filter {
            $0.status=="real_source_float64_render_pass"
        }.count
        let refused=results.filter {
            $0.status=="refused_by_production_memory_gate"
        }.count
        let failed=results.filter {
            $0.status=="real_source_render_failed_or_unmeasured"
        }.count
        let notRun=results.filter {$0.status=="not_run"}.count
        let allAdmitted=target && measured>0 && failed==0 &&
            notRun==0 && persistenceFailure==nil &&
            results.count==cases.count

        let thirteen=results.filter {
            $0.width==5000 && $0.height==2600
        }
        let thirteenRefused=thirteen.count==2 && thirteen.allSatisfy {
            $0.status=="refused_by_production_memory_gate"
        }
        let thirteenRendered=thirteen.contains {
            $0.status=="real_source_float64_render_pass"
        }
        let budget=UInt64(13_000_000) * (
            OriginalSourcePhysicalImage.estimatedPeakBytesPerPixel +
            OriginalSourcePhysicalGrain.extraBytesPerPixel +
            OriginalSourcePhysicalGrain.unseededParallelExtraBytesPerPixel
        )

        let first=persistenceFailure ?? executionFailure ??
            (target ? nil : "非有效 SHA 的 iOS 16.5.1 真机")
        return Build116GrainMemoryReport(
            schema:2,appVersion:version,appBuild:build,
            compiledSourceCommit:commit,osVersion:osVersion,
            physicalDevice:physicalDevice,
            generatedUTC:ISO8601DateFormatter().string(from:Date()),
            matrixCases:results,plannedCaseCount:cases.count,
            measuredCaseCount:measured,refusedCaseCount:refused,
            failedCaseCount:failed,notRunCaseCount:notRun,
            allAdmittedCasesPassed:allAdmitted,
            thirteenMegapixelGrainBudgetBytes:budget,
            thirteenMegapixelGrainAdmissionRefused:thirteenRefused,
            thirteenMegapixelGrainActuallyRendered:thirteenRendered,
            sampledRSSIsExactJetsamPeak:false,firstFailure:first,
            limitations:[
                "One tap: 8 image sizes x SciPy seeded and Numba 4-worker 3x3 source-grain routes",
                "Only production Build91/optical preflight-admitted cases really render; memory refusals are NOT test passes",
                "After a real rendering failure, remaining cases record not_run for safety",
                "25ms sampled RSS can miss Jetsam high-watermarks and short transient peaks",
                "Synthetic sRGB source frame, not imported RAW/ICC/EXIF end-to-end",
                "Unseeded Numba output may not repeat bitwise; no Python full-size image parity"
            ]
        )
    }


    // Build118: one explicit 8/10/13MP button per report; no chained sizes.
    struct Build118LargeCase:Codable {
        let route:String
        let optical:OpticalCase
        let stages:[StageRSS]
    }
    struct Build118LargeReport:Codable {
        let schema:Int
        let appVersion:String
        let appBuild:String
        let compiledSourceCommit:String
        let osVersion:String
        let physicalDevice:Bool
        let megapixels:Int
        let width:Int
        let height:Int
        let cases:[Build118LargeCase]
        let measuredCaseCount:Int
        let refusedCaseCount:Int
        let failedCaseCount:Int
        let notRunCaseCount:Int
        let bothRoutesRendered:Bool
        let firstFailure:String?
        let generatedUTC:String
        let limitations:[String]
    }
    static func captureBuild118Large(
        megapixels:Int,version:String,build:String,commit:String,
        osVersion:String,physicalDevice:Bool,checkpointURL:URL?
    )->Build118LargeReport {
        let shape:(Int,Int)
        switch megapixels {
        case 8: shape=(4000,2000)
        case 10: shape=(4000,2500)
        case 13: shape=(5000,2600)
        default: shape=(0,0)
        }
        let target=physicalDevice && osVersion=="16.5.1" &&
            build=="118" && shape.0>0 &&
            commit.count==40 && commit.allSatisfy {
                "0123456789abcdef".contains($0)
            }
        var results=[Build118LargeCase]()
        var executionFailure:String?
        var checkpointFailure:String?
        func checkpoint(_ step:String)->Bool {
            guard let checkpointURL else {return true}
            var text="status=IN_PROGRESS\napp=\(version) build=\(build) sha=\(commit)\n"
            text+="selected=\(megapixels)MP\nstep=\(step)\ncompleted=\(results.count)/2\n"
            for entry in results {
                text+="\(entry.route): \(entry.optical.status), RSS="
                text+="\(entry.optical.sampledPeakResidentBytes.map{String($0)} ?? "none")"
                text+=" error=\(entry.optical.firstFailure ?? "none")\n"
            }
            do {
                try text.write(to:checkpointURL,atomically:true,encoding:.utf8)
                return true
            } catch {
                checkpointFailure=error.localizedDescription
                return false
            }
        }
        for parallel in [false,true] {
            let route=parallel ? "Numba4WorkerFastStats" : "SciPySeeded"
            let g=Geometry(
                label:"Build118_\(megapixels)MP_\(route)_3x3_Float64",
                width:shape.0,height:shape.1,
                grain:true,parallelFastStats:parallel
            )
            let safe=checkpoint("BEFORE_\(route)")
            var samples=[StageRSS]()
            let value:OpticalCase
            if !target {
                value=skipped(g,"必须为源码 SHA 绑定的 Build118 iOS16.5.1 真机")
            } else if !safe || checkpointFailure != nil {
                value=skipped(g,"Jetsam 检查点无法写入，停止大图渲染")
            } else if let executionFailure {
                value=skipped(g,"前一真实渲染失败，停止下一条路线："+executionFailure)
            } else {
                value=measure(g,phaseSink:{ sample in
                    samples.append(sample)
                    _=checkpoint("IN_\(route)_\(sample.stage)")
                })
                if value.status=="real_source_render_failed_or_unmeasured" {
                    executionFailure=value.firstFailure ?? "真实渲染失败"
                }
            }
            results.append(Build118LargeCase(
                route:route,optical:value,stages:samples
            ))
            _=checkpoint("AFTER_\(route)")
        }
        let passed=results.filter{
            $0.optical.status=="real_source_float64_render_pass"
        }.count
        let refused=results.filter{
            $0.optical.status=="refused_by_production_memory_gate"
        }.count
        let failed=results.filter{
            $0.optical.status=="real_source_render_failed_or_unmeasured"
        }.count
        let notRun=results.filter{$0.optical.status=="not_run"}.count
        return Build118LargeReport(
            schema:1,appVersion:version,appBuild:build,
            compiledSourceCommit:commit,osVersion:osVersion,
            physicalDevice:physicalDevice,megapixels:megapixels,
            width:shape.0,height:shape.1,cases:results,
            measuredCaseCount:passed,refusedCaseCount:refused,
            failedCaseCount:failed,notRunCaseCount:notRun,
            bothRoutesRendered:passed==2 && checkpointFailure==nil,
            firstFailure:checkpointFailure ?? executionFailure ??
                (target ? nil : "非 Build118 iOS16.5.1 真机"),
            generatedUTC:ISO8601DateFormatter().string(from:Date()),
            limitations:[
                "Separate size selection: two source-grain routes for one selected resolution only",
                "Same 80% process headroom and predecode/renderer production gate",
                "25ms sampled RSS + stage point samples are NOT exact Jetsam high-water marks",
                "Atomic checkpoint persists the last stage before potential Jetsam",
                "Synthetic sRGB only; no RAW/ICC/16-bit full-path Python parity",
                "Numba unseeded worker results are stochastic, not bit-identical arbitrary source stream",
                "Other optional camera/print/scanner/FFT routes keep conservative memory ledger"
            ]
        )
    }

    static func writeBuild118Large(
        _ report:Build118LargeReport,documents:URL
    ) throws -> (log:URL,json:URL) {
        let folder=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true
        )
        let prefix="Build118-\(report.megapixels)MP-grain-memory-"+UUID().uuidString
        let log=folder.appendingPathComponent(prefix+".log")
        let json=folder.appendingPathComponent(prefix+".json")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:json,options:.atomic)
        var text="Build118 independent \(report.megapixels)MP SciPy and Numba 3x3 Float64\n"
        text+="App \(report.appVersion) Build\(report.appBuild) SHA \(report.compiledSourceCommit)\n"
        text+="iOS \(report.osVersion), physical \(report.physicalDevice)\n"
        text+="Measured \(report.measuredCaseCount)/2; refused \(report.refusedCaseCount); failed \(report.failedCaseCount); not-run \(report.notRunCaseCount)\n"
        text+="Both actual renders passed: \(report.bothRoutesRendered)\n"
        for entry in report.cases {
            let c=entry.optical
            text+="\n\(entry.route): \(c.status) \(c.width)x\(c.height)\n"
            text+="Budget \(c.estimatedProductionBudgetBytes.map{String($0)} ?? "none") RSS before / sampled peak / after: \(c.beforeResidentBytes.map{String($0)} ?? "none") / \(c.sampledPeakResidentBytes.map{String($0)} ?? "none") / \(c.afterResidentBytes.map{String($0)} ?? "none")\n"
            text+="Minimum headroom \(c.minimumAvailableBytes.map{String($0)} ?? "none") samples \(c.residentSampleCount) seconds \(c.elapsedSeconds.map{String($0)} ?? "none") checksum \(c.outputSampleChecksum.map{String($0)} ?? "none")\n"
            text+="First failure / admission reason \(c.firstFailure ?? "none")\n"
            for point in entry.stages {
                text+="  \(point.stage) t=\(point.elapsedSeconds)s rss=\(point.residentBytes.map{String($0)} ?? "none") available=\(point.processAvailableBytes.map{String($0)} ?? "none")\n"
            }
        }
        text+="\nFirst failure \(report.firstFailure ?? "none")\n"
        text+=report.limitations.joined(separator:"\n")
        try text.write(to:log,atomically:true,encoding:.utf8)
        return (log,json)
    }

    static func writeBuild116GrainMemory(
        _ report:Build116GrainMemoryReport,documents:URL
    ) throws -> (log:URL,json:URL) {
        let dir=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:dir,withIntermediateDirectories:true
        )
        let prefix="Build116-grain-memory-"+UUID().uuidString
        let json=dir.appendingPathComponent(prefix+".json")
        let log=dir.appendingPathComponent(prefix+".log")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:json,options:.atomic)
        var text="Build116 full 8-size x 2-route grain memory matrix\n"
        text+="App \(report.appVersion) Build\(report.appBuild) SHA \(report.compiledSourceCommit)\n"
        text+="iOS \(report.osVersion), physical \(report.physicalDevice)\n"
        text+="Planned: \(report.plannedCaseCount), real passed: \(report.measuredCaseCount)\n"
        text+="Admission-refused: \(report.refusedCaseCount), failed: \(report.failedCaseCount), not-run: \(report.notRunCaseCount)\n"
        text+="All admitted tests passed: \(report.allAdmittedCasesPassed)\n"
        text+="13MP real grain rendered: \(report.thirteenMegapixelGrainActuallyRendered)\n"
        text+="13MP both grain routes refused: \(report.thirteenMegapixelGrainAdmissionRefused)\n"
        text+="13MP parallel budget: \(report.thirteenMegapixelGrainBudgetBytes)\n"
        for item in report.matrixCases {
            text+="\n\(item.label) \(item.width)x\(item.height): \(item.status)\n"
            text+="Estimated bytes: \(item.estimatedProductionBudgetBytes.map{String($0)} ?? "none")\n"
            text+="RSS before / sampled peak / after: \(item.beforeResidentBytes.map{String($0)} ?? "none") / \(item.sampledPeakResidentBytes.map{String($0)} ?? "none") / \(item.afterResidentBytes.map{String($0)} ?? "none")\n"
            text+="RSS samples: \(item.residentSampleCount), seconds: \(item.elapsedSeconds.map{String($0)} ?? "none")\n"
            text+="Checksum: \(item.outputSampleChecksum.map{String($0)} ?? "none")\n"
            text+="First failure / gate reason: \(item.firstFailure ?? "none")\n"
        }
        text+="\nFirst execution failure: \(report.firstFailure ?? "none")\n"
        text+=report.limitations.joined(separator:"\n")
        try text.write(to:log,atomically:true,encoding:.utf8)
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
