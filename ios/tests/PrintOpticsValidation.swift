import Foundation

/// Original Python Float64 reference comparisons at the PRINT EXPOSURE
/// buffer, before s023 paper curves / scanning. Independent of output LUT.
@main
struct PrintOpticsValidation {
    static func unpack(_ text: String, count: Int) -> [Double] {
        guard let data = Data(base64Encoded: text),
              data.count == count * 4 else {
            fatalError("Missing original Float32 profile data")
        }
        let bytes = [UInt8](data)
        return (0..<count).map { index in
            let offset = index * 4
            let bits = UInt32(bytes[offset])
                | (UInt32(bytes[offset+1]) << 8)
                | (UInt32(bytes[offset+2]) << 16)
                | (UInt32(bytes[offset+3]) << 24)
            return Double(Float(bitPattern: bits))
        }
    }

    static func near(_ observed: Double, _ expected: Double,
                     label: String) {
        let tolerance = max(2e-6, abs(expected)*2.0e-4)
        precondition(observed.isFinite &&
                     abs(observed-expected) <= tolerance,
                     "\(label): \(observed) != \(expected) tolerance \(tolerance)")
    }

    static func raw(
        densities: [Double], base: [Double], dye: [Double],
        weights: [[Double]]
    ) -> [Double] {
        var result = [Double](repeating: 0, count: 3)
        for index in 0..<81 {
            var absorbance = base[index]
            for c in 0..<3 {
                absorbance += dye[index*3+c]*densities[c]
            }
            let transmission = pow(10.0, -absorbance)
            for c in 0..<3 {
                result[c] += weights[index][c] * transmission
            }
        }
        return result
    }

    static func main() {
        let source = unpack(GeneratedOriginalOptics.enlargerSource, count: 81)
        let taps = [0, 17, 40, 64, 80]
        precondition(GeneratedPrintOpticsReference.vectors.count == 4)
        for vector in GeneratedPrintOpticsReference.vectors {
            guard let film = GeneratedSpectralData.profiles[vector.film],
                  let paper = GeneratedSpectralData.profiles[vector.paper],
                  let neutral = GeneratedOriginalOptics.neutralCMYByPair[
                    vector.film + "|" + vector.paper
                  ] else {
                fatalError("Missing print source reference material")
            }
            let base = unpack(film.baseDensity, count: 81)
            let dye = unpack(film.channelDensity, count: 243)
            let paperLog = unpack(paper.logSensitivity, count: 243)
            let paperSens = (0..<81).map { index in
                (0..<3).map { c in pow(10.0, paperLog[index*3+c]) }
            }
            let settings = OriginalPrintOptics.Settings(
                enabled: true,
                cyanShift: vector.shift[0],
                magentaShift: vector.shift[1],
                yellowShift: vector.shift[2],
                preflashExposure: vector.preflashExposure,
                preflashMagentaShift: vector.preflashM,
                preflashYellowShift: vector.preflashY
            )
            precondition(settings.isValid)
            let prepared = OriginalPrintOptics.prepare(
                source: source, neutralCC: neutral, settings: settings,
                filmBase: base, paperSensitivity: paperSens
            )
            for c in 0..<5 {
                near(prepared.printIlluminant[taps[c]], vector.lightSamples[c],
                     label: "CMY irradiance \(vector.film): \(c)")
            }
            for c in 0..<3 {
                near(prepared.preflashRaw[c], vector.preflash[c],
                     label: "preflash raw \(vector.film): \(c)")
            }
            let weights = (0..<81).map { i in
                (0..<3).map { c in
                    prepared.printIlluminant[i]*paperSens[i][c]
                }
            }
            let observed = raw(
                densities: vector.density, base: base, dye: dye,
                weights: weights
            )
            let midgray = raw(
                densities: vector.midgrayDensity, base: base, dye: dye,
                weights: weights
            )
            let reference = OriginalPrintOptics.midgrayReference(midgray)
            near(reference, vector.reference, label: "midgrey normalization")
            let compensatedDensity = (0..<3).map {
                vector.midgrayDensity[$0] + [0.09, -0.05, 0.10][$0]
            }
            let compRaw = raw(
                densities: compensatedDensity, base: base, dye: dye,
                weights: weights
            )
            let modes: [(Bool, Bool)] = [
                (false, false), (true, false),
                (false, true), (true, true)
            ]
            for (i, flags) in modes.enumerated() {
                let divisor = OriginalPrintOptics.referenceDivisor(
                    midgrayRaw: midgray, compensatedRaw: compRaw,
                    normalize: flags.0, compensate: flags.1
                )
                near(1.0 / divisor, vector.normalizationFactors[i],
                     label: "source enlarger normalization flags \(i)")
            }
            for c in 0..<3 {
                near(observed[c], vector.raw[c],
                     label: "paper spectral raw \(vector.paper): \(c)")
            }
            let printed = OriginalPrintOptics.paperLogExposure(
                raw: observed, reference: reference,
                preflash: prepared.preflashRaw, printEV: vector.ev
            )
            for c in 0..<3 {
                near(printed[c], vector.logExposure[c],
                     label: "post preflash log exposure \(vector.paper): \(c)")
            }
        }
        precondition(!OriginalPrintOptics.Settings(
            enabled: true, preflashExposure: -0.1
        ).isValid)
        print("PASS: source Python Float64 optical print parity — 4 vectors, CMY spectrum, preflash, raw/normalized/log exposure.")
    }
}
