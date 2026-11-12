import Foundation

/// Port of PrintingStage optical enlarger / color_filters.py.
/// Filter CC is Kodak colour-compensating density (100 CC = D1.0).
/// The preflash is additional paper *irradiance*, before log exposure
/// and before the paper H-D development curve; it is not an RGB lift.
enum OriginalPrintOptics {
    struct Settings {
        var enabled = false
        var normalizePrintExposure = true
        var printExposureCompensation = true
        var cyanShift = 0.0
        var magentaShift = 0.0
        var yellowShift = 0.0
        var preflashExposure = 0.0
        var preflashMagentaShift = 0.0
        var preflashYellowShift = 0.0

        var isValid: Bool {
            let values = [cyanShift, magentaShift, yellowShift,
                          preflashExposure, preflashMagentaShift,
                          preflashYellowShift]
            return values.allSatisfy { $0.isFinite } &&
                abs(cyanShift) <= 100 && abs(magentaShift) <= 100 &&
                abs(yellowShift) <= 100 &&
                abs(preflashMagentaShift) <= 100 &&
                abs(preflashYellowShift) <= 100 &&
                preflashExposure >= 0 && preflashExposure <= 1
        }
    }

    struct Prepared {
        let printIlluminant: [Double]
        let preflashRaw: [Double]
    }

    /// The original custom dichroics: erf transition profile, in CMY order.
    /// Wavelengths are 380...780 nm at 5 nm spacing.
    static func filteredIlluminant(_ source: [Double], cc: [Double]) -> [Double] {
        precondition(source.count == 81 && cc.count == 3)
        return (0..<81).map { index in
            let wavelength = Double(380 + index * 5)
            let cyan = (1.0 - erf((wavelength - 607.0) / 8.0)) * 0.5
            let magenta = wavelength <= 550
                ? (1.0 - erf((wavelength - 500.0) / 8.0)) * 0.5
                : (1.0 + erf((wavelength - 610.0) / 8.0)) * 0.5
            let yellow = (1.0 + erf((wavelength - 516.0) / 12.0)) * 0.5
            let filters = [cyan, magenta, yellow]
            var transmission = 1.0
            for c in 0..<3 {
                let wheel = pow(10.0, -cc[c] / 100.0)
                transmission *= 1.0 - (1.0 - filters[c]) * (1.0 - wheel)
            }
            return source[index] * transmission
        }
    }

    static func prepare(
        source: [Double], neutralCC: [Double],
        settings: Settings, filmBase: [Double],
        paperSensitivity: [[Double]]
    ) -> Prepared {
        precondition(source.count == 81 && neutralCC.count == 3 &&
                     filmBase.count == 81 && paperSensitivity.count == 81)
        let printingCC = [
            neutralCC[0] + settings.cyanShift,
            neutralCC[1] + settings.magentaShift,
            neutralCC[2] + settings.yellowShift
        ]
        let printingLight = filteredIlluminant(source, cc: printingCC)
        var preflash = [Double](repeating: 0, count: 3)
        if settings.preflashExposure > 0 {
            // Upstream preflash uses neutral C, and separately shifted M/Y.
            // This bypasses the negative image dyes, but traverses film base.
            let preflashCC = [
                neutralCC[0],
                neutralCC[1] + settings.preflashMagentaShift,
                neutralCC[2] + settings.preflashYellowShift
            ]
            let flashLight = filteredIlluminant(source, cc: preflashCC)
            for i in 0..<81 {
                let light = flashLight[i] * pow(10.0, -filmBase[i])
                for c in 0..<3 {
                    preflash[c] += light * paperSensitivity[i][c]
                }
            }
            for c in 0..<3 { preflash[c] *= settings.preflashExposure }
        }
        return Prepared(printIlluminant: printingLight, preflashRaw: preflash)
    }

    /// PrintingStage._compute_exposure_factor_midgray when both source
    /// normalize_print_exposure and print_exposure_compensation are true:
    /// inverse geometric mean of the compensated midgrey triplet.
    static func midgrayReference(_ raw: [Double]) -> Double {
        precondition(raw.count == 3)
        let meanLog = raw.reduce(0.0) {
            $0 + log(max($1, 1e-10))
        } / 3.0
        return exp(meanLog)
    }

    /// PrintingStage._compute_exposure_factor_midgray implements FOUR
    /// normalization/compensation switch combinations:
    ///   normalize  compensate  multiplier
    ///      true      true       1/G(compensated_midgray)
    ///      true      false      1/G(midgray)
    ///      false     true       G(midgray)/G(compensated_midgray)
    ///      false     false      1
    /// Here the multiplier is represented by a DIVISOR to avoid another
    /// multiplication at every LUT sample.
    static func referenceDivisor(
        midgrayRaw: [Double], compensatedRaw: [Double],
        normalize: Bool, compensate: Bool
    ) -> Double {
        if !normalize && !compensate { return 1.0 }
        let midgray = midgrayReference(midgrayRaw)
        if normalize && !compensate { return midgray }
        let compensated = midgrayReference(compensatedRaw)
        if normalize && compensate { return compensated }
        return compensated / max(midgray, 1e-10)
    }

    /// PrintingStage.expose: raw = (enlarger_raw * factor_midgray_comp +
    /// raw_preflash) * print_exposure * black_white_exposure_correction.
    /// Diffusion is spatial and outside this per-pixel LUT (not simulated).
    static func paperLogExposure(
        raw: [Double], reference: Double, preflash: [Double],
        printEV: Double
    ) -> [Double] {
        precondition(raw.count == 3 && preflash.count == 3)
        let exposure = pow(2.0, printEV)
        return (0..<3).map { c in
            let rawBeforeEnlarger = max(
                0, raw[c] / max(reference, 1e-10) + preflash[c]
            ) + 1e-10
            let total = rawBeforeEnlarger * exposure
            // Two 1e-10 floors in the source: before and after printing.
            return log10(max(0, total) + 1e-10)
        }
    }
}
