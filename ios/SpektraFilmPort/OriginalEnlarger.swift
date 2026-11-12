import Foundation
import Darwin

/// Source Spektrafilm model/color_filters.py and runtime
/// services/filter_enlarger_source.py. All spectra are evaluated on
/// the ORIGINAL 380...780 nm @ 5 nm, using exact 4+4 dichroic edges,
/// 3-channel Kodak CC density and stock-specific neutral CMY table.
/// Optional mode only; a v1.3 render does not load this component.
enum OriginalEnlarger {
    struct Settings: Equatable {
        var enabled = false
        var normalizeExposure = true
        var mShift = 0.0
        var yShift = 0.0
        var preflashExposure = 0.0
        var preflashMShift = 0.0
        var preflashYShift = 0.0
        var printExposureCompensation = true

        var valid: Bool {
            [mShift,yShift,preflashMShift,preflashYShift,
             preflashExposure].allSatisfy({$0.isFinite}) &&
            abs(mShift) <= 100 && abs(yShift) <= 100 &&
            abs(preflashMShift) <= 100 && abs(preflashYShift) <= 100 &&
            preflashExposure >= 0 && preflashExposure <= 3
        }
    }

    static func filterTransmission(wavelength: Double,
                                   cc: [Double]) -> Double {
        guard cc.count == 3 else { return 1.0 }
        let c = 0.5-0.5*erf((wavelength-607.0)/8.0)
        let m = wavelength <= 550
            ? 0.5-0.5*erf((wavelength-500.0)/8.0)
            : 0.5+0.5*erf((wavelength-610.0)/8.0)
        let y = 0.5+0.5*erf((wavelength-516.0)/12.0)
        // Upstream DichroicFilters.apply_cc:
        // T = product(1-(1-dichroic)*(1-10^(-cc/100))).
        return zip([c,m,y],cc).reduce(1.0) { result, pair in
            let t=pow(10.0,-pair.1/100.0)
            return result*(1-(1-pair.0)*(1-t))
        }
    }

    static func filteredSpectrum(source: [Double], cc: [Double]) -> [Double] {
        guard source.count == 81,cc.count == 3 else { return [] }
        return (0..<81).map { i in
            source[i]*filterTransmission(
                wavelength: Double(380 + 5*i), cc: cc
            )
        }
    }

    static func mainCC(neutral: [Double], settings: Settings) -> [Double] {
        [neutral[0],neutral[1]+settings.mShift,neutral[2]+settings.yShift]
    }

    static func flashCC(neutral: [Double], settings: Settings) -> [Double] {
        [neutral[0],neutral[1]+settings.preflashMShift,
         neutral[2]+settings.preflashYShift]
    }

    /// Per-wavelength enlargement channel response.
    static func weights(illuminant: [Double],
                        paperSensitivity: [[Double]]) -> [[Double]] {
        guard illuminant.count == 81,paperSensitivity.count == 81 else {
            return []
        }
        return (0..<81).map { i in
            (0..<3).map { channel in
                illuminant[i]*paperSensitivity[i][channel]
            }
        }
    }

    /// Original PrintingStage._compute_raw_preflash: the filtered base
    /// film density transmitted into print stock channel sensitivity,
    /// multiplied by independent preflash exposure (not normalized).
    static func preflashRaw(
        filmBaseDensity: [Double],
        source: [Double],
        neutral: [Double],
        settings: Settings,
        paperSensitivity: [[Double]]
    ) -> [Double] {
        guard settings.valid,settings.preflashExposure > 0,
              filmBaseDensity.count == 81, source.count == 81,
              neutral.count == 3, paperSensitivity.count == 81 else {
            return [0,0,0]
        }
        let flashIlluminant=filteredSpectrum(
            source:source,cc:flashCC(neutral:neutral,settings:settings)
        )
        var response=[Double](repeating:0,count:3)
        for wavelength in 0..<81 {
            let transmitted=pow(10.0,-filmBaseDensity[wavelength])
            for channel in 0..<3 {
                response[channel] += flashIlluminant[wavelength] *
                    transmitted * paperSensitivity[wavelength][channel]
            }
        }
        return response.map { $0*settings.preflashExposure }
    }

    static func geometricNormalization(_ response: [Double]) -> Double {
        guard response.count == 3 else { return 1.0 }
        return exp(response.reduce(0.0) {
            $0+log(max(1e-10,$1))
        }/3.0)
    }

    /// Preflash is added AFTER main beam's midgrey normalization and
    /// BEFORE enlarger exposure; equivalent to upstream
    /// PrintingStage._film_cmy_to_print_log_raw and expose.
    static func rawWithPreflash(
        sceneRaw: [Double], reference: Double,
        flashRaw: [Double], normalize: Bool
    ) -> [Double] {
        guard sceneRaw.count == 3,flashRaw.count == 3 else { return sceneRaw }
        let denominator = normalize ? max(1e-14,reference) : 1.0
        return (0..<3).map { channel in
            max(0,sceneRaw[channel]/denominator+flashRaw[channel])
        }
    }
}
