import Foundation

/// Build140 all-optical-option memory admission; standalone deterministic
/// Swift math test. Real iPhone RSS measurements remain separate.
@main
struct Build140RAWMemoryAdmissionValidation {
    static func demand(_ yes:Bool,_ msg:String) {
        precondition(yes, "Build140: "+msg)
    }
    static func optional(_ mask:Int,_ bit:Int)->Bool {
        (mask & (1<<bit)) != 0
    }
    static func main() throws {
        let w=3024,h=4032
        let sourcePixels=UInt64(w*h)
        let headroom:UInt64=3_163_000_000
        let grainOnly=Build106SourceMemoryLedger.productionAdditional(
            scannerFinish:false,scannerGlare:false,grain:true,
            grainSublayers:true,cameraActive:false,cameraLens:false,
            filmHalation:false,paperDiffusion:false,stageObserver:false,
            paperStageObserver:false,outputGamut:false,parallelGrain:false
        )
        demand(grainOnly==64,
               "grain-only phase-lifetime must use validated 64 not stale 224")
        // Build153: only the already measured Build152 serial no-micro
        // storage reduction may lower the conservative estimate by 8 B/px.
        // Preserve original 70/80% live gates and cold fallback.
        let noMicro=Build106SourceMemoryLedger.productionAdditional(
            scannerFinish:false,scannerGlare:false,grain:true,
            grainSublayers:true,cameraActive:false,cameraLens:false,
            filmHalation:false,paperDiffusion:false,stageObserver:false,
            paperStageObserver:false,outputGamut:false,parallelGrain:false,
            serialMicrostructureActive:false)
        demand(noMicro==56,"only observed serial no-micro reduction")
        for live:UInt64 in [2_808_018_112,2_802_496_512] {
            let old=try SafeExportResolution.plan(width:w,height:h,
                physicalMemory:4_000_000_000,processAvailableMemory:live,
                mode:.original,estimatedBytesPerPixel:168,fullSourceProcessing:true)
            do {
                try SafeExportResolution.validateForHeadroom(old,processAvailableMemory:live)
                preconditionFailure("Build152 rejection not reproduced")
            } catch SafeExportResolution.Failure.invalid {}
            let candidate=try SafeExportResolution.plan(width:w,height:h,
                physicalMemory:4_000_000_000,processAvailableMemory:live,
                mode:.original,estimatedBytesPerPixel:104+noMicro,fullSourceProcessing:true)
            try SafeExportResolution.validateForHeadroom(candidate,processAvailableMemory:live)
            demand(candidate.estimatedPeakBytes==sourcePixels*160 && !candidate.dimensions.reduced,
                   "actual observed headroom, exact geometry, unchanged 70% gate")
            do {
                try SafeExportResolution.validateForHeadroom(candidate,processAvailableMemory:2_500_000_000)
                preconditionFailure("low headroom must still refuse")
            } catch SafeExportResolution.Failure.invalid {}
        }
        let p=try Build91PhysicalMemory.plan(
            width:w,height:h,baseBytesPerPixel:104,
            additionalBytesPerPixel:grainOnly,
            physicalMemory:4_000_000_000,
            processAvailable:headroom
        )
        demand(p.estimatedPeakBytes==sourcePixels*168,
               "1219万 pixels old 328B/px bug reproduced")
        try Build91PhysicalMemory.validate(p)
        // Earlier screenshot used 104+224=328 even though its production
        // renderer uses 104+64=168 for the no-combination grain case.
        let stale=try Build91PhysicalMemory.plan(
            width:w,height:h,baseBytesPerPixel:104,
            additionalBytesPerPixel:224,physicalMemory:4_000_000_000,
            processAvailable:headroom
        )
        do {
            try Build91PhysicalMemory.validate(stale)
            preconditionFailure("old 3999MB hard refusal not reproduced")
        } catch Build91PhysicalMemory.Failure.invalid {}
        let output=try SafeExportResolution.plan(
            width:w,height:h,physicalMemory:4_000_000_000,
            processAvailableMemory:headroom,mode:.megapixels(720),
            estimatedBytesPerPixel:168,fullSourceProcessing:true
        )
        demand(output.dimensions.pixels<=7_200_000,"requested 720万 cap")
        demand(output.estimatedPeakBytes==p.estimatedPeakBytes,
               "sequential output buffers must NOT add to optical peak")
        try SafeExportResolution.validateForHeadroom(
            output,processAvailableMemory:headroom
        )
        do {
            try SafeExportResolution.validateForHeadroom(
                output,processAvailableMemory:1_500_000_000
            )
            preconditionFailure("low live memory must be refused")
        } catch SafeExportResolution.Failure.invalid {}
        // Exhaustive matrix: scanner optics, controlled scanner glare,
        // grain, camera lens, film halation, paper diffusion, output gamut,
        // unseeded grain workers. No combination may silently claim
        // grain-only optimization when another source buffer is alive.
        var cases=0
        for mask in 0..<256 {
            let scanner=optional(mask,0)
            let glare=optional(mask,1)
            let grain=optional(mask,2)
            let lens=optional(mask,3)
            let halation=optional(mask,4)
            let print=optional(mask,5)
            let gamut=optional(mask,6)
            let parallel=optional(mask,7)
            let extra=Build106SourceMemoryLedger.productionAdditional(
                scannerFinish:scanner,scannerGlare:glare,grain:grain,
                grainSublayers:true,cameraActive:lens,cameraLens:lens,
                filmHalation:halation,paperDiffusion:print,
                stageObserver:false,paperStageObserver:false,
                outputGamut:gamut,parallelGrain:parallel
            )
            let ordinary=Build106SourceMemoryLedger.additional(
                scannerFinish:scanner,scannerGlare:glare,grain:grain,
                cameraLens:lens,filmHalation:halation,paperDiffusion:print,
                stageObserver:false,paperStageObserver:false,
                parallelGrain:parallel
            )
            let noMicroExtra=Build106SourceMemoryLedger.productionAdditional(
                scannerFinish:scanner,scannerGlare:glare,grain:grain,
                grainSublayers:true,cameraActive:lens,cameraLens:lens,
                filmHalation:halation,paperDiffusion:print,stageObserver:false,
                paperStageObserver:false,outputGamut:gamut,parallelGrain:parallel,
                serialMicrostructureActive:false)
            demand(noMicroExtra==(grain && !scanner && !glare && !lens &&
                !halation && !print && !gamut && !parallel ? 56 : extra),
                "only simple serial no-microstructure may receive reduction")
            demand(extra<=ordinary,"optimized ledger must not exceed old budget")
            if extra<ordinary {
                demand(grain && !scanner && !glare && !lens &&
                    !halation && !print && !gamut,
                    "a live extra optical stage cannot receive grain-only credit")
            }
            let model=Build106SourceMemoryLedger.phaseModel(
                base:104,admittedAdditional:extra,
                scannerFinish:scanner,scannerGlare:glare,grain:grain,
                cameraLens:lens,filmHalation:halation,paperDiffusion:print,
                stageObserver:false,paperStageObserver:false,parallelGrain:parallel
            )
            demand(model.admittedBytesPerPixel==104+extra,"production admission unchanged")
            demand(model.candidatePeakBytesPerPixel==model.phases.map { $0.bytesPerPixel }.max(),
                   "candidate is max of sequential phases")
            demand(model.phases.count==8,"all phase labels retained")
            let all=try Build91PhysicalMemory.plan(
                width:w,height:h,baseBytesPerPixel:104,
                additionalBytesPerPixel:extra,
                physicalMemory:4_000_000_000,
                processAvailable:headroom
            )
            demand(all.estimatedPeakBytes==sourcePixels*(104+extra),
                   "all feature combinations share the same peak formula")
            let selected=try SafeExportResolution.plan(
                width:w,height:h,physicalMemory:4_000_000_000,
                processAvailableMemory:headroom,mode:.megapixels(720),
                estimatedBytesPerPixel:104+extra,fullSourceProcessing:true
            )
            demand(selected.estimatedPeakBytes>=all.estimatedPeakBytes,
                   "output stage must never understate source optical phase")
            cases+=1
        }
        print("PASS Build140: 256 optical option combinations, 1219万 168 vs stale 328B/px, 80% source and 70% output live headroom, reduced output remains full source optical")
        print("NOT CERTIFIED: iPhone A15 measured RSS/Jetsam or 12MP full grain render")
    }
}
