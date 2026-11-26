import Foundation
#if os(iOS)
import Darwin
import os
#endif

/// Build133 diagnostic only: real preserved RAW -> LibRaw ACES16 -> original
/// Float64 physical engine. Crops are explicitly diagnostic patches, never
/// resized, never used for export and never claimed as Python parity.
enum Build133RAWMemoryLadder {
    struct Sample: Codable {
        let phase: String
        let seconds: Double
        let residentBytes: UInt64?
        let physicalFootprintBytes: UInt64?
        let processAvailableBytes: UInt64?
    }
    struct Report: Codable {
        let schema: Int
        let version: String
        let build: String
        let sourceCommit: String
        let osVersion: String
        let deviceModel: String
        let level: Int
        let status: String
        let sourceWidth: Int
        let sourceHeight: Int
        let testedWidth: Int?
        let testedHeight: Int?
        let beforeHeadroom: UInt64?
        let afterHeadroom: UInt64?
        let sampledPeakRSS: UInt64?
        let sampledPeakPhysicalFootprintBytes: UInt64?
        let plannedPhaseModel: Build106SourceMemoryLedger.PhaseModel?
        let lowestHeadroom: UInt64?
        let sampleCount: Int
        let outputChecksum: Double?
        let firstFailure: String?
        let phases: [Sample]
        let limitations: [String]
    }
    static func resident() -> UInt64? {
        #if os(iOS)
        var info=mach_task_basic_info()
        var count=mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size /
            MemoryLayout<integer_t>.size
        )
        let rc=withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
            }
        }
        return rc==KERN_SUCCESS ? UInt64(info.resident_size) : nil
        #else
        return nil
        #endif
    }
    static func footprint() -> UInt64? {
        #if os(iOS)
        var info=task_vm_info_data_t()
        var count=mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let capacity=Int(count)
        let rc=withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:capacity) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
            }
        }
        guard rc==KERN_SUCCESS,
              let offset=MemoryLayout<task_vm_info_data_t>.offset(of:\.phys_footprint),
              Int(count)*MemoryLayout<integer_t>.size >= offset+MemoryLayout.size(ofValue:info.phys_footprint)
        else { return nil }
        return UInt64(info.phys_footprint)
        #else
        return nil
        #endif
    }
    static func available() -> UInt64? {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }
    private final class RSSSampler {
        private let lock=NSLock()
        private var timer:DispatchSourceTimer?
        private var peak:UInt64?
        private var peakFootprint:UInt64?
        private var lowest:UInt64?
        private var count=0
        func sample() {
            let rss=Build133RAWMemoryLadder.resident()
            let footprint=Build133RAWMemoryLadder.footprint()
            let free=Build133RAWMemoryLadder.available()
            lock.lock()
            defer {lock.unlock()}
            if let rss {peak=max(peak ?? rss,rss); count+=1}
            if let footprint {peakFootprint=max(peakFootprint ?? footprint,footprint)}
            if let free {lowest=min(lowest ?? free,free)}
        }
        func start() {
            sample()
            let t=DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.utility))
            t.schedule(deadline:.now(),repeating:.milliseconds(25),
                       leeway:.milliseconds(5))
            t.setEventHandler { [weak self] in self?.sample() }
            timer=t
            t.resume()
        }
        func finish()->(peak:UInt64?,footprint:UInt64?,lowest:UInt64?,count:Int) {
            timer?.cancel()
            timer=nil
            sample()
            lock.lock()
            defer {lock.unlock()}
            return (peak,peakFootprint,lowest,count)
        }
    }

    /// A real pixel crop of the original linear ACES16 source; no resampling,
    /// gamma, sRGB remap or 8-bit/Float32 renderer substitution.
    private static func diagnosticPatch(
        _ source:P1OriginalRawACESIngress.Source, width:Int,height:Int
    ) -> OriginalSourcePixelIO.Frame {
        let w=min(width,source.width), h=min(height,source.height)
        let left=(source.width-w)/2, top=(source.height-h)/2
        var frame=OriginalSourcePixelIO.Frame(
            width:w,height:h,rgb:[Double](repeating:0,count:w*h*3)
        )
        source.packedRGB16.withUnsafeBytes { bytes in
            let p=bytes.bindMemory(to:UInt8.self)
            for y in 0..<h {
                let sourceOffset=((top+y)*source.width+left)*3
                let targetOffset=y*w*3
                for k in 0..<(w*3) {
                    let i=(sourceOffset+k)*2
                    let value=UInt16(p[i]) | (UInt16(p[i+1]) << 8)
                    frame.rgb[targetOffset+k]=Double(Float(value)/Float(65535.0))
                }
            }
        }
        return frame
    }

    static func capture(
        level:Int,rawURL:URL,sourceWidth:Int,sourceHeight:Int,
        parameters:OriginalSourcePhysicalImage.Parameters,
        version:String,build:String,commit:String,osVersion:String,
        deviceModel:String,checkpointURL:URL
    )->Report {
        let started=Date()
        let sampler=RSSSampler()
        let startingHeadroom=available()
        var phaseSamples=[Sample]()
        var failure:String?
        var status="not_run"
        var outputChecksum:Double?
        var testedWidth:Int?,testedHeight:Int?
        var plannedPhaseModel:Build106SourceMemoryLedger.PhaseModel?
        func mark(_ label:String) {
            phaseSamples.append(Sample(
                phase:label,seconds:Date().timeIntervalSince(started),
                residentBytes:resident(),physicalFootprintBytes:footprint(),
                processAvailableBytes:available()
            ))
            let checkpoint = [
                "Build133 RAW diagnostic",
                "level=\(level) phase=\(label) status=INCOMPLETE",
                "source=\(sourceWidth)x\(sourceHeight) commit=\(commit)",
                "If iOS terminates this process, preserve this checkpoint."
            ].joined(separator:"\n") + "\n"
            try? checkpoint.write(to:checkpointURL,atomically:true,encoding:.utf8)
        }
        sampler.start()
        mark("start")
        do {
            guard (0...4).contains(level) else {
                throw NSError(domain:"Build133",code:1,userInfo:[
                    NSLocalizedDescriptionKey:"诊断档位无效"])
            }
            if level == 0 {
                plannedPhaseModel=OriginalSourcePhysicalImage.memoryEnvelope(
                    width:sourceWidth,height:sourceHeight,parameters:parameters
                ).phaseModel
                mark("predecode_budget")
                // The SAME production guard; a refusal is recorded, not bypassed.
                try OriginalSourcePhysicalImage.validateMemoryBudget(
                    width:sourceWidth,height:sourceHeight,parameters:parameters
                )
                status="budget_admitted_not_rendered"
            } else {
                if level == 4 {
                    plannedPhaseModel=OriginalSourcePhysicalImage.memoryEnvelope(
                        width:sourceWidth,height:sourceHeight,parameters:parameters
                    ).phaseModel
                    mark("full_original_predecode_gate")
                    try OriginalSourcePhysicalImage.validateMemoryBudget(
                        width:sourceWidth,height:sourceHeight,parameters:parameters
                    )
                }
                mark("before_real_libraw_aces16")
                let raw=try P1OriginalRawACESIngress.open(
                    rawURL,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
                )
                mark("raw_aces16_decoded")
                testedWidth=raw.width
                testedHeight=raw.height
                if level == 1 {
                    status="real_raw_aces16_decoded"
                } else {
                    // Admit the actual working dimensions before allocating
                    // the Double frame, using the same options as production.
                    let workWidth=level==2 ? min(1000,raw.width) : (level==3 ? min(2000,raw.width) : raw.width)
                    let workHeight=level==2 ? min(1000,raw.height) : (level==3 ? min(2000,raw.height) : raw.height)
                    var configured=parameters
                    configured.cameraInputColorSpace = .acesLinear
                    try configured.validate()
                    plannedPhaseModel=OriginalSourcePhysicalImage.memoryEnvelope(
                        width:workWidth,height:workHeight,parameters:configured
                    ).phaseModel
                    mark("before_float64_allocation_gate")
                    try OriginalSourcePhysicalImage.validateMemoryBudget(
                        width:workWidth,height:workHeight,parameters:configured
                    )
                    var frame:OriginalSourcePixelIO.Frame
                    if level==2 {
                        frame=diagnosticPatch(raw,width:1000,height:1000)
                    } else if level==3 {
                        frame=diagnosticPatch(raw,width:2000,height:2000)
                    } else {
                        frame=try P1OriginalRawACESIngress.makeSourceFrame(
                            raw,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
                        )
                    }
                    testedWidth=frame.width
                    testedHeight=frame.height
                    mark("float64_source_frame_ready")
                    try OriginalSourcePhysicalImage.developInPlace(
                        &frame,parameters:configured,
                        stageDoubleObserver:nil,
                        phaseMemoryObserver:{ phase in mark(phase) }
                    )
                    mark("original_float64_output_ready")
                    var checksum=0.0
                    for k in stride(from:0,to:frame.rgb.count,by:997) {
                        checksum+=frame.rgb[k]
                    }
                    guard checksum.isFinite else {
                        throw NSError(domain:"Build133",code:2,userInfo:[
                            NSLocalizedDescriptionKey:"真实 RAW 光学输出包含非有限校验值"])
                    }
                    outputChecksum=checksum
                    status="real_raw_original_float64_render_pass"
                }
            }
        } catch {
            failure=error.localizedDescription
            status="failed_or_admission_refused"
            mark("first_failure")
        }
        mark("finished")
        let observations=sampler.finish()
        let endingHeadroom=available()
        let final = [
            "Build133 level=\(level) status=\(status)",
            "firstFailure=\(failure ?? "none")",
            "lastPhase=\(phaseSamples.last?.phase ?? "none")",
            "sampledPeakRSS=\(observations.peak.map { String($0) } ?? "not_measured")"
        ].joined(separator:"\n") + "\n"
        try? final.write(to:checkpointURL,atomically:true,encoding:.utf8)
        return Report(
            schema:2,version:version,build:build,sourceCommit:commit,
            osVersion:osVersion,deviceModel:deviceModel,level:level,
            status:status,sourceWidth:sourceWidth,sourceHeight:sourceHeight,
            testedWidth:testedWidth,testedHeight:testedHeight,
            beforeHeadroom:startingHeadroom,afterHeadroom:endingHeadroom,
            sampledPeakRSS:observations.peak,
            sampledPeakPhysicalFootprintBytes:observations.footprint,
            plannedPhaseModel:plannedPhaseModel,lowestHeadroom:observations.lowest,
            sampleCount:observations.count,outputChecksum:outputChecksum,
            firstFailure:failure,phases:phaseSamples,
            limitations:[
                "Levels 2/3 use unchanged, unresampled center pixels with diagnostic crop boundaries: not a full-frame output or source Python parity.",
                "Level 4 uses the real production memory guard, no bypass, no Float32/8-bit or resizing fallback.",
                "25ms sampled RSS/physical footprint may miss transient peaks; iOS Jetsam is not catchable, inspect persistent checkpoint.",
                "Phase B/px estimates exclude FFT workspace and are telemetry only; production admission is unchanged.",
                "The preserved RAW is never modified and no diagnostic image replaces the editor output."
            ]
        )
    }
    static func write(_ report:Report,documents:URL)throws->(log:URL,json:URL) {
        let folder=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true)
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true)
        let prefix="Build133-RAW-level\(report.level)-"+UUID().uuidString
        let log=folder.appendingPathComponent(prefix+".log")
        let json=folder.appendingPathComponent(prefix+".json")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:json,options:.atomic)
        var lines:[String] = [
            "Build133 original RAW staged memory test",
            "App \(report.version) Build\(report.build) SHA \(report.sourceCommit)",
            "Level \(report.level), status \(report.status)",
            "RAW \(report.sourceWidth)x\(report.sourceHeight), tested \(report.testedWidth ?? 0)x\(report.testedHeight ?? 0)",
            "First failure: \(report.firstFailure ?? "none")",
            "Headroom before/after: \(report.beforeHeadroom.map { String($0) } ?? "none") / \(report.afterHeadroom.map { String($0) } ?? "none")",
            "Peak sampled RSS: \(report.sampledPeakRSS.map { String($0) } ?? "none")",
            "Minimum headroom: \(report.lowestHeadroom.map { String($0) } ?? "none")",
            "RSS samples: \(report.sampleCount)",
            "Checksum: \(report.outputChecksum.map { String($0) } ?? "none")"
        ]
        lines.append("Peak sampled physical footprint: "+(report.sampledPeakPhysicalFootprintBytes.map { String($0) } ?? "none"))
        if let model=report.plannedPhaseModel {
            lines.append("Candidate phase peak B/px (not admitted): "+String(model.candidatePeakBytesPerPixel))
            lines.append("Admitted B/px (excluding FFT): "+String(model.admittedBytesPerPixel))
            for phase in model.phases {
                lines.append("Model "+phase.phase+": "+String(phase.bytesPerPixel)+" B/px")
            }
        }
        for phase in report.phases {
            lines.append("\(phase.phase): t=\(phase.seconds)s rss=\(phase.residentBytes.map { String($0) } ?? "none") footprint=\(phase.physicalFootprintBytes.map { String($0) } ?? "none") available=\(phase.processAvailableBytes.map { String($0) } ?? "none")")
        }
        lines.append(contentsOf:report.limitations)
        try lines.joined(separator:"\n").write(
            to:log,atomically:true,encoding:.utf8)
        return (log,json)
    }
}
