import Foundation

/// Exposure-aware printing black/white calibration, ported from source
/// ColorReferenceService.black_white_printing_exposure_correction.
///
/// Original source computes a luminance correction slope and maps
/// corrected 0.184 midgrey luminance back to a print-exposure adjustment
/// by inverting the original measured three-channel average H-D curve.
/// The upstream print normalization/preflash/CC pipeline is approximated
/// by the existing iOS printRaw/reference normalization, not fully equal.
enum OriginalPrintReference {
    struct Correction {
        let yBlack: Double
        let yWhite: Double
        let exposureEV: Double
        let midgrayInputY: Double
        let targetBlack: Double
        let targetWhite: Double
    }

    static func apply(
        yBlack: Double, yWhite: Double,
        logExposure: [Float], rawCurves: [Float],
        spectralBase: [Float],
        blackLevel: Double = 0.01,
        whiteLevel: Double = 0.98
    ) -> Correction? {
        guard yBlack.isFinite, yWhite.isFinite, yWhite > yBlack+1e-10,
              logExposure.count == 256, rawCurves.count == 256*3,
              spectralBase.count == 81 else { return nil }

        let encodedBlack = OriginalScannerMath.decodeSRGB(blackLevel)
        let encodedWhite = OriginalScannerMath.decodeSRGB(whiteLevel)
        let slope = (encodedWhite-encodedBlack)/(yWhite-yBlack+1e-10)
        let intercept = encodedBlack - slope*yBlack
        guard slope.isFinite, abs(slope) > 1e-10 else { return nil }
        let midgreyBeforeCorrection = (0.184-intercept)/slope
        guard midgreyBeforeCorrection.isFinite,
              midgreyBeforeCorrection > 0 else { return nil }

        let densityTarget = -log10(max(1e-10,midgreyBeforeCorrection))
        let densityUncorrected = -log10(0.184)
        let minDensity = spectralBase.reduce(0.0) {
            $0 + Double($1)
        } / Double(spectralBase.count)

        var measured = [Double](repeating:0,count:256)
        for j in 0..<256 {
            measured[j] = (
                Double(rawCurves[j*3]) +
                Double(rawCurves[j*3+1]) +
                Double(rawCurves[j*3+2])
            )/3
        }
        let correctedExposure = interpolateInverse(
            target: densityTarget-minDensity,
            response: measured, exposure: logExposure
        )
        let baselineExposure = interpolateInverse(
            target: densityUncorrected-minDensity,
            response: measured, exposure: logExposure
        )
        let resultFactor = pow(10.0,correctedExposure-baselineExposure)
        guard resultFactor.isFinite, resultFactor > 0 else { return nil }
        // Clamp only extreme physically invalid numerical endpoints.
        let ev = max(-4,min(4,log2(resultFactor)))
        return Correction(
            yBlack:yBlack, yWhite:yWhite, exposureEV:ev,
            midgrayInputY:midgreyBeforeCorrection,
            targetBlack:encodedBlack, targetWhite:encodedWhite
        )
    }

    /// np.interp in source color_reference.py: monotonic response curve
    /// in ascending density. Endpoint clamp matches NumPy.
    static func interpolateInverse(
        target: Double, response: [Double],
        exposure: [Float]
    ) -> Double {
        guard response.count == 256 && exposure.count == 256,
              target.isFinite else { return 0 }
        if target <= response[0] { return Double(exposure[0]) }
        if target >= response[255] { return Double(exposure[255]) }
        var lo=0
        var hi=255
        while lo+1<hi {
            let mid=(lo+hi)/2
            if target >= response[mid] { lo=mid }
            else { hi=mid }
        }
        let d0=response[lo]
        let d1=response[hi]
        let fraction=(target-d0)/max(1e-12,d1-d0)
        return Double(exposure[lo])*(1-fraction)+Double(exposure[hi])*fraction
    }
}
