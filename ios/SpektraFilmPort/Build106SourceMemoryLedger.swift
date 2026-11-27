import Foundation

/// Build106: byte-accounting ledger shared by REAL source-physical predecode
/// and the actual in-place optical renderer. This is a conservative bound,
/// NOT an iPhone Jetsam/RSS measurement and NOT a new optical algorithm.
/// Numeric coefficients preserve the Build91 production allowance except
/// for the long-lived diagnostic observer that may capture many full images.
enum Build106SourceMemoryLedger {
    static let baseBytesPerPixel: UInt64 = 120
    static let scannerFinishBytesPerPixel: UInt64 = 40
    static let scannerGlareBytesPerPixel: UInt64 = 96
    static let grainBytesPerPixel: UInt64 = 224
    static let parallelGrainExtraBytesPerPixel: UInt64 = 56
    static let cameraLensBytesPerPixel: UInt64 = 40
    static let filmHalationBytesPerPixel: UInt64 = 120
    static let paperDiffusionBytesPerPixel: UInt64 = 40
    // Up to 23 labelled production callbacks plus 4 grain stages, one of
    // which is 9 channels (=3 standard RGB taps). Accommodates optional
    // scanner/print taps, retained Array COW snapshots and headroom.
    // If the caller retains stage buffers, 24 B/px is NOT sufficient.
    // The source digital RGB array remains budgeted in the base 120 B/px.
    static let stageObserverBytesPerPixel: UInt64 = 960
    static let paperStageBytesPerPixel: UInt64 = 48

    static func additional(
        scannerFinish:Bool,
        scannerGlare:Bool,
        grain:Bool,
        cameraLens:Bool,
        filmHalation:Bool,
        paperDiffusion:Bool,
        stageObserver:Bool,
        paperStageObserver:Bool,
        parallelGrain:Bool=false
    ) -> UInt64 {
        var bytes:UInt64=0
        if scannerFinish { bytes+=scannerFinishBytesPerPixel }
        if scannerGlare { bytes+=scannerGlareBytesPerPixel }
        if grain { bytes+=grainBytesPerPixel }
        if grain && parallelGrain { bytes+=parallelGrainExtraBytesPerPixel }
        if cameraLens { bytes+=cameraLensBytesPerPixel }
        if filmHalation { bytes+=filmHalationBytesPerPixel }
        if paperDiffusion { bytes+=paperDiffusionBytesPerPixel }
        if stageObserver { bytes+=stageObserverBytesPerPixel }
        if paperStageObserver { bytes+=paperStageBytesPerPixel }
        return bytes
    }

    /// Build118: basic 3x3 grain-only phase budget; other optics unchanged.
    /// 24B input + 24B output + 24B sublayers + 24B particle fields
    /// + 16B cloud/scratch + 16B counts = 128B/px. Reserve 48B/px
    /// allocator/CoW margin => 176B/px, or 184B/px for Numba workers.
    /// This is a model, not measured 13MP Jetsam high-watermark.
    static func productionAdditional(
        scannerFinish:Bool,scannerGlare:Bool,grain:Bool,
        grainSublayers:Bool,cameraActive:Bool,cameraLens:Bool,
        filmHalation:Bool,paperDiffusion:Bool,stageObserver:Bool,
        paperStageObserver:Bool,outputGamut:Bool,parallelGrain:Bool
    ) -> UInt64 {
        let conservative=additional(
            scannerFinish:scannerFinish,scannerGlare:scannerGlare,
            grain:grain,cameraLens:cameraLens,filmHalation:filmHalation,
            paperDiffusion:paperDiffusion,stageObserver:stageObserver,
            paperStageObserver:paperStageObserver,parallelGrain:parallelGrain
        )
        guard grain && grainSublayers && !scannerFinish && !scannerGlare &&
              !cameraActive && !cameraLens && !filmHalation &&
              !paperDiffusion && !stageObserver && !paperStageObserver &&
              !outputGamut else {return conservative}
        // Build114 source baseline is 112B/px.
        return parallelGrain ? 72 : 64
    }

    /// OPT-03: model sequential optical phases separately. The candidate
    /// is telemetry only: no reduced budget is admitted until real-device
    /// footprints and source regressions establish the actual lifetimes.
    /// Observer snapshots are persistent; FFT workspace is reported
    /// separately by Build91 and is NOT included in these B/px values.
    struct PhaseEstimate: Codable {
        let phase: String
        let bytesPerPixel: UInt64
    }

    struct PhaseModel: Codable {
        let phases: [PhaseEstimate]
        let candidatePeakBytesPerPixel: UInt64
        let admittedBytesPerPixel: UInt64
    }

    static func phaseModel(
        base:UInt64,admittedAdditional:UInt64,
        scannerFinish:Bool,scannerGlare:Bool,grain:Bool,
        cameraLens:Bool,filmHalation:Bool,paperDiffusion:Bool,
        stageObserver:Bool,paperStageObserver:Bool,parallelGrain:Bool
    ) -> PhaseModel {
        let observer = (stageObserver ? stageObserverBytesPerPixel : 0)
            + (paperStageObserver ? paperStageBytesPerPixel : 0)
        let phases:[PhaseEstimate] = [
            .init(phase:"camera_photons",bytesPerPixel:base+observer),
            .init(phase:"camera_lens",bytesPerPixel:base+observer+(cameraLens ? cameraLensBytesPerPixel : 0)),
            .init(phase:"film_halation",bytesPerPixel:base+observer+(filmHalation ? filmHalationBytesPerPixel : 0)),
            .init(phase:"spatial_DIR",bytesPerPixel:base+observer),
            .init(phase:"grain",bytesPerPixel:base+observer+(grain ? grainBytesPerPixel+(parallelGrain ? parallelGrainExtraBytesPerPixel : 0) : 0)),
            .init(phase:"paper_diffusion",bytesPerPixel:base+observer+(paperDiffusion ? paperDiffusionBytesPerPixel : 0)),
            .init(phase:"scanner_glare",bytesPerPixel:base+observer+(scannerGlare ? scannerGlareBytesPerPixel : 0)),
            .init(phase:"scanner_finish",bytesPerPixel:base+observer+(scannerFinish ? scannerFinishBytesPerPixel : 0))
        ]
        return PhaseModel(phases:phases,
            candidatePeakBytesPerPixel:phases.map { $0.bytesPerPixel }.max() ?? base,
            admittedBytesPerPixel:base+admittedAdditional)
    }

    /// Stable audit of the lifetime boundary in grain.py::apply_grain.
    /// Sub-layer interpolation and particle-count preparations are consumed
    /// BEFORE microstructure. They must NOT leak into the next whole-frame
    /// Gaussian pass. This does not claim a measured process RSS peak.
    struct Scratch {
        let layerInputsBytes:UInt64
        let particleFieldsBytes:UInt64
        let cloudBytes:UInt64
        let accumulatedDensityBytes:UInt64
        let lateMicrostructureInputBytes:UInt64
        let releasedBeforeMicrostructureBytes:UInt64
    }
    static func scratch(pixels:UInt64,withDyeCloud:Bool)->Scratch {
        // Production holds 3 layers per pixel; observed 9-layer snapshots
        // are charged to stageObserverBytesPerPixel separately.
        let layers=pixels*3*8
        let fields=pixels*3*8
        // Build116 scalar dye-cloud blur holds only one Double channel.
        let cloud=withDyeCloud ? pixels*8 : 0
        return Scratch(
            layerInputsBytes:layers,
            particleFieldsBytes:fields,
            cloudBytes:cloud,
            accumulatedDensityBytes:pixels*3*8,
            lateMicrostructureInputBytes:pixels*3*8,
            releasedBeforeMicrostructureBytes:layers+fields+cloud
        )
    }

    /// OPT-20: logical full-plane payload by lifetime for the serial
    /// nine-layer no-observer implementation only. Not allocator capacity,
    /// RSS, physical footprint, or a replacement for productionAdditional.
    /// Input includes the film-density plane; a cached density may alias
    /// that input while grain is running, and outlive it in downstream print.
    /// No credit for such aliasing in the existing admission budget.
    struct SerialGrainLifetime {
        let inputBytes:UInt64
        let outputBytes:UInt64
        let layerBytes:UInt64
        let probabilityBytes:UInt64
        let ratesBytes:UInt64
        let countBytes:UInt64
        let cloudBytes:UInt64
        let particlePhaseBytes:UInt64
        let releasedScratchBytes:UInt64
        let microstructurePhaseBytes:UInt64?
        let finalBlurPhaseBytes:UInt64?
        let logicalPeakBytes:UInt64
    }

    static func serialGrainLifetime(
        pixels:UInt64,dyeCloud:Bool,microstructure:Bool,
        microBlur:Bool,finalBlur:Bool
    )->SerialGrainLifetime? {
        guard pixels>0,pixels<=13_000_000 else{return nil}
        let scalar=pixels*8,rgb=pixels*24
        // Serial no-observer path reuses dead rates for cloud and
        // dead probabilities for its intermediate after both draws.
        // Observer/parallel scratch() remains the conservative model.
        let cloud:UInt64=0
        // First sublayer prepares directly into sampler planes; only
        // two remaining measured sublayers survive the first draw.
        let layers=scalar*2
        let scratch=layers+scalar*3+cloud
        let particle=rgb*2+scratch
        // After release: input + out. Clump RGB is conditional and its
        // in-place Gaussian uses three scalar scratch planes.
        let micro:UInt64?=microstructure
            ? rgb*3+(microBlur ? scalar*3 : 0) : nil
        // Clump scope has ended; in-place final Gaussian uses three planes.
        let final:UInt64?=finalBlur ? rgb*2+scalar*3 : nil
        return .init(inputBytes:rgb,outputBytes:rgb,layerBytes:layers,
            probabilityBytes:scalar,ratesBytes:scalar,countBytes:scalar,
            cloudBytes:cloud,particlePhaseBytes:particle,
            releasedScratchBytes:scratch,microstructurePhaseBytes:micro,
            finalBlurPhaseBytes:final,
            logicalPeakBytes:max(particle,max(micro ?? 0,final ?? 0)))
    }

    struct Preview {
        let pixels:UInt64
        let additionalBytesPerPixel:UInt64
        let estimatedWithoutFFT:UInt64
        let totalWithFFT:UInt64
        var estimatedMB:Double {Double(totalWithFFT)/1_000_000}
    }
    /// Pure dry-run arithmetic, never allocates the requested giant frame.
    static func preview(width:Int,height:Int,
                        additionalBytesPerPixel:UInt64,
                        fftScratchBytes:UInt64=0) -> Preview? {
        guard width>0,height>0,width<=8192,height<=8192,
              width<=13_000_000/height,
              additionalBytesPerPixel<=4096 else{return nil}
        let pixels=UInt64(width)*UInt64(height)
        let perPixel=baseBytesPerPixel+additionalBytesPerPixel
        let without=pixels*perPixel
        guard without<=UInt64.max-fftScratchBytes else{return nil}
        return Preview(
            pixels:pixels,
            additionalBytesPerPixel:additionalBytesPerPixel,
            estimatedWithoutFFT:without,
            totalWithFFT:without+fftScratchBytes
        )
    }
}
