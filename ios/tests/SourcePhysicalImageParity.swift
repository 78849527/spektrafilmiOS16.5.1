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

    static func evaluate(fixtures: URL) throws {
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
        var activeMicroCases=0
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
                _ = try compare(
                    observed:observed,expected:originalData,
                    maxTolerance:outputTolerance,
                    maeTolerance:meanTolerance,
                    label:fixture.name + "/" + stage
                )
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
                    for ch in 0..<3 {
                        let deltaXYZ=abs(observedXYZ[k+ch]-expectedXYZ[ch])
                        let deltaLinear=abs(observedLinear[k+ch]-expectedLinear[ch])
                        let expectedEncoded=OriginalScannerMath.encodeSRGB(
                            expectedLinear[ch]
                        )
                        let deltaEncoded=abs(glared.rgb[k+ch]-expectedEncoded)
                        maxXYZ=max(maxXYZ,deltaXYZ)
                        maxLinear=max(maxLinear,deltaLinear)
                        maxEncoded=max(maxEncoded,deltaEncoded)
                        guard deltaXYZ<1e-11,deltaLinear<1e-11,
                              deltaEncoded<1e-11 else {
                            throw Failure.invalid(
                                "Production scanner glare wrong stage order " +
                                "p=\\(pixel) c=\\(ch) XYZ=\\(deltaXYZ) " +
                                "linear=\\(deltaLinear) encoded=\\(deltaEncoded)"
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
                    "\\(observedXYZ.count) XYZ channels max=\\(maxXYZ), " +
                    "linearMax=\\(maxLinear), sRGBMax=\\(maxEncoded); " +
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
                // Independent Python is now RUN on the same entire
                // original image, including original SciPy counts,
                // one-worker Numba microstructure and optical paper RGB.
                // The previous Swift self-loop check below is retained,
                // but it NEVER substitutes for these source comparisons.
                let upstreamStages:[(String,String,Int,Double,Double)] = [
                    ("grainSublayers","sourceGrainSublayers",9,0.002,0.0003),
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
                do {
                    _=try OriginalSourcePhysicalImage.develop(
                        frame,parameters:denied
                    )
                    throw Failure.invalid("Source physical grain accepted implicit unseeded Numba")
                } catch OriginalSourcePhysicalGrain.Failure.invalid {}
                checkedProductionGrain=true
                print(
                    "PASS v1.8.50 ACTUAL full physical grain " +
                    "9 SciPy layers→dye cloud→Numba controlled micro→FIR/YVV" +
                    "→original enlarger/paper/scanner; " +
                    "\\(after.count) CMY channels, source-order " +
                    "optical RGB discrepancy max=\\(worst), no seed rejected"
                )
            }
            total+=fixture.width*fixture.height*3
            print("PASS original nonlinear whole-frame stock " +
                  fixture.film + " → " + fixture.paper)
        }
        guard checkedProductionGlare else {
            throw Failure.invalid("No negative print fixture exercised source production scanner glare")
        }
        guard checkedProductionGrain,
              activeMicroCases > 0,fullGrainRGBChannels > 0 else {
            throw Failure.invalid(
                "Missing full independent Python grain+paper RGB image " +
                "with ACTUALLY ACTIVE Numba microstructure"
            )
        }
        print(
            "PASS original Python→Swift full 2D grain+optical RGB " +
            "\(fullGrainRGBChannels) channels, four upstream source " +
            "image fixtures, active-micro cases \(activeMicroCases); " +
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
        } catch OriginalSourcePhysicalImage.Failure.invalid(let reason) {
            budgetDenied=reason.contains("内存预算不足") &&
                reason.contains("不会擅自缩图")
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
        } catch OriginalSourcePhysicalImage.Failure.invalid(let reason) {
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
