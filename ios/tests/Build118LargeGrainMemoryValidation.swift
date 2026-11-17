import Foundation

@main
enum Build118LargeGrainMemoryValidation {
    enum Failure:Error {case invalid(String)}
    static func check(_ valid:Bool,_ note:String)throws {
        if !valid {throw Failure.invalid(note)}
    }
    static func main() throws {
        let ledger=Build106SourceMemoryLedger.self
        func extra(_ parallel:Bool,
                   scanner:Bool=false,observer:Bool=false)->UInt64 {
            ledger.productionAdditional(
                scannerFinish:scanner,scannerGlare:false,
                grain:true,grainSublayers:true,cameraActive:false,
                cameraLens:false,filmHalation:false,
                paperDiffusion:false,stageObserver:observer,
                paperStageObserver:false,outputGamut:false,
                parallelGrain:parallel
            )
        }
        try check(extra(false)==64,"SciPy basic budget must be 176B/pixel")
        try check(extra(true)==72,"Numba basic budget must be 184B/pixel")
        try check(extra(false,scanner:true)==264,
                  "Scanner must still pay full legacy budget")
        try check(extra(true,observer:true)==1240,
                  "Stage observers must retain original conservative budget")
        // The same 8/10/13MP sizes from independent device buttons.
        for (w,h) in [(4000,2000),(4000,2500),(5000,2600)] {
            for parallel in [false,true] {
                let memory=try Build91PhysicalMemory.plan(
                    width:w,height:h,baseBytesPerPixel:112,
                    additionalBytesPerPixel:extra(parallel),
                    physicalMemory:4_000_000_000,
                    processAvailable:3_189_000_000
                )
                try check(
                    memory.estimatedPeakBytes ==
                        UInt64(w)*UInt64(h)*(parallel ? 184 : 176),
                    "Phase envelope drift"
                )
                try Build91PhysicalMemory.validate(memory)
                let constrained=try Build91PhysicalMemory.plan(
                    width:w,height:h,baseBytesPerPixel:112,
                    additionalBytesPerPixel:extra(parallel),
                    physicalMemory:4_000_000_000,
                    processAvailable:1_000_000_000
                )
                do {
                    try Build91PhysicalMemory.validate(constrained)
                    throw Failure.invalid("Low OS memory must refuse full frame")
                } catch Build91PhysicalMemory.Failure.invalid(_) {}
            }
        }
        let complex=ledger.productionAdditional(
            scannerFinish:true,scannerGlare:true,
            grain:true,grainSublayers:true,cameraActive:true,
            cameraLens:true,filmHalation:true,paperDiffusion:true,
            stageObserver:true,paperStageObserver:true,
            outputGamut:true,parallelGrain:true
        )
        try check(complex==1624,"Fully enabled optics budget must remain conservative")
        print("PASS Build118 independent 8/10/13MP 176/184Bpx phase envelope, real iOS 80% process headroom and original complex optics fail closed")
    }
}
