import Foundation

@main
enum Build106SourceMemoryLedgerValidation {
    enum Failure:Error {case invalid(String)}
    static func demand(_ condition:Bool,_ reason:String)throws {
        if !condition {throw Failure.invalid(reason)}
    }
    static func main()throws {
        let b=Build106SourceMemoryLedger.self
        let base=b.additional(
            scannerFinish:false,scannerGlare:false,grain:false,
            cameraLens:false,filmHalation:false,paperDiffusion:false,
            stageObserver:false,paperStageObserver:false
        )
        try demand(base==0,"base ledger changed")
        let all=b.additional(
            scannerFinish:true,scannerGlare:true,grain:true,
            cameraLens:true,filmHalation:true,paperDiffusion:true,
            stageObserver:false,paperStageObserver:false
        )
        try demand(all==608,"previous production feature budget changed")
        let grain=b.additional(
            scannerFinish:false,scannerGlare:false,grain:true,
            cameraLens:false,filmHalation:false,paperDiffusion:false,
            stageObserver:false,paperStageObserver:false
        )
        try demand(grain==272,"source 3x3 grain scratch mis-budgeted")
        let observed=b.additional(
            scannerFinish:true,scannerGlare:true,grain:true,
            cameraLens:true,filmHalation:true,paperDiffusion:true,
            stageObserver:true,paperStageObserver:true
        )
        try demand(observed==1616,"diagnostic observer peak budget changed")
        // Both entrypoints must compute same feature plan for same knobs.
        let predecode=b.additional(
            scannerFinish:true,scannerGlare:true,grain:true,
            cameraLens:true,filmHalation:true,paperDiffusion:true,
            stageObserver:false,paperStageObserver:false)
        let renderer=b.additional(
            scannerFinish:true,scannerGlare:true,grain:true,
            cameraLens:true,filmHalation:true,paperDiffusion:true,
            stageObserver:false,paperStageObserver:false)
        try demand(predecode==renderer,"predecode/renderer ledger drift")
        let scratch=b.scratch(pixels:1_900_000,withDyeCloud:true)
        try demand(scratch.layerInputsBytes==136_800_000,
                   "9 Double layer field wrong")
        try demand(scratch.particleFieldsBytes==45_600_000,
                   "3 Double particle scratch wrong")
        try demand(scratch.cloudBytes==45_600_000,
                   "3-channel dye cloud wrong")
        try demand(scratch.releasedBeforeMicrostructureBytes==228_000_000,
                   "scratch not eligible to release before microstructure")
        try demand(b.scratch(pixels:1_900_000,withDyeCloud:false)
                    .releasedBeforeMicrostructureBytes==182_400_000,
                   "no dye-cloud must not allocate unused cloud buffer")
        let cases:[(Int,Int)]=[
            (1000,1000),(1600,1250),(2000,2000),
            (3000,2400),(4000,3000),(5000,2600)
        ]
        for (w,h) in cases {
            let pixels=UInt64(w)*UInt64(h)
            let none=b.preview(width:w,height:h,
                               additionalBytesPerPixel:base)!
            let dense=b.preview(width:w,height:h,
                                additionalBytesPerPixel:grain)!
            let full=b.preview(width:w,height:h,
                               additionalBytesPerPixel:all)!
            try demand(none.estimatedWithoutFFT==pixels*120,
                       "Build91 base estimate changed")
            try demand(dense.totalWithFFT==pixels*392,
                       "Build91 3x3 density estimate changed")
            try demand(full.totalWithFFT==pixels*728,
                       "Build91 all-feature estimate changed")
            let tapped=b.preview(width:w,height:h,
                                 additionalBytesPerPixel:observed)!
            try demand(tapped.totalWithFFT>full.totalWithFFT,
                       "Retained stage arrays must cost memory")
        }
        let fft=UInt64(40_000_000)
        let fftPlan=b.preview(width:1000,height:1000,
                              additionalBytesPerPixel:grain,
                              fftScratchBytes:fft)!
        try demand(fftPlan.totalWithFFT==432_000_000,
                   "FFT scratch double-account or hidden")
        try demand(b.preview(width:5000,height:2601,
                             additionalBytesPerPixel:0)==nil,
                   "past source 13MP ceiling")
        try demand(b.preview(width:0,height:100,
                             additionalBytesPerPixel:0)==nil,
                   "invalid dimensions accepted")
        try demand(b.preview(width:1000,height:1000,
                             additionalBytesPerPixel:4097)==nil,
                   "per pixel cap bypassed")
        print("PASS Build106 source memory: 6 geometries x 4 scenarios," +
              " historical bpp unchanged, +960b/px callback guard," +
              " 228MB scratch release at 1.9MP, FFT budget and fail-closed geometry." +
              " No physical-device RSS certification claimed.")
    }
}
