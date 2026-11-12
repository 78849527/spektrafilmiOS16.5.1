import Foundation

/// Exact source-supported output RGB ACES RGC v1.3 scalar formulation
/// and original colour-science XYZ-to-linear-sRGB viewing transforms.
/// Spektrafilm's source DEFAULT gamut algorithm is CAM16-UCS, which is
/// not silently substituted by ACES RGC in this optional experiment.
enum OriginalScannerMath {

    /// The original ScanningStage calls colour.XYZ_to_RGB(..., illuminant=
    /// viewing_illuminant_xy, apply_cctf_encoding=False). Build-time
    /// colour-science generates the full transform for D50 and K75P.
    static func linearSRGB(xyz: [Double], viewing: String) -> [Double] {
        guard xyz.count == 3,
              let m = GeneratedScannerReference.transformsXYZToLinearSRGB[viewing],
              m.count == 9 else { return [0,0,0] }
        return (0..<3).map { target in
            (0..<3).reduce(0.0) { sum, channel in
                sum + xyz[channel] * m[channel*3+target]
            }
        }
    }

    /// Source gamut_compression.reinhard_knee(d, threshold=0, limit=1,
    /// power=6) and compress_rgb_aces_rgc. This matches the ACES option,
    /// not the upstream default CAM16-UCS perceptual gamut compression.
    static func compressACESRGC(_ rgb: [Double]) -> [Double] {
        guard rgb.count == 3 else { return rgb }
        let achromatic = rgb.max() ?? 0
        if !achromatic.isFinite || achromatic <= 1e-12 { return rgb }
        return rgb.map { channel in
            let distance = (achromatic-channel)/achromatic
            if distance <= 0 { return channel }
            let amount = distance/pow(1+pow(distance,6),1.0/6.0)
            return achromatic*(1-amount)
        }
    }

    /// Original ColorReferenceService.black_white_xyz_correction:
    /// y' = clip((white_target-black_target)/(Yw-Yb) * y +
    ///            black_target - slope*Yb, 0,1)
    /// XYZ scaled by y'/(y+1e-10) to preserve chromaticities.
    ///
    /// Reference endpoint densities for this port are calculated from
    /// film / print H-D limits. Unlike original printing exposure-aware
    /// references, this is currently an ENDPOINT approximation.
    static func correctBlackWhiteXYZ(
        _ xyz: [Double], yBlack: Double, yWhite: Double,
        encodedBlack: Double = 0.01, encodedWhite: Double = 0.98
    ) -> [Double] {
        guard xyz.count == 3, yBlack.isFinite, yWhite.isFinite,
              yWhite > yBlack + 1e-10 else { return xyz }
        let targetBlack = decodeSRGB(encodedBlack)
        let targetWhite = decodeSRGB(encodedWhite)
        let slope = (targetWhite-targetBlack)/(yWhite-yBlack+1e-10)
        let intercept = targetBlack-slope*yBlack
        let newY = max(0, min(1, slope*xyz[1]+intercept))
        let multiplier = newY/(xyz[1]+1e-10)
        return xyz.map { $0*multiplier }
    }

    static func decodeSRGB(_ x: Double) -> Double {
        x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4)
    }

    static func encodeSRGB(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92*x : 1.055*pow(x,1.0/2.4)-0.055
    }
}
