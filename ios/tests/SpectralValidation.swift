import Foundation

/// Portable macOS native-physics regression suite built on Xcode 16.4.
/// Tests correctness of stock classification, original Hanatos sensor LUT
/// interpolation, Mallett 2019 reference compatibility, 16x8 negative print
/// combinations and reversal film direct-scanning (without paper).
@main
struct SpectralValidation {
    static func main() throws {
        // v1.8.25: independently certify every source input bit is still
        // original binary64; fast Float32 material bytes remain unchanged.
        try SourceFloat64ProfileValidation.evaluate()
        let all = GeneratedSpectralData.profiles
        let films = SpectralPhysics.supportedFilmIDs
        let media = SpectralPhysics.supportedPaperIDs
        let negatives = GeneratedSpectralData.negativeFilmIDs
        let positives = GeneratedSpectralData.positiveFilmIDs

        precondition(all.count == 28, "All 28 original measured profiles needed")
        for (stock, record) in all {
            guard let mask = Data(base64Encoded: record.scannerValidWavelengths) else {
                preconditionFailure("Missing source scanner mask: " + stock)
            }
            precondition(mask.count == 81 && mask.contains(1) &&
                         mask.allSatisfy({ $0 == 0 || $0 == 1 }),
                         "Invalid source 81-wavelength mask: " + stock)
            guard let baseMask = Data(base64Encoded: record.baseValidWavelengths),
                  let sensitivityMask = Data(base64Encoded: record.sensitivityValidSamples) else {
                preconditionFailure("Missing independent base/sensitivity null masks: " + stock)
            }
            precondition(baseMask.count == 81 && baseMask.contains(1) &&
                         baseMask.allSatisfy({ $0 <= 1 }))
            precondition(sensitivityMask.count == 243 &&
                         sensitivityMask.contains(1) &&
                         sensitivityMask.allSatisfy({ $0 <= 1 }))
            for index in 0..<81 {
                if mask[index] == 1 {
                    precondition(baseMask[index] == 1,
                                 "Scanner-valid wavelength cannot have invalid base")
                }
            }
        }
        for stock in ["fujifilm_provia_100f", "fujifilm_velvia_100"] {
            let mask = Data(base64Encoded: all[stock]!.scannerValidWavelengths)!
            precondition(mask.filter({ $0 == 0 }).count > 10,
                         "Original missing dyes must not become zero density")
        }
        print("PASS: scanner NaN masks for all 28 source profiles.")
        precondition(films.count == 20, "20 original filming stocks needed")
        precondition(negatives.count == 16 && positives.count == 4,
                     "Wrong reversal/negative classification")
        precondition(media.count == 8, "6 papers + 2 movie stocks needed")
        precondition(GeneratedSpectralData.paperIDs.count == 6)
        precondition(GeneratedSpectralData.printFilmIDs.count == 2)
        precondition(Set(films).count == 20 && Set(media).count == 8)

        let samples: [[Double]] = [
            [0.05, 0.05, 0.05],
            [0.46, 0.46, 0.46],
            [0.92, 0.92, 0.92],
            [0.82, 0.14, 0.11],
            [0.12, 0.78, 0.18],
            [0.13, 0.18, 0.86]
        ]
        func check(_ values: [Double], _ label: String) {
            precondition(values.count == 3 && values.allSatisfy {
                $0.isFinite && $0 >= 0 && $0 <= 1
            }, "Nonfinite or OOG output: \(label), \(values)")
        }

        // Original Hanatos2025: source 2D irradiance LUT, original film
        // adaptation window and original reflected Mitchell cubic interpolation.
        let hanatosReferences: [(String, [Double], [Double])] = [
            (GeneratedHanatosData.refStock0, GeneratedHanatosData.refRGB0, GeneratedHanatosData.refRaw0),
            (GeneratedHanatosData.refStock1, GeneratedHanatosData.refRGB1, GeneratedHanatosData.refRaw1),
            (GeneratedHanatosData.refStock2, GeneratedHanatosData.refRGB2, GeneratedHanatosData.refRaw2),
            (GeneratedHanatosData.refStock3, GeneratedHanatosData.refRGB3, GeneratedHanatosData.refRaw3),
            (GeneratedHanatosData.refStock4, GeneratedHanatosData.refRGB4, GeneratedHanatosData.refRaw4),
            (GeneratedHanatosData.refStock5, GeneratedHanatosData.refRGB5, GeneratedHanatosData.refRaw5),
            (GeneratedHanatosData.refStock6, GeneratedHanatosData.refRGB6, GeneratedHanatosData.refRaw6),
            (GeneratedHanatosData.refStock7, GeneratedHanatosData.refRGB7, GeneratedHanatosData.refRaw7),
            (GeneratedHanatosData.refStock8, GeneratedHanatosData.refRGB8, GeneratedHanatosData.refRaw8),
            (GeneratedHanatosData.refStock9, GeneratedHanatosData.refRGB9, GeneratedHanatosData.refRaw9),
            (GeneratedHanatosData.refStock10, GeneratedHanatosData.refRGB10, GeneratedHanatosData.refRaw10),
            (GeneratedHanatosData.refStock11, GeneratedHanatosData.refRGB11, GeneratedHanatosData.refRaw11),
        ]
        for (id, linearRGB, reference) in hanatosReferences {
            let hanatos = try OriginalHanatosResponse(filmID: id)
            let result = hanatos.raw(linearRGB: linearRGB)
            precondition(result.count == 3)
            for c in 0..<3 {
                // Packed Float16 is an intentional mobile memory choice.
                let tolerance = max(0.005, abs(reference[c]) * 0.01)
                precondition(abs(result[c] - reference[c]) < tolerance,
                             "Hanatos2025 source mismatch \(id), channel \(c): " +
                             "\(result[c]) vs \(reference[c])")
            }
        }
        print("PASS: 12 Hanatos2025 reference vectors with mobile Float16 precision.")

        // Retain the previously validated Mallett2019 alternative.
        let mallett: [(String, [Double], [Double])] = [
            (GeneratedOriginalOptics.referenceStock0, GeneratedOriginalOptics.referenceRGB0, GeneratedOriginalOptics.referenceRaw0),
            (GeneratedOriginalOptics.referenceStock1, GeneratedOriginalOptics.referenceRGB1, GeneratedOriginalOptics.referenceRaw1),
            (GeneratedOriginalOptics.referenceStock2, GeneratedOriginalOptics.referenceRGB2, GeneratedOriginalOptics.referenceRaw2),
            (GeneratedOriginalOptics.referenceStock3, GeneratedOriginalOptics.referenceRGB3, GeneratedOriginalOptics.referenceRaw3),
            (GeneratedOriginalOptics.referenceStock4, GeneratedOriginalOptics.referenceRGB4, GeneratedOriginalOptics.referenceRaw4),
            (GeneratedOriginalOptics.referenceStock5, GeneratedOriginalOptics.referenceRGB5, GeneratedOriginalOptics.referenceRaw5),
            (GeneratedOriginalOptics.referenceStock6, GeneratedOriginalOptics.referenceRGB6, GeneratedOriginalOptics.referenceRaw6),
            (GeneratedOriginalOptics.referenceStock7, GeneratedOriginalOptics.referenceRGB7, GeneratedOriginalOptics.referenceRaw7),
        ]
        for (id, input, expected) in mallett {
            let eng = try SpectralPhysics(filmID: id, paperID: "kodak_portra_endura")
            let rgb = eng.mallettRaw(linearRGB: input)
            for c in 0..<3 {
                precondition(abs(rgb[c] - expected[c]) < max(0.00001, abs(expected[c]) * 0.0001),
                             "Original Mallett2019 numeric mismatch: \(id)")
            }
        }
        print("PASS: original Mallett2019 Python/Swift numeric comparison.")

        // Upstream Python model/couplers.py parity including positive films:
        // density-curve inverse, silver inversion, donor/receiver matrix,
        // exposure inhibition and final corrected H-D lookup.
        precondition(GeneratedDIRData.records.count == 20,
                     "DIR matrices must cover every filming stock")
        let dirReferenceSamples: [(String, [Double], [Double])] = [
            (GeneratedDIRData.referenceStock0,
             GeneratedDIRData.referenceLogRaw0,
             GeneratedDIRData.referenceDensity0),
            (GeneratedDIRData.referenceStock1,
             GeneratedDIRData.referenceLogRaw1,
             GeneratedDIRData.referenceDensity1),
            (GeneratedDIRData.referenceStock2,
             GeneratedDIRData.referenceLogRaw2,
             GeneratedDIRData.referenceDensity2),
            (GeneratedDIRData.referenceStock3,
             GeneratedDIRData.referenceLogRaw3,
             GeneratedDIRData.referenceDensity3),
            (GeneratedDIRData.referenceStock4,
             GeneratedDIRData.referenceLogRaw4,
             GeneratedDIRData.referenceDensity4),
            (GeneratedDIRData.referenceStock5,
             GeneratedDIRData.referenceLogRaw5,
             GeneratedDIRData.referenceDensity5),
            (GeneratedDIRData.referenceStock6,
             GeneratedDIRData.referenceLogRaw6,
             GeneratedDIRData.referenceDensity6),
            (GeneratedDIRData.referenceStock7,
             GeneratedDIRData.referenceLogRaw7,
             GeneratedDIRData.referenceDensity7),
            (GeneratedDIRData.referenceStock8,
             GeneratedDIRData.referenceLogRaw8,
             GeneratedDIRData.referenceDensity8),
            (GeneratedDIRData.referenceStock9,
             GeneratedDIRData.referenceLogRaw9,
             GeneratedDIRData.referenceDensity9),
            (GeneratedDIRData.referenceStock10,
             GeneratedDIRData.referenceLogRaw10,
             GeneratedDIRData.referenceDensity10),
            (GeneratedDIRData.referenceStock11,
             GeneratedDIRData.referenceLogRaw11,
             GeneratedDIRData.referenceDensity11)
        ]
        for (filmID, logRaw, reference) in dirReferenceSamples {
            let engine = try SpectralPhysics(
                filmID: filmID, paperID: "kodak_portra_endura"
            )
            let simulated = engine.dirDevelopedDensity(logRaw: logRaw)
            precondition(simulated.count == 3, "Invalid DIR channel count")
            for channel in 0..<3 {
                precondition(
                    abs(simulated[channel] - reference[channel]) < 0.003,
                    "Original Python DIR mismatch \(filmID) ch\(channel): " +
                    "\(simulated[channel]) vs \(reference[channel])"
                )
            }
        }
        print("PASS: 12 original DIR coupled chemistry reference samples.")

        // v1.6 original emulsion granularity: source interp_density_cmy_layers
        // inverts measured H-D separately for all 3×3 sublayers, including
        // positive reversal films (negative density lookup direction).
        precondition(GeneratedSublayerGrainReference.samples.count == 16)
        for sample in GeneratedSublayerGrainReference.samples {
            let source = try SpectralPhysics.measuredSublayers(
                filmID: sample.stock, normalizedTotal: sample.total
            )
            precondition(source.layers.count == 9 && source.maxima.count == 9)
            for k in 0..<9 {
                precondition(
                    abs(source.layers[k]-sample.layers[k]) < 0.006,
                    "Measured source 3×3 layer mismatch for \(sample.stock), index \(k)"
                )
                precondition(
                    abs(source.maxima[k]-sample.layerRawMaximum[k]) < 0.006,
                    "Measured source layer maximum mismatch"
                )
            }
        }
        print("PASS: 16 original NumPy measured 3×3 H-D layer inversions, positive and negative stocks.")

        var pairs = 0
        for film in negatives {
            for medium in media {
                let engine = try SpectralPhysics(filmID: film, paperID: medium)
                let outputs = samples.map { engine.render($0, exposureEV: 0, paperEV: 0) }
                for value in outputs { check(value, "\(film) → \(medium)") }
                // Both exposure controls must yield well-defined finite output.
                check(engine.render(samples[1], exposureEV: 1, paperEV: 0), film)
                check(engine.render(samples[1], exposureEV: 0, paperEV: 1), medium)
                pairs += 1
            }
        }
        precondition(pairs == 128)
        print("PASS: all 16 negative films × all 8 print media = 128 routes.")

        for positive in positives {
            precondition(SpectralPhysics.isPositiveFilm(positive))
            let film1 = try SpectralPhysics(filmID: positive, paperID: media[0])
            let film2 = try SpectralPhysics(filmID: positive, paperID: media[7])
            for input in samples {
                let a = film1.render(input, exposureEV: 0, paperEV: -2)
                let b = film2.render(input, exposureEV: 0, paperEV: 2)
                check(a, "\(positive) direct scan")
                check(b, "\(positive) direct scan")
                for c in 0..<3 {
                    precondition(abs(a[c] - b[c]) < 0.000001,
                                 "Reversal must bypass enlarger and print stock")
                }
            }
        }
        print("PASS: 4 reversal films directly scan and bypass all print media.")

        // v1.4: optical-printing opt-in must preserve the previous
        // shipped result when disabled, even with nonzero dormant values.
        let experimentalOptics = OriginalPrintOptics.Settings(
            enabled: true,
            cyanShift: 25, magentaShift: -30, yellowShift: 18,
            preflashExposure: 0.03,
            preflashMagentaShift: 8, preflashYellowShift: -12
        )
        let dormantOptics = OriginalPrintOptics.Settings(
            enabled: false,
            cyanShift: 25, preflashExposure: 0.1
        )
        let referenceOld = try SpectralPhysics(
            filmID: "kodak_portra_400", paperID: "kodak_portra_endura"
        )
        let legacyDisabled = try SpectralPhysics(
            filmID: "kodak_portra_400", paperID: "kodak_portra_endura",
            printOptics: dormantOptics
        )
        let opticalNew = try SpectralPhysics(
            filmID: "kodak_portra_400", paperID: "kodak_portra_endura",
            printOptics: experimentalOptics, cameraExposureEV: 0.7
        )
        var meaningfulChanges = 0
        for color in samples {
            let oldRGB = referenceOld.render(
                color, exposureEV: 0.7, paperEV: -0.5
            )
            let sameRGB = legacyDisabled.render(
                color, exposureEV: 0.7, paperEV: -0.5
            )
            let newRGB = opticalNew.render(
                color, exposureEV: 0.7, paperEV: -0.5
            )
            check(newRGB, "original CMY/preflash print optics")
            for c in 0..<3 {
                precondition(oldRGB[c] == sameRGB[c],
                             "Disabled v1.4 must preserve v1.3 optical maths")
                if abs(newRGB[c] - oldRGB[c]) > 0.0001 {
                    meaningfulChanges += 1
                }
            }
        }
        precondition(meaningfulChanges > 0,
                     "Active source CMY/preflash must affect real paper exposure")
        let positiveLegacy = try SpectralPhysics(
            filmID: positives[0], paperID: media[0]
        )
        let positiveOptics = try SpectralPhysics(
            filmID: positives[0], paperID: media[0],
            printOptics: experimentalOptics
        )
        for color in samples {
            let old = positiveLegacy.render(color, exposureEV: 0, paperEV: 0)
            let new = positiveOptics.render(color, exposureEV: 0, paperEV: 0)
            precondition(old == new, "Reversal must bypass preflash/CMY")
        }
        let opticalStages = try SpectralPhysics.makeDensityStageData(
            filmID: "kodak_portra_400", paperID: "kodak_portra_endura",
            exposureEV: 0.7, paperEV: -0.5, size: 9,
            printOptics: experimentalOptics
        )
        precondition(opticalStages.printCube.count == 9*9*9*16)
        let opticalCube = try SpectralPhysics.makeCubeData(
            filmID: "kodak_portra_400", paperID: "kodak_portra_endura",
            exposureEV: 0.7, paperEV: -0.5, size: 9,
            printOptics: experimentalOptics
        )
        precondition(opticalCube.count == opticalStages.printCube.count)
        print("PASS: v1.4 opt-in optical print path, default parity, reversals and double-stage grain support.")

        let lut = try SpectralPhysics.makeCubeData(
            filmID: "kodak_portra_400", paperID: "kodak_2383",
            exposureEV: 0, paperEV: 0, size: 9
        )
        precondition(lut.count == 9*9*9*4*MemoryLayout<Float>.size)
        let reverseCube = try SpectralPhysics.makeCubeData(
            filmID: "fujifilm_provia_100f", paperID: media[0],
            exposureEV: 0, paperEV: 0, size: 9
        )
        precondition(reverseCube.count == lut.count)
        print("PASS: 3D colour cube generation for negative→movie print and reversal scan.")

        // Native two-stage density rendering: unmodified source RGB
        // becomes the original Hanatos+DIR developed film optical density,
        // then that density is optically printed/scanned using the same
        // negative/reversal topology as the original Python engine.
        let densityRoutes = [
            ("kodak_portra_400", "kodak_portra_endura"),
            ("kodak_portra_400", "kodak_2383"),
            ("fujifilm_provia_100f", "kodak_portra_endura")
        ]
        func lookup(_ bytes: Data, _ floatIndex: Int) -> Double {
            let array = [UInt8](bytes)
            let j = floatIndex * 4
            precondition(j+3 < array.count)
            let bits = UInt32(array[j]) |
                UInt32(array[j+1]) << 8 |
                UInt32(array[j+2]) << 16 |
                UInt32(array[j+3]) << 24
            return Double(Float(bitPattern: bits))
        }
        for (negative, paper) in densityRoutes {
            let engine = try SpectralPhysics(filmID: negative, paperID: paper)
            let paired = try SpectralPhysics.makeDensityStageData(
                filmID: negative, paperID: paper, exposureEV: 0,
                paperEV: 0, size: 9
            )
            let size = paired.size
            precondition(paired.inputCube.count == size*size*size*16)
            precondition(paired.printCube.count == size*size*size*16)
            precondition(paired.ranges.count == 3)
            let offset = ((4*size+4)*size+4)*4
            let measured = engine.developedFilmDensity(
                [0.5,0.5,0.5], exposureEV: 0
            )
            let scanned = engine.scanFilmDensity(
                paired.ranges.map { $0*0.5 }, paperEV: 0
            )
            for channel in 0..<3 {
                let dSample = lookup(paired.inputCube, offset+channel)
                let rgbSample = lookup(paired.printCube, offset+channel)
                precondition(abs(dSample - min(1.0, max(0.0,
                    measured[channel]/paired.ranges[channel]))) < 0.00005,
                    "Initial optical-density stage mismatch \(negative), ch\(channel)")
                precondition(abs(rgbSample - scanned[channel]) < 0.00005,
                    "Substrate optical print/scan mismatch \(paper), ch\(channel)")
            }
        }
        print("PASS: original Hanatos+DIR optical density and downstream print/scan 3D cube separation.")
        // Exercise the complete new source spatial DIR LUT generator, not
        // only the standalone inhibition/CI kernels. Negative paper,
        // negative motion-print and reversal direct-scan paths must all
        // produce finite shader input data with original exposure ranges.
        for (film, medium) in densityRoutes {
            let sourceDIR = try SpectralPhysics.makeSpatialDIRStageData(
                filmID: film, paperID: medium,
                exposureEV: 0.5, paperEV: -0.4,
                size: 9, correctedSize: 17
            )
            precondition(sourceDIR.valid,
                         "Invalid physical DIR spatial intermediate stage")
            precondition(sourceDIR.rawLogCube.count == 9*9*9*16)
            precondition(sourceDIR.initialDensityCube.count == 9*9*9*16)
            precondition(sourceDIR.correctedDensityCube.count == 17*17*17*16)
            precondition(sourceDIR.printCube.count == 9*9*9*16)
            precondition(sourceDIR.positive == SpectralPhysics.isPositiveFilm(film))
            let layers = try SpectralPhysics.makeDensityStageData(
                filmID: film, paperID: medium,
                exposureEV: 0.5, paperEV: -0.4,
                size: 9
            )
            precondition(layers.sublayerCubes.count == 3 &&
                         layers.sublayerRawMaxima.count == 9)
            precondition(layers.sublayerCubes.allSatisfy {
                $0.count == 9*9*9*16
            })
        }
        print("PASS: 3 complete Hanatos -> initial DIR -> spatial DIR corrected H-D -> print/scan data paths.")

        // Source-scanner opt-in must not alter the legacy v1.0.1 default.
        // Exercise all measured print media and direct reversal routes, and
        // the two-cube grain print stage under the scanner pathway.
        var originalScannerPairs=0
        for negative in negatives {
            for paper in media {
                let engine=try SpectralPhysics(
                    filmID:negative,paperID:paper,sourceScanner:true
                )
                for input in [samples[1],samples[3]] {
                    check(engine.render(input,exposureEV:0,paperEV:0),
                          "source scanner \(negative) \(paper)")
                }
                originalScannerPairs+=1
            }
        }
        precondition(originalScannerPairs==128)
        for reversal in positives {
            let a=try SpectralPhysics(
                filmID:reversal,paperID:media[0],sourceScanner:true
            )
            let b=try SpectralPhysics(
                filmID:reversal,paperID:media[7],sourceScanner:true
            )
            for input in [samples[1],samples[4]] {
                let v1=a.render(input,exposureEV:0,paperEV:-2)
                let v2=b.render(input,exposureEV:0,paperEV:2)
                check(v1,"source reversal \(reversal)")
                for c in 0..<3 {
                    precondition(abs(v1[c]-v2[c]) < 0.000001,
                                 "Reversal bypasses printing in source scanner")
                }
            }
        }
        print("PASS: 128 original viewing-scanner negatives and 4 reversal direct-scans.")

        for (filmID,printID) in densityRoutes {
            let scanner=try SpectralPhysics(
                filmID:filmID,paperID:printID,
                sourceScanner:true,scannerBlackWhite:true
            )
            check(scanner.render(samples[1],exposureEV:0,paperEV:0),
                  "source scanner calibrated \(filmID)")
            let pair=try SpectralPhysics.makeDensityStageData(
                filmID:filmID,paperID:printID,exposureEV:0,paperEV:0,
                size:9,sourceScanner:true,scannerBlackWhite:true
            )
            precondition(pair.inputCube.count==9*9*9*16)
            precondition(pair.printCube.count==9*9*9*16)
        }
        print("PASS: optional black/white endpoint calibration and source scanner density split.")

        // v1.3 source-topology print calibration and original 3-layer
        // fitted CDF printing chemistry: all 16x8 media combinations.
        var calibratedPairCount=0
        var nonzeroExposureCount=0
        var morphEffectCount=0
        let gamma=OriginalPrintMorph.Settings(
            gamma:1.18,fast:1.05,slow:0.94,developerExhaustion:0.2
        )
        for negative in negatives {
            for medium in media {
                let original=try SpectralPhysics(
                    filmID:negative,paperID:medium,
                    sourceScanner:true,scannerBlackWhite:true
                )
                let enriched=try SpectralPhysics(
                    filmID:negative,paperID:medium,sourceScanner:true,
                    scannerBlackWhite:true,cam16Gamut:true,
                    printReferenceCorrection:true,printMorph:gamma
                )
                for ev in [-1.0,0.0,1.0] {
                    check(enriched.render(samples[2],exposureEV:0,paperEV:ev),
                          "calibrated print \(negative)/\(medium)")
                }
                if let ref=enriched.originalPrintCalibration() {
                    precondition(ref.yBlack > 0 && ref.yWhite > ref.yBlack)
                    precondition(ref.ev.isFinite && abs(ref.ev)<=4)
                    if abs(ref.ev)>1e-6 { nonzeroExposureCount += 1 }
                }
                let delta=enriched.originalPrintMorphDelta(
                    logExposure:0.24,channel:1
                )
                precondition(delta.isFinite)
                if abs(delta)>1e-6 { morphEffectCount += 1 }
                // A disabled new option must leave the v1.2 source
                // scanner result unaffected.
                let unmodified=try SpectralPhysics(
                    filmID:negative,paperID:medium,
                    sourceScanner:true,scannerBlackWhite:true,
                    printReferenceCorrection:false,
                    printMorph:OriginalPrintMorph.Settings()
                )
                let plainA=original.render(samples[1],exposureEV:0,paperEV:0)
                let plainB=unmodified.render(samples[1],exposureEV:0,paperEV:0)
                for c in 0..<3 {
                    precondition(abs(plainA[c]-plainB[c]) < 1e-12)
                }
                calibratedPairCount += 1
            }
        }
        precondition(calibratedPairCount == 128)
        precondition(nonzeroExposureCount > 0)
        precondition(morphEffectCount == 128)
        print("PASS: 128 print-pair source reference/morph optical chains and legacy-off parity.")

        for reversal in positives {
            let a=try SpectralPhysics(
                filmID:reversal,paperID:media[0],sourceScanner:true,
                scannerBlackWhite:true,cam16Gamut:true,
                printReferenceCorrection:true,printMorph:gamma
            )
            precondition(a.originalPrintCalibration() == nil,
                         "Direct reversal scan must bypass print exposure.")
            precondition(a.originalPrintMorphDelta(
                logExposure:0.2,channel:0)==0,
                "Direct reversal scan must bypass print morphology.")
        }
        print("PASS: 4 reversal sources ignore downstream print reference/morph.")

        for (negative,medium) in densityRoutes.prefix(2) {
            let lut=try SpectralPhysics.makeDensityStageData(
                filmID:negative,paperID:medium,
                exposureEV:0,paperEV:0,size:9,
                sourceScanner:true,scannerBlackWhite:true,cam16Gamut:true,
                printReferenceCorrection:true,printMorph:gamma
            )
            precondition(lut.inputCube.count==9*9*9*16)
            precondition(lut.printCube.count==9*9*9*16)
        }
        print("PASS: measured density-grain split supports calibrated print and s023 morph.")

        do {
            _ = try SpectralPhysics(filmID: "missing_profile", paperID: media[0])
            preconditionFailure("Unknown materials must reject")
        } catch is SpectralPhysics.PhysicsError {}
        print("PASS: 28 original source materials, native spectral film/print routing and invalid-selection rejection.")
        // v1.8.21: true nonlinear measured-film/paper source LUT nodes
        // must remain Double in the real production SpatialDIRStage.
        // This tests REAL Hanatos/film-H-D/spectral-print nodes, not the
        // existing identity-cube DIR physics fixture. The Python source
        // 13-stage optical vectors remain independently gated below.
        let optical = OriginalPrintOptics.Settings(enabled: true)
        let nonlinearStage = try SpectralPhysics.makeSpatialDIRStageData(
            filmID: "kodak_portra_400",
            paperID: "kodak_portra_endura",
            exposureEV: 0, paperEV: 0,
            size: 9, correctedSize: 17,
            sourceScanner: true, printOptics: optical,
            hanatosPrecision: .originalFloat64
        )
        precondition(nonlinearStage.valid,
                     "Real stock spectral stage must validate")
        guard let preciseNodes = nonlinearStage.float64OpticalNodes else {
            fatalError("Nonlinear source Float64 LUT nodes missing in production")
        }
        let packedNodes: [(Data, [Double], String)] = [
            (nonlinearStage.rawLogCube, preciseNodes.raw, "camera log"),
            (nonlinearStage.initialDensityCube, preciseNodes.initial, "initial H-D"),
            (nonlinearStage.correctedDensityCube, preciseNodes.corrected, "corrected H-D"),
            (nonlinearStage.printCube, preciseNodes.printed, "paper/spectral scan")
        ]
        var quantizedNodes=0
        var maxQuantization=0.0
        for (data, truth, label) in packedNodes {
            let bytes=[UInt8](data)
            precondition(bytes.count == truth.count * 4, label + ": node sizes")
            for i in truth.indices {
                let at=i*4
                let bits = UInt32(bytes[at]) |
                    UInt32(bytes[at+1]) << 8 |
                    UInt32(bytes[at+2]) << 16 |
                    UInt32(bytes[at+3]) << 24
                let old = Double(Float(bitPattern: bits))
                let delta=abs(old-truth[i])
                precondition(delta.isFinite && delta <= 0.000001,
                             label + ": packed Float32 and Double represent different algorithms")
                maxQuantization=max(maxQuantization,delta)
                if delta>0 { quantizedNodes+=1 }
            }
        }
        precondition(quantizedNodes > 0,
                     "Source nonlinear LUT test did not expose Float32 rounding")
        let samplePrint=preciseNodes.printed
        let nonlinearity = zip(
            Array(samplePrint[0..<3]),
            Array(samplePrint[(samplePrint.count-4)..<(samplePrint.count-1)])
        ).reduce(0.0) { $0 + abs($1.0 - $1.1) }
        precondition(nonlinearity > 0.001,
                     "Test fixture must contain nonlinear real stock printing")
        let nodeCount = preciseNodes.raw.count + preciseNodes.initial.count +
            preciseNodes.corrected.count + preciseNodes.printed.count
        print("PASS: original nonlinear stock/paper four source LUTs retain " +
              "\(nodeCount) Double node values, \(quantizedNodes) changed " +
              "by Float32 packing, maximum quantization=\(maxQuantization). " +
              "Source DIR consumes Double nodes without fallback.")

        // Quantify actual source Python to Swift OUTPUT RGB deviation for
        // direct reversal scans; this stage is deliberately not a
        // whole-film/printing/grain certification.
        let rgbEvidence = try OriginalSourceRGBParity.evaluate()
        precondition(rgbEvidence.samples == 72)
        precondition(rgbEvidence.mae.isFinite && rgbEvidence.rmse.isFinite)
        precondition(rgbEvidence.maximum.isFinite)
        print(rgbEvidence.text)
        precondition(rgbEvidence.outsideTolerance == 0,
                     "SOURCE RGB regression: >0.002 encoded channel deviation")
        // Separate source-backed scan of ALREADY-DEVELOPED printing media.
        // Do not mislabel as full negative->paper/RAW/whole-image parity.
        let printRGBEvidence = try OriginalPrintScannerParity.evaluate()
        precondition(printRGBEvidence.samples == 72)
        precondition(printRGBEvidence.mae.isFinite &&
                     printRGBEvidence.maximum.isFinite)
        print(printRGBEvidence.text)
        precondition(printRGBEvidence.outsideTolerance == 0,
                     "SOURCE PAPER SCANNER RGB: >0.002 encoded channel deviation")
        // v1.8.12: CONTIGUOUS source optical chain with already-developed
        // negative CMY. Not a camera RAW/film-DIR/whole-image certificate.
        let chainEvidence = try OriginalNegativePrintChainParity.evaluate()
        print(chainEvidence.text)
        precondition(chainEvidence.channels == 54)
        precondition(chainEvidence.outputOutsideTolerance == 0,
                     "SOURCE NEGATIVE-PRINT RGB: >0.002 encoded channel deviation")
        precondition(chainEvidence.stageOutsideTolerance == 0,
                     "SOURCE NEGATIVE-PRINT H-D/RAW/XYZ: >0.002 stage deviation")
        // v1.8.14 extends the SAME source optics and CDF H-D chain
        // BACKWARDS through upstream Python measured negative H-D and
        // model/couplers.py nonspatial DIR. Exposure log10 RAW input is
        // known; camera RAW/Hanatos is NOT certified by this test.
        let filmEvidence = try OriginalFilmDIRPrintParity.evaluate()
        print(filmEvidence.text)
        precondition(filmEvidence.channels == 54)
        precondition(filmEvidence.outputOutsideTolerance == 0,
                     "SOURCE FILM H-D/DIR→PRINT RGB: >0.002 encoded deviation")
        precondition(filmEvidence.stageOutsideTolerance == 0,
                     "SOURCE FILM H-D/DIR→PRINT: >0.002 intermediate deviation")
        // Full source H2025 -> camera EV -> measured negative H-D / DIR ->
        // exact s023 paper CDF + XYZ / ACES / sRGB. Tests both storage
        // precision modes against the SAME upstream source Float64 image
        // values. Only original Float64 is source-certification gated;
        // mobile Float16 approximation errors remain visible separately.
        let cameraEvidence=try OriginalCameraFilmPrintParity.evaluate()
        print(cameraEvidence.text)
        precondition(cameraEvidence.channels==72)
        precondition(cameraEvidence.preciseStageExceed==0,
                     "SOURCE H2025 CAMERA->PRINT: >0.002 exact-mode stage")
        precondition(cameraEvidence.preciseOutputExceed==0,
                     "SOURCE H2025 CAMERA->PRINT: >0.002 exact-mode RGB")
        // v1.8.22: the TRUE nonlinear 2D optical image is computed from
        // original Hanatos/H-D/physical paper/scan per input pixel.
        // The independent real Python source stages are generated in CI.
        try SourcePhysicalImageParity.evaluate(
            fixtures:URL(
                fileURLWithPath:"ios/verification/generated-physical-v1.8.22",
                isDirectory:true
            )
        )
    }
}
