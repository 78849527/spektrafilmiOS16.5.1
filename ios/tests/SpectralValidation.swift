import Foundation

/// Portable macOS native-physics regression suite built on Xcode 16.4.
/// Tests correctness of stock classification, original Hanatos sensor LUT
/// interpolation, Mallett 2019 reference compatibility, 16x8 negative print
/// combinations and reversal film direct-scanning (without paper).
@main
struct SpectralValidation {
    static func main() throws {
        let all = GeneratedSpectralData.profiles
        let films = SpectralPhysics.supportedFilmIDs
        let media = SpectralPhysics.supportedPaperIDs
        let negatives = GeneratedSpectralData.negativeFilmIDs
        let positives = GeneratedSpectralData.positiveFilmIDs

        precondition(all.count == 28, "All 28 original measured profiles needed")
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

        do {
            _ = try SpectralPhysics(filmID: "missing_profile", paperID: media[0])
            preconditionFailure("Unknown materials must reject")
        } catch is SpectralPhysics.PhysicsError {}
        print("PASS: 28 original source materials, native spectral film/print routing and invalid-selection rejection.")
    }
}
