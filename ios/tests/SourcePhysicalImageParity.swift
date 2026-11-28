import Foundation
import CryptoKit

/// v1.8.22 continuous REAL SOURCE Python physical whole-image evidence.
/// Every reference buffer comes from the imported Python original modules;
/// Swift runs the same product ImageIO ingress, nonlinear film/H-D/scan
/// functions, and original two-dimensional spatial DIR filter.
enum SourcePhysicalImageParity {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }
    private struct Manifest: Decodable {
        struct GrainEvidence: Decodable {
            let scope: String
            let numba_seed: UInt32
            let numba_workers: Int
            let source_blobs: [String:String]
        }
        let scope: String
        let grain: GrainEvidence
        let cases: [Case]
    }
    private struct Case: Decodable {
        let name: String
        let film: String
        let paper: String
        let morph: String
        let width: Int
        let height: Int
        let pixelUM: Double
        let cameraEV: Double
        let paperEV: Double
        let flash: Double
        let flashM: Double
        let flashY: Double
        let shift: [Double]
        let numba_micro_enabled: Bool
        let sha256: [String: String]
    }

    static let stages = [
        "logRaw","initial","inhibitors","diffused",
        "correctedLog","density","printed"
    ]
    private static func read(_ path: URL, sha: String) throws -> Data {
        let data = try Data(contentsOf:path)
        let digest = SHA256.hash(data:data).map {
            String(format:"%02x",$0)
        }.joined()
        guard digest == sha else {
            throw Failure.invalid(
                "Python original image stage SHA256 mismatch " +
                path.lastPathComponent
            )
        }
        return data
    }
    private static func original(
        fixtures: URL, name: String, stage: String,
        checksum: String, width: Int, height: Int,
        channels: Int = 3
    ) throws -> [Double] {
        let bytes=try read(
            fixtures.appendingPathComponent(
                name + "." + stage + ".f64le"
            ),sha:checksum
        )
        let n=width*height*channels
        guard bytes.count == n*8 else {
            throw Failure.invalid(
                "Original Python \(name)/\(stage) not Float64 RGB"
            )
        }
        return bytes.withUnsafeBytes { raw in
            (0..<n).map { k in
                let u=raw.loadUnaligned(
                    fromByteOffset:k*8,as:UInt64.self
                )
                return Double(bitPattern:UInt64(littleEndian:u))
            }
        }
    }

    private struct Metrics {
        let mae: Double
        let rmse: Double
        let maximum: Double
        let worst: Int
        let over: Int
    }
    private static func compare(
        observed: [Double], expected: [Double],
        maxTolerance: Double, maeTolerance: Double, label: String,
        channels: Int = 3
    ) throws -> Metrics {
        guard observed.count == expected.count,
              !expected.isEmpty else {
            throw Failure.invalid(label + ": pixel buffer length differs")
        }
        var error=0.0, squared=0.0, maximum=0.0
        var worst=0,over=0
        for i in expected.indices {
            guard observed[i].isFinite && expected[i].isFinite else {
                throw Failure.invalid(label + ": NaN/Inf at \(i)")
            }
            let d=abs(observed[i]-expected[i])
            error+=d;squared+=d*d
            if d>maximum { maximum=d;worst=i }
            if d>maxTolerance {over+=1}
        }
        let n=Double(expected.count)
        let metrics=Metrics(
            mae:error/n,rmse:sqrt(squared/n),
            maximum:maximum,worst:worst,over:over
        )
        print(
            "\(label) n=\(expected.count) MAE=\(metrics.mae) " +
            "RMSE=\(metrics.rmse) max=\(metrics.maximum) " +
            "worstPixel=\(worst/channels) channel=\(worst%channels) over=\(over)"
        )
        guard over==0,metrics.mae <= maeTolerance else {
            throw Failure.invalid(
                "FAIL original nonlinear Python entire image \(label): " +
                "MAE=\(metrics.mae) RMSE=\(metrics.rmse) " +
                "max=\(metrics.maximum) pixel=\(worst/channels) ch=\(worst%channels). " +
                "Do not promote source image precision."
            )
        }
        return metrics
    }

    // Independent host regression: cold/no-cache vs cache cold and
    // changed downstream hot, including actual seeded grain and both FFT
    // stages. Full-sized A15 residency and time still require device tests.
    private static func verifyFullOpticalDensityCache() throws {
        let w=32,h=25
        let input=(0..<(w*h*3)).map {Double(($0*137+31)%65536)/65535.0}
        var optics=OriginalPrintOptics.Settings(enabled:true)
        optics.normalizePrintExposure=false;optics.printExposureCompensation=false
        var dir=SpatialDIRSettings(enabled:true)
        dir.sourceConvolutionEnabled=true
        var cfg=OriginalSourcePhysicalImage.Parameters(filmID:"kodak_portra_400",
            paperID:"kodak_portra_endura",cameraEV:0,paperEV:0,dir:dir,print:optics,morph:.init())
        cfg.cameraInputColorSpace = .acesLinear
        cfg.enableFullOpticalDensityCache=true
        cfg.cameraOptics.metering = .average
        cfg.cameraOptics.diffusion.active=true
        cfg.cameraOptics.lensBlurUM=5
        cfg.cameraOptics.boostEV=0.1
        cfg.filmHalation.active=true
        cfg.printDiffusion.active=true
        cfg.sourceGrain.active=true
        cfg.sourceGrain.sublayersActive=true
        cfg.sourceGrain.numbaSeed=8888
        cfg.scannerGlare.active=true
        cfg.scannerGlareSeed=8888
        cfg.scannerOptics.lensBlurSigma=0.5
        let frame=OriginalSourcePixelIO.Frame(width:w,height:h,rgb:input)
        func key(_ p:OriginalSourcePhysicalImage.Parameters)throws -> OriginalSourcePhysicalImage.FilmDensityReuse.Key {
            try OriginalSourcePhysicalImage.filmDensityReuseKey(frame:frame,parameters:p,
                allowSeededGrain:true)
        }
        let baseKey=try key(cfg)
        var changes:[(inout OriginalSourcePhysicalImage.Parameters)->Void]=[
            {$0.cameraOptics.metering = .median},
            {$0.cameraOptics.boostEV+=0.1},{$0.cameraOptics.boostRange+=0.1},
            {$0.cameraOptics.protectEV+=1},{$0.cameraOptics.lensBlurUM+=1},
            {$0.cameraOptics.filmFormatMM+=1},{$0.cameraOptics.diffusion.active.toggle()},
            {$0.cameraOptics.diffusion.family = .cinebloom},
            {$0.cameraOptics.diffusion.strength+=0.1},{$0.cameraOptics.diffusion.spatialScale+=0.1},
            {$0.cameraOptics.diffusion.haloWarmth+=0.1},
            {$0.cameraOptics.diffusion.coreIntensity+=0.1},{$0.cameraOptics.diffusion.coreSize+=0.1},
            {$0.cameraOptics.diffusion.haloIntensity+=0.1},{$0.cameraOptics.diffusion.haloSize+=0.1},
            {$0.cameraOptics.diffusion.bloomIntensity+=0.1},{$0.cameraOptics.diffusion.bloomSize+=0.1},
            {$0.filmHalation.active.toggle()},{$0.filmHalation.scatterAmount-=0.1},
            {$0.filmHalation.scatterSpatialScale+=0.1},{$0.filmHalation.halationAmount+=0.1},
            {$0.filmHalation.halationSpatialScale+=0.1},{$0.filmHalation.filmFormatMM+=1},
            {$0.filmHalation.scatterCoreUM[0]+=0.1},{$0.filmHalation.scatterTailUM[0]+=0.1},
            {$0.filmHalation.scatterTailWeight[0]-=0.1},{$0.filmHalation.halationStrength[0]+=0.1},
            {$0.filmHalation.halationFirstSigmaUM[0]+=1},{$0.filmHalation.bounceCount+=1},
            {$0.filmHalation.bounceDecay+=0.1},{$0.filmHalation.renormalize.toggle()}
        ]
        for change in changes {
            var other=cfg;change(&other)
            let otherKey=try key(other)
            precondition(otherKey != baseKey,"Build156 upstream change must miss")
        }
        let count=changes.count
        changes.removeAll()
        var downstream=cfg
        downstream.sourceOutputCCTFEncoding=false
        downstream.printDiffusion.strength+=0.1
        downstream.scannerOptics.lensBlurSigma+=0.1
        let downstreamKey=try key(downstream)
        precondition(downstreamKey==baseKey)
        let session=OriginalSourcePhysicalImage.FilmDensityReuse()
        defer {session.clear()}
        for (params,hot) in [(cfg,false),(downstream,true)] {
            var expected=frame,actual=frame
            try OriginalSourcePhysicalImage.developInPlace(&expected,parameters:params)
            var phases=[String]()
            let lease=session.lease()
            // Diagnostic shared input is not the independently owned hot
            // production snapshot, so no committed cache credit claimed.
            try OriginalSourcePhysicalImage.developInPlace(&actual,parameters:params,
                phaseMemoryObserver:{phases.append($0)},filmDensityReuse:session,
                filmDensityReuseLease:lease,allowSeededGrainDensityReuse:true)
            precondition(expected.rgb.map{$0.bitPattern}==actual.rgb.map{$0.bitPattern})
            precondition(phases.contains("film_density_cache_hit")==hot)
            precondition(phases.contains("camera_diffusion_ready") != hot)
            precondition(phases.contains("paper_diffusion_ready"))
            precondition(phases.contains("three_sublayer_grain_ready"))
        }
        var expected=frame
        try OriginalSourcePhysicalImage.developInPlace(&expected,parameters:downstream)
        var consumed=OriginalSourcePixelIO.Frame(width:w,height:h,rgb:input.map{$0})
        let lease=session.lease()
        precondition(session.takeMatchingDensity(baseKey,expectedGeneration:lease &+ 1)==nil)
        var consumePhases=[String]()
        try OriginalSourcePhysicalImage.developInPlace(&consumed,parameters:downstream,
            phaseMemoryObserver:{consumePhases.append($0)},filmDensityReuse:session,
            filmDensityReuseLease:lease,allowSeededGrainDensityReuse:true,
            consumeExistingFilmDensity:true)
        precondition(consumed.rgb.map{$0.bitPattern}==expected.rgb.map{$0.bitPattern})
        precondition(consumePhases.contains("export_density_cache_consumed"))
        precondition(!session.hasEntry(expectedGeneration:session.lease()))
        precondition(!consumePhases.contains("camera_diffusion_ready") && consumePhases.contains("three_sublayer_grain_ready") && consumePhases.contains("paper_diffusion_ready"))
        print("PASS Build156 full optical cache cold/hot bitwise, \(count) upstream key mutations; one-shot consumed export bitwise")
    }

    static func evaluate(
        fixtures: URL,
        onBuild103StageMetric: ((Build103VerificationEvidence.StageMetric) -> Void)? = nil
    ) throws {
        // Build137 regression: run bit-exact prepared scanner and source
        // exposure gates whenever the real Python physical tapes are checked.
        try SpectralPhysics.verifyPreparedScannerSamples()
        try SpectralPhysics.verifySpectralSIMD()
        try SpectralPhysics.verifyPreparedMeasuredHD()
        try SpectralPhysics.verifyPreparedCameraMultiplier()
        try verifyFullOpticalDensityCache()
        let doc=try Data(
            contentsOf:fixtures.appendingPathComponent("manifest.json")
        )
        let manifest=try JSONDecoder().decode(Manifest.self,from:doc)
        guard manifest.scope ==
              "original-source-nonlinear-hanatos-spatial-dir-paper-aces-8bit",
              manifest.cases.count==4,
              manifest.grain.numba_seed==8888,
              manifest.grain.numba_workers==1,
              manifest.grain.source_blobs["model/grain.py"] ==
                  "f2d2b23e3eab4f4a1d919f69bcb4aceb714e024d",
              manifest.grain.scope.contains("original optical paper RGB")
              else {
            throw Failure.invalid("Wrong Python original physical fixture scope")
        }
        var total=0
        var checkedProductionGlare=false
        var checkedProductionGrain=false
        var checkedProductionPaperStages=false
        var activeMicroCases=0
        var inactiveMicroSeedFreeCases=0
        var activeMicroMissingSeedRejectedCases=0
        var fullGrainRGBChannels=0
        for fixture in manifest.cases {
            guard fixture.width>0 && fixture.height>0,
                  fixture.width<=8192,fixture.height<=8192,
                  fixture.width<=OriginalSourcePhysicalImage.maximumPixels /
                      fixture.height,
                  fixture.shift.count==3,
                  let pngSHA=fixture.sha256["png"] else {
                throw Failure.invalid("Invalid source Python image manifest")
            }
            let png=try read(
                fixtures.appendingPathComponent(fixture.name+".png"),
                sha:pngSHA
            )
            let frame=try OriginalSourcePixelIO.decode(
                png,
                maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
            )
            guard frame.width==fixture.width,
                  frame.height==fixture.height else {
                throw Failure.invalid(
                    "ImageIO source orientation mismatch " + fixture.name
                )
            }
            var optical=OriginalPrintOptics.Settings(enabled:true)
            optical.normalizePrintExposure=false
            optical.printExposureCompensation=false
            optical.cyanShift=fixture.shift[0]
            optical.magentaShift=fixture.shift[1]
            optical.yellowShift=fixture.shift[2]
            optical.preflashExposure=fixture.flash
            optical.preflashMagentaShift=fixture.flashM
            optical.preflashYellowShift=fixture.flashY
            var morph=OriginalPrintMorph.Settings()
            switch fixture.morph {
            case "neutral": break
            case "gamma_082": morph.gamma=0.82
            case "exhaustion_04": morph.developerExhaustion=0.4
            default:throw Failure.invalid("Unknown source paper curve morph")
            }
            var dir=SpatialDIRSettings(enabled:true)
            dir.diffusionRadiusScale=1.0
            dir.tailWeight=0.06
            dir.referencePixelSizeUM=fixture.pixelUM
            dir.sourceConvolutionEnabled=true
            let params=OriginalSourcePhysicalImage.Parameters(
                filmID:fixture.film,paperID:fixture.paper,
                cameraEV:fixture.cameraEV,paperEV:fixture.paperEV,
                dir:dir,print:optical,morph:morph
            )
            var traces=[String:[Double]]()
            let actual=try OriginalSourcePhysicalImage.develop(
                frame,parameters:params,
                stageDoubleObserver: { stage,pixels in
                    traces[stage]=pixels
                }
            )
            // Independent full-chain serial/parallel candidate comparison.
            // No diagnostic observer is shared by threads, no RNG changed.
            var parallel=params
            parallel.deterministicPixelWorkers=4
            let parallelFrame=try OriginalSourcePhysicalImage.develop(frame,parameters:parallel)
            guard parallelFrame.rgb.map({$0.bitPattern})==actual.rgb.map({$0.bitPattern}) else {
                throw Failure.invalid("OPT deterministic parallel image bit mismatch "+fixture.name)
            }
            // Local experimental no-grain density reuse: compare cold
            // split and hot downstream-only path with original fused math.
            if !SpectralPhysics.isPositiveFilm(params.filmID) {
                let session=OriginalSourcePhysicalImage.FilmDensityReuse()
                var cold=frame
                var coldPhases=[String]()
                try OriginalSourcePhysicalImage.developInPlace(&cold,parameters:params,
                    phaseMemoryObserver:{coldPhases.append($0)},filmDensityReuse:session)
                guard coldPhases.contains("film_density_cache_stored"),
                      cold.rgb.map({$0.bitPattern})==actual.rgb.map({$0.bitPattern}) else {
                    throw Failure.invalid("OPT film density cold split bit mismatch "+fixture.name)
                }
                let downstream=OriginalSourcePhysicalImage.Parameters(
                    filmID:params.filmID,paperID:params.paperID,cameraEV:params.cameraEV,
                    paperEV:params.paperEV>3.8 ? params.paperEV-0.125 : params.paperEV+0.125,
                    dir:params.dir,print:params.print,morph:params.morph)
                let expected=try OriginalSourcePhysicalImage.develop(frame,parameters:downstream)
                var hot=frame
                var hotPhases=[String]()
                try OriginalSourcePhysicalImage.developInPlace(&hot,parameters:downstream,
                    phaseMemoryObserver:{hotPhases.append($0)},filmDensityReuse:session)
                guard hotPhases.contains("film_density_cache_hit"),
                      !hotPhases.contains("camera_photons_ready"),
                      hot.rgb.map({$0.bitPattern})==expected.rgb.map({$0.bitPattern}) else {
                    throw Failure.invalid("OPT film density hot downstream bit mismatch "+fixture.name)
                }
                var changed=frame
                changed.rgb[0]+=0.001
                var missPhases=[String]()
                let changedExpected=try OriginalSourcePhysicalImage.develop(changed,parameters:downstream)
                try OriginalSourcePhysicalImage.developInPlace(&changed,parameters:downstream,
                    phaseMemoryObserver:{missPhases.append($0)},filmDensityReuse:session)
                guard missPhases.contains("film_density_cache_miss"),
                      changed.rgb.map({$0.bitPattern})==changedExpected.rgb.map({$0.bitPattern}) else {
                    throw Failure.invalid("OPT film density input invalidation mismatch "+fixture.name)
                }
                session.clear()
                var invalidated=frame
                var invalidatedPhases=[String]()
                try OriginalSourcePhysicalImage.developInPlace(&invalidated,parameters:params,
                    phaseMemoryObserver:{phase in
                        invalidatedPhases.append(phase)
                        if phase=="film_density_ready_DIR_released" {session.clear()}
                    },filmDensityReuse:session)
                guard invalidatedPhases.contains("film_density_cache_store_invalidated"),
                      !invalidatedPhases.contains("film_density_cache_stored"),
                      invalidated.rgb.map({$0.bitPattern})==actual.rgb.map({$0.bitPattern}) else {
                    throw Failure.invalid("OPT film density stale store mismatch "+fixture.name)
                }
                // Clear BEFORE the optical renderer starts, e.g. during
                // an input decode. The old lease must not refill the cache.
                let staleLease=session.lease()
                session.clear()
                var stale=frame
                var stalePhases=[String]()
                try OriginalSourcePhysicalImage.developInPlace(&stale,parameters:params,
                    phaseMemoryObserver:{stalePhases.append($0)},filmDensityReuse:session,
                    filmDensityReuseLease:staleLease)
                guard stalePhases.contains("film_density_cache_store_invalidated"),
                      !stalePhases.contains("film_density_cache_stored"),
                      stale.rgb.map({$0.bitPattern})==actual.rgb.map({$0.bitPattern}) else {
                    throw Failure.invalid("OPT film density pre-render stale lease mismatch "+fixture.name)
                }
                var rebuilt=frame
                var rebuiltPhases=[String]()
                try OriginalSourcePhysicalImage.developInPlace(&rebuilt,parameters:params,
                    phaseMemoryObserver:{rebuiltPhases.append($0)},filmDensityReuse:session)
                guard rebuiltPhases.contains("film_density_cache_miss"),
                      rebuiltPhases.contains("film_density_cache_stored") else {
                    throw Failure.invalid("OPT film density invalidated generation reused "+fixture.name)
                }
            }
            // Build77/02: compare the ACTUAL production pre-photon
            // input against ORIGINAL Python SimulationPipeline._preprocess
            // for the explicitly supported sRGB/CCTF, no crop/resize case.
            // This is not a claim of default ProPhoto or RAW correctness.
            guard let identity=traces["rgbPre"],identity == frame.rgb else {
                throw Failure.invalid(
                    "Build77 no-meter/no-crop source rgb_pre must be identity"
                )
            }
            if fixture.name == "kodak_neutral_fir" {
                guard let expectedSHA=fixture.sha256["rgbPre"] else {
                    throw Failure.invalid(
                        "Missing independent Python _preprocess reference"
                    )
                }
                let expectedPre=try original(
                    fixtures:fixtures,name:fixture.name,stage:"rgbPre",
                    checksum:expectedSHA,width:fixture.width,
                    height:fixture.height
                )
                var metered=params
                metered.cameraOptics.metering = .centerWeighted
                var meteredTrace=[String:[Double]]()
                let meteredImage=try OriginalSourcePhysicalImage.develop(
                    frame,parameters:metered,
                    stageDoubleObserver:{key,values in
                        meteredTrace[key]=values
                    }
                )
                let noObserver=try OriginalSourcePhysicalImage.develop(
                    frame,parameters:metered
                )
                guard meteredImage.rgb == noObserver.rgb,
                      let actualPre=meteredTrace["rgbPre"],
                      let meter=meteredTrace["cameraAutoExposureEV"],
                      meter.count==1 && meter[0].isFinite,
                      actualPre.count==frame.rgb.count else {
                    throw Failure.invalid(
                        "Build77 production rgb_pre missing or changes output"
                    )
                }
                let preMetrics=try compare(
                    observed:actualPre,expected:expectedPre,
                    maxTolerance:5e-11,maeTolerance:1e-11,
                    label:"Build77 true Python _preprocess sRGB/no-resize"
                )
                print("PASS Build77 real Python rgb_pre vs production "
                      + "center-weighted source input: "
                      + "\(actualPre.count) Float64 channels, "
                      + "max=\(preMetrics.maximum), "
                      + "observer-off output bit-exact")
            }
            // Build77/02: verify source NORMAL print branch also gives
            // the actual Python PrintingStage log-exposure and developed
            // CMY density, before scanning; not a post-RGB reconstruction.
            if !SpectralPhysics.isPositiveFilm(fixture.film) {
                guard let paperLog=traces["paperLogExposure"],
                      let paperDensity=traces["paperDevelopedDensity"],
                      let filmDensity=traces["density"],
                      paperLog.count == frame.rgb.count,
                      paperDensity.count == frame.rgb.count,
                      filmDensity.count == frame.rgb.count else {
                    throw Failure.invalid(
                        "Build77 missing real normal-branch paper stages"
                    )
                }
                let engine=try params.createEngine()
                for offset in stride(from:0,to:frame.rgb.count,by:3) {
                    var sourceLog=[Double]()
                    var sourceDensity=[Double]()
                    let final=try engine.sourceSpatialScan(
                        filmDensity:Array(filmDensity[offset..<(offset+3)]),
                        paperEV:fixture.paperEV,
                        paperStageObserver: { log,density in
                            sourceLog=log
                            sourceDensity=density
                        }
                    )
                    guard sourceLog.count==3,sourceDensity.count==3 else {
                        throw Failure.invalid("Build77 source normal callback absent")
                    }
                    for c in 0..<3 {
                        guard paperLog[offset+c].bitPattern ==
                                sourceLog[c].bitPattern,
                              paperDensity[offset+c].bitPattern ==
                                sourceDensity[c].bitPattern,
                              final[c].bitPattern ==
                                actual.rgb[offset+c].bitPattern else {
                            throw Failure.invalid(
                                "Build77 normal source paper tap drift at "
                                + "pixel=\(offset/3) ch=\(c)"
                            )
                        }
                    }
                }
                print("PASS Build77 normal original print log_e_print/"
                      + "cmy_print storage, all \((frame.rgb.count)) "
                      + "Double channels preserved; source-scanner RGB "
                      + "remains bit-exact")
            } else {
                guard traces["paperLogExposure"] == nil,
                      traces["paperDevelopedDensity"] == nil else {
                    throw Failure.invalid("Direct film scan acquired false paper taps")
                }
            }
            for stage in stages {
                guard let expectedSHA=fixture.sha256[stage],
                      let observed=traces[stage] else {
                    throw Failure.invalid(
                        "Missing Python or production stage " +
                        fixture.name + " " + stage
                    )
                }
                let originalData=try original(
                    fixtures:fixtures,name:fixture.name,stage:stage,
                    checksum:expectedSHA,width:fixture.width,
                    height:fixture.height
                )
                let outputTolerance:Double=stage=="printed" ? 0.002 : 0.002
                let meanTolerance:Double=stage=="printed" ? 0.0005 : 0.0003
                let stageMetrics = try compare(
                    observed:observed,expected:originalData,
                    maxTolerance:outputTolerance,
                    maeTolerance:meanTolerance,
                    label:fixture.name + "/" + stage
                )
                onBuild103StageMetric?(Build103VerificationEvidence.StageMetric(
                    caseName:fixture.name,stageName:stage,
                    channelCount:observed.count,
                    mae:stageMetrics.mae,rmse:stageMetrics.rmse,
                    maximumAbsoluteError:stageMetrics.maximum,
                    worstPixel:stageMetrics.worst/3,
                    worstChannel:stageMetrics.worst%3,
                    overMaximumTolerance:stageMetrics.over,
                    maximumTolerance:outputTolerance,
                    maeTolerance:meanTolerance,
                    expectedPythonStageSHA256:expectedSHA
                ))
                if stage=="printed" {
                    guard actual.rgb == observed else {
                        throw Failure.invalid(
                            "Diagnostic output differs from production pixel output"
                        )
                    }
                }
            }
            // v1.8.46: exercise actual production developInPlace on an
            // original 2D negative image, not just the isolated glare
            // module from v1.8.45. Never alter the no-glare fixture.
            if !checkedProductionGlare &&
               !SpectralPhysics.isPositiveFilm(fixture.film) {
                var experimental=params
                experimental.scannerGlare = .init(
                    active:true,percent:0.03,roughness:0.7,blur:0.5
                )
                experimental.scannerGlareSeed=8888
                var glareTraces=[String:[Double]]()
                let glared=try OriginalSourcePhysicalImage.develop(
                    frame,parameters:experimental,
                    stageDoubleObserver: { stage,pixels in
                        glareTraces[stage]=pixels
                    }
                )
                let repeated=try OriginalSourcePhysicalImage.develop(
                    frame,parameters:experimental
                )
                guard glared.rgb==repeated.rgb, glared.rgb != actual.rgb,
                      let observedXYZ=glareTraces["scannerGlareXYZ"],
                      let observedLinear=glareTraces["scannerGlareLinearRGB"],
                      let observedDensity=traces["density"],
                      observedXYZ.count==fixture.width*fixture.height*3,
                      observedLinear.count==observedXYZ.count else {
                    throw Failure.invalid(
                        "Original source glare production did not run or seeded output was nondeterministic"
                    )
                }
                let engine=try experimental.createEngine()
                let lamp=try engine.sourceSpatialScannerIlluminantXYZ()
                let field=try OriginalSourceScannerGlare.computeAmount(
                    width:fixture.width,height:fixture.height,
                    settings:experimental.scannerGlare,
                    controlledSeed:experimental.scannerGlareSeed
                )
                var maxXYZ=0.0,maxLinear=0.0,maxEncoded=0.0
                for pixel in 0..<(fixture.width*fixture.height) {
                    let k=pixel*3
                    let paperXYZ=try engine.sourceSpatialScanXYZ(
                        filmDensity:Array(observedDensity[k..<(k+3)]),
                        paperEV:fixture.paperEV
                    )
                    let expectedXYZ=(0..<3).map {
                        paperXYZ[$0]+field[pixel]*lamp[$0]
                    }
                    let expectedLinear=try engine.sourceSpatialXYZToLinearRGB(
                        expectedXYZ
                    )
                    // Original Python colour.RGB_to_RGB(sRGB,sRGB,
                    // decoding=false,encoding=true) is a non-identity
                    // Float64 3x3 pass followed by sRGB CCTF.
                    // A scalar encodeSRGB() skips that stage, producing
                    // false "wrong stage order" results on real iPhones.
                    let expectedEncoded=OriginalScannerMath.sourceCCTFEncoding(
                        expectedLinear
                    )
                    for ch in 0..<3 {
                        let deltaXYZ=abs(observedXYZ[k+ch]-expectedXYZ[ch])
                        let deltaLinear=abs(observedLinear[k+ch]-expectedLinear[ch])
                        let deltaEncoded=abs(
                            glared.rgb[k+ch]-expectedEncoded[ch]
                        )
                        maxXYZ=max(maxXYZ,deltaXYZ)
                        maxLinear=max(maxLinear,deltaLinear)
                        maxEncoded=max(maxEncoded,deltaEncoded)
                        guard deltaXYZ<1e-11,deltaLinear<1e-11,
                              deltaEncoded<1e-11 else {
                            throw Failure.invalid(
                                "Production scanner glare wrong stage order " +
                                "p=\(pixel) c=\(ch) XYZ=\(deltaXYZ) " +
                                "linear=\(deltaLinear) encoded=\(deltaEncoded)"
                            )
                        }
                    }
                }
                var withoutSeed=experimental
                withoutSeed.scannerGlareSeed=nil
                do {
                    _=try OriginalSourcePhysicalImage.develop(
                        frame,parameters:withoutSeed
                    )
                    throw Failure.invalid("Source scanner glare accepted implicit random seed")
                } catch OriginalSourcePhysicalImage.Failure.invalid {}
                checkedProductionGlare=true
                print(
                    "PASS v1.8.46 production 2D source glare " +
                    "paperXYZ→glareXYZ→ACESlinear→sRGB, " +
                    "\(observedXYZ.count) XYZ channels max=\(maxXYZ), " +
                    "linearMax=\(maxLinear), sRGBMax=\(maxEncoded); " +
                    "seed reproducible, seed-missing rejection PASS"
                )
            }
            // v1.8.48: TRUE production H-D/DIR→9 SciPy sublayer grain
            // → source print/scan integration on an existing Python
            // original image fixture; no post-RGB grain is allowed.
            if !SpectralPhysics.isPositiveFilm(fixture.film) {
                var enabled=params
                enabled.sourceGrain.active=true
                enabled.sourceGrain.numbaSeed=8888
                var grainTraces=[String:[Double]]()
                let developed=try OriginalSourcePhysicalImage.develop(
                    frame,parameters:enabled,
                    stageDoubleObserver:{stage,values in
                        grainTraces[stage]=values
                    }
                )
                let repeated=try OriginalSourcePhysicalImage.develop(
                    frame,parameters:enabled
                )
                guard developed.rgb == repeated.rgb,
                      developed.rgb != actual.rgb,
                      let before=grainTraces["density"],
                      let after=grainTraces["grainDensity"],
                      let sourceAfter=grainTraces["sourceGrainFinalDensity"],
                      let dye=grainTraces["sourceGrainDyeClouds"],
                      let micro=grainTraces["sourceGrainMicrostructure"],
                      let sub=grainTraces["sourceGrainSublayers"],
                      before.count==fixture.width*fixture.height*3,
                      after.count==before.count,
                      sourceAfter==after,
                      dye.count==before.count,
                      micro.count==before.count,
                      sub.count==fixture.width*fixture.height*9 else {
                    throw Failure.invalid(
                        "Controlled source 3x3 grain was not integrated at the film density/print boundary"
                    )
                }
                // The same actual Python-reference fixture must match
                // a cold pre-grain cache and a hot render with fresh RNG.
                let grainSession=OriginalSourcePhysicalImage.FilmDensityReuse()
                var grainCold=frame
                var grainColdPhases=[String]()
                try OriginalSourcePhysicalImage.developInPlace(&grainCold,parameters:enabled,
                    phaseMemoryObserver:{grainColdPhases.append($0)},filmDensityReuse:grainSession,
                    allowSeededGrainDensityReuse:true)
                guard grainColdPhases.contains("film_density_cache_stored"),
                      grainColdPhases.contains("three_sublayer_grain_ready"),
                      grainCold.rgb.map({$0.bitPattern})==developed.rgb.map({$0.bitPattern}) else {
                    throw Failure.invalid("OPT pre-grain cold cache changed seeded output")
                }
                var grainChanged=enabled
                grainChanged.sourceGrain.numbaSeed=9999
                grainChanged.sourceGrain.particleScale[0]*=1.125
                let grainReference=try OriginalSourcePhysicalImage.develop(frame,parameters:grainChanged)
                var grainHot=frame
                var grainHotPhases=[String]()
                try OriginalSourcePhysicalImage.developInPlace(&grainHot,parameters:grainChanged,
                    phaseMemoryObserver:{grainHotPhases.append($0)},filmDensityReuse:grainSession,
                    allowSeededGrainDensityReuse:true)
                guard grainHotPhases.contains("film_density_cache_hit"),
                      !grainHotPhases.contains("camera_photons_ready"),
                      grainHotPhases.contains("grain_particle_clouds_ready"),
                      grainHotPhases.contains("three_sublayer_grain_ready"),
                      grainHot.rgb.map({$0.bitPattern})==grainReference.rgb.map({$0.bitPattern}),
                      !OriginalSourcePhysicalImage.canReuseFilmDensity(enabled) else {
                    throw Failure.invalid("OPT pre-grain cache did not preserve fresh seeded RNG")
                }
                grainSession.clear()
                // Independent Python is now RUN on the same entire
                // original image, including original SciPy counts,
                // one-worker Numba microstructure and optical paper RGB.
                // The previous Swift self-loop check below is retained,
                // but it NEVER substitutes for these source comparisons.
                let upstreamStages:[(String,String,Int,Double,Double)] = [
                    ("grainSublayers","sourceGrainSublayers",9,1e-8,1e-10),
                    ("grainDyeClouds","sourceGrainDyeClouds",3,0.002,0.0005),
                    ("grainMicrostructure","sourceGrainMicrostructure",3,0.002,0.0005),
                    ("grainDensity","grainDensity",3,0.002,0.0005),
                    ("grainPrinted","printed",3,0.002,0.0005),
                ]
                for (name,key,channels,maxError,meanError) in upstreamStages {
                    guard let sha=fixture.sha256[name],
                          let observed=grainTraces[key] else {
                        throw Failure.invalid(
                            "Missing independent Python grain full RGB " +
                            fixture.name + "/" + name
                        )
                    }
                    let truth=try original(
                        fixtures:fixtures,name:fixture.name,stage:name,
                        checksum:sha,width:fixture.width,
                        height:fixture.height,channels:channels
                    )
                    _ = try compare(
                        observed:observed,expected:truth,
                        maxTolerance:maxError,maeTolerance:meanError,
                        label:fixture.name+"/upstream/"+name,
                        channels:channels
                    )
                }
                guard fixture.numba_micro_enabled ==
                      (enabled.sourceGrain.microstructureNM * 0.001 /
                       fixture.pixelUM > 0.05) else {
                    throw Failure.invalid(
                        "Python/Swift actual Numba microstructure gate mismatch"
                    )
                }
                if fixture.numba_micro_enabled {activeMicroCases+=1}
                fullGrainRGBChannels += developed.rgb.count

                // The new production buffer after grain must be passed to
                // the SAME original full optical enlarger/paper/scanner,
                // not an RGB postprocessing blur or a colour cube.
                let film=try enabled.createEngine()
                var worst=0.0
                for p in 0..<(fixture.width*fixture.height) {
                    let k=p*3
                    let expected=try film.sourceSpatialScan(
                        filmDensity:[after[k],after[k+1],after[k+2]],
                        paperEV:fixture.paperEV
                    )
                    for ch in 0..<3 {
                        let delta=abs(expected[ch]-developed.rgb[k+ch])
                        worst=max(worst,delta)
                        guard delta < 1e-11 else {
                            throw Failure.invalid(
                                "Source original grain not placed BEFORE real optical print scanner"
                            )
                        }
                    }
                }
                var denied=enabled
                denied.sourceGrain.numbaSeed=nil
                // The unmodified Python grain.py does NOT call Numba
                // lognormal when microNM * 0.001 / pixelUM <= 0.05.
                // Build103 used to demand a seed even for that legal
                // no-draw branch: it stopped after the first 7 metrics.
                if fixture.numba_micro_enabled {
                    do {
                        _=try OriginalSourcePhysicalImage.develop(
                            frame,parameters:denied
                        )
                        throw Failure.invalid(
                            "Source physical grain accepted implicit unseeded Numba"
                        )
                    } catch OriginalSourcePhysicalGrain.Failure.invalid {}
                    activeMicroMissingSeedRejectedCases+=1
                } else {
                    // For inactive microstructure, SciPy nine-layer
                    // sampling is seeded independently. A missing Numba
                    // microstructure seed must NOT change a single RGB bit.
                    let seedFree=try OriginalSourcePhysicalImage.develop(
                        frame,parameters:denied
                    )
                    guard seedFree.rgb == developed.rgb else {
                        throw Failure.invalid(
                            "Inactive original microstructure unexpectedly depends on Numba seed"
                        )
                    }
                    inactiveMicroSeedFreeCases+=1
                }
                checkedProductionGrain=true
                print(
                    "PASS original full physical grain " +
                    "9 SciPy layers→dye cloud→conditionally Numba micro→FIR/YVV" +
                    "→original enlarger/paper/scanner; " +
                    "\(after.count) CMY channels, source-order " +
                    "optical RGB discrepancy max=\(worst); " +
                    (fixture.numba_micro_enabled
                        ? "active microstructure missing seed rejected"
                        : "inactive microstructure seed-free output bit-exact")
                )
            }
            // Build77 02: ACTUAL 2D optical print production must expose
            // paper raw-photon→log exposure→H-D without recomputation or
            // modifying final rendered RGB. This is scoped to the active
            // original print-diffusion branch, not generic seven-tap parity.
            if !SpectralPhysics.isPositiveFilm(fixture.film) &&
                !checkedProductionPaperStages {
                var paperParams=params
                paperParams.printDiffusion.active=true
                paperParams.printDiffusion.strength=0.5
                var paperTraces=[String:[Double]]()
                let withTaps=try OriginalSourcePhysicalImage.develop(
                    frame,parameters:paperParams,
                    stageDoubleObserver: { key,values in
                        paperTraces[key]=values
                    }
                )
                let withoutTaps=try OriginalSourcePhysicalImage.develop(
                    frame,parameters:paperParams
                )
                var parallelScan=frame
                try OriginalSourcePhysicalImage.developInPlace(&parallelScan,
                    parameters:paperParams,postDiffusionScanWorkers:2)
                guard parallelScan.rgb.map({$0.bitPattern}) == withoutTaps.rgb.map({$0.bitPattern}) else {
                    throw Failure.invalid("Build159 independent post-diffusion scan workers differ")
                }
                var parallelHD=frame
                try OriginalSourcePhysicalImage.developInPlace(&parallelHD,
                    parameters:paperParams,postDiffusionScanWorkers:2,compactPixelWorkers:2)
                guard parallelHD.rgb.map({$0.bitPattern}) == withoutTaps.rgb.map({$0.bitPattern}) else {
                    throw Failure.invalid("Build160 compact initial/corrected H-D workers differ")
                }
                let count=fixture.width*fixture.height*3
                guard withTaps.rgb == withoutTaps.rgb,
                      let raw=paperTraces["printDiffusion"],
                      let log=paperTraces["paperLogExposure"],
                      let density=paperTraces["paperDevelopedDensity"],
                      raw.count==count,log.count==count,density.count==count
                else {
                    throw Failure.invalid(
                        "Build77 source print stages missing or changed pixel RGB"
                    )
                }
                let engine=try paperParams.createEngine()
                for k in stride(from:0,to:count,by:3) {
                    let photon=[raw[k],raw[k+1],raw[k+2]]
                    var returnedLog=[Double]()
                    var returnedDensity=[Double]()
                    let output=try engine.sourceSpatialScanPrintedPhoton(
                        photon,
                        paperStageObserver:{ values,valuesDensity in
                            returnedLog=values
                            returnedDensity=valuesDensity
                        }
                    )
                    guard returnedLog.count==3,
                          returnedDensity.count==3 else {
                        throw Failure.invalid("Build77 print callback missing")
                    }
                    for c in 0..<3 {
                        let expectedLog=log10(max(0,photon[c])+1e-10)
                        guard log[k+c].bitPattern==expectedLog.bitPattern,
                              returnedLog[c].bitPattern==log[k+c].bitPattern,
                              returnedDensity[c].bitPattern==density[k+c].bitPattern,
                              output[c].bitPattern==withTaps.rgb[k+c].bitPattern
                        else {
                            throw Failure.invalid(
                                "Build77 actual paper tap drift at k=\(k) c=\(c)"
                            )
                        }
                    }
                }
                checkedProductionPaperStages=true
                print("PASS Build77 paper source photon→actual log exposure→"
                      + "original H-D→scan output; \(count) channels; "
                      + "stage observer bit-exact, final RGB unchanged")
            }
            total+=fixture.width*fixture.height*3
            print("PASS original nonlinear whole-frame stock " +
                  fixture.film + " → " + fixture.paper)
        }
        guard checkedProductionPaperStages else {
            throw Failure.invalid("No production print-diffusion source stage evidence")
        }
        guard checkedProductionGlare else {
            throw Failure.invalid("No negative print fixture exercised source production scanner glare")
        }
        guard checkedProductionGrain,
              activeMicroCases==1,
              inactiveMicroSeedFreeCases==3,
              activeMicroMissingSeedRejectedCases==1,
              fullGrainRGBChannels > 0 else {
            throw Failure.invalid(
                "Missing full independent Python grain+paper RGB image " +
                "with ACTUALLY ACTIVE Numba microstructure"
            )
        }
        print(
            "PASS original Python→Swift full 2D grain+optical RGB " +
            "\(fullGrainRGBChannels) channels, four upstream source " +
            "image fixtures, active-micro cases \(activeMicroCases), " +
            "inactive seed-free \(inactiveMicroSeedFreeCases), " +
            "active seed rejection \(activeMicroMissingSeedRejectedCases); " +
            "strict fail-closed, no fast LUT fallback"
        )
        // Explicit memory guard: cannot silently scale the image, nor
        // downgrade to a Float32 optical 3D LUT when original is requested.
        let tooLarge=OriginalSourcePixelIO.Frame(
            width:4096,height:4096,rgb:[]
        )
        var rejected=false
        do {
            let fixture=manifest.cases[0]
            var dir=SpatialDIRSettings(enabled:true)
            dir.sourceConvolutionEnabled=true
            let p=OriginalSourcePhysicalImage.Parameters(
                filmID:fixture.film,paperID:fixture.paper,
                cameraEV:0,paperEV:0,dir:dir,
                print:OriginalPrintOptics.Settings(enabled:true),
                morph:OriginalPrintMorph.Settings()
            )
            _ = try OriginalSourcePhysicalImage.develop(
                tooLarge,parameters:p
            )
        } catch OriginalSourcePhysicalImage.Failure.invalid(let message) {
            rejected=message.contains("1300 万像素")
        }
        guard rejected else {
            throw Failure.invalid("Oversize physical image failed to reject")
        }
        // iPhone 13-class 10MP photo: admission is now based on TRUE
        // current physical/process budget, not the old fixed 2MP cap.
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:3888,height:2592,
            physicalMemory:4_500_000_000,
            processAvailableMemory:3_140_000_000
        )
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:3888,height:2592,maximumAllowedPixels:
                OriginalSourcePhysicalImage.maximumPixels
        )
        var budgetDenied=false
        do {
            try OriginalSourcePhysicalImage.validateMemoryBudget(
                width:3888,height:2592,
                physicalMemory:3_000_000_000,
                processAvailableMemory:500_000_000
            )
        } catch Build91PhysicalMemory.Failure.invalid(let reason) {
            budgetDenied=reason.contains("内存预算不足") &&
                reason.contains("不会自动缩图")
        }
        guard budgetDenied else {
            throw Failure.invalid(
                "Physical full-res output did not reject insufficient memory"
            )
        }
        // 4032x3024 is 12,192,768 pixels. The old 12MP gate blocked it
        // before estimating memory; v1.8.49 admits its source GEOMETRY.
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:4032,height:3024,
            maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
        )
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:4032,height:3024,
            physicalMemory:6_000_000_000,
            processAvailableMemory:3_000_000_000
        )
        // Geometry acceptance is NOT a memory promise: controlled grain
        // adds 272 bytes/pixel. Refuse a 12MP full-res render on A15.
        var grainMemoryDenied=false
        do {
            try OriginalSourcePhysicalImage.validateMemoryBudget(
                width:4032,height:3024,
                additionalBytesPerPixel:OriginalSourcePhysicalGrain.extraBytesPerPixel,
                physicalMemory:4_000_000_000,
                processAvailableMemory:1_000_000_000
            )
        } catch Build91PhysicalMemory.Failure.invalid(let reason) {
            grainMemoryDenied=reason.contains("内存预算不足")
        }
        guard grainMemoryDenied else {
            throw Failure.invalid("Large 12.19MP grain was incorrectly promised on A15")
        }
        // An explicitly confirmed 1600x1200 safe/economy export keeps ALL
        // physical density and grain stages in the same algorithm path.
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:1600,height:1200,
            additionalBytesPerPixel:OriginalSourcePhysicalGrain.extraBytesPerPixel,
            physicalMemory:4_000_000_000,
            processAvailableMemory:1_200_000_000
        )
        var over13MPDenied=false
        do {
            try OriginalSourcePixelIO.validatePixelDimensions(
                width:4000,height:3300,
                maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
            )
        } catch OriginalSourcePixelIO.Failure.invalid(let reason) {
            over13MPDenied=reason.contains("1300 万像素") &&
                reason.contains("逐像素全光学")
        }
        guard over13MPDenied else {
            throw Failure.invalid("Physical 13MP dimension guard was lost")
        }
        print("PASS: original Python nonlinear full image → Swift " +
              "Hanatos/H-D/spatial DIR/s023 paper/scan: " +
              "\(total) RGB channels across seven stages for 3 frames." +
              " Original 10MP-class input conditionally admitted under " +
              "verified simulated memory headroom; 13MP upper guard, " +
              "no fallback under low memory. NOT physical iPhone-certified.")
    }
}
