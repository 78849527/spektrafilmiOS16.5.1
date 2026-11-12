import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// The first actual image-space processing stage in the iOS 16.5.1 port.
/// It implements the original apply_halation_um scatter+backreflection math
/// using Core Image Gaussian filters instead of upstream Python/Numba FIR/IIR.
///
/// ORDER: scatter -> 3 reflection bounces -> physically normalized output.
/// Source uses linear, unclamped film irradiance. This iOS stage operates on
/// gamma-decoded sRGB source pixels *before* spectral CIColorCube. Thus its
/// kernel formula, presets and weights are based on upstream code but this
/// is NOT yet numerically identical to upstream raw-sensitivity processing.
///
/// No fake grain is included here: density-dependent stochastic grain must
/// be attached to real emulsion-density buffers rather than RGB noise.
struct SpatialOpticsSettings: Equatable {
    var scatterAmount: Double = 0
    var halationAmount: Double = 0
    var filmUse = "still"
    var antihalation = "strong"

    var enabled: Bool { scatterAmount > 0 || halationAmount > 0 }
}

enum SpatialOptics {
    struct Preset: Equatable {
        let sigmaHalationUM: Double
        let strength: [Double]

        static func forFilm(use: String, antihalation: String) -> Preset {
            let sigma = use == "cine" ? 50.0 : 65.0
            let strength: [Double]
            switch antihalation {
            case "weak": strength = [0.08, 0.02, 0.0]
            case "no": strength = [0.30, 0.10, 0.015]
            default: strength = [0.015, 0.005, 0.0]
            }
            return Preset(sigmaHalationUM: sigma, strength: strength)
        }
    }

    // Physical defaults copied from src/spektrafilm/runtime/params_schema.py.
    static let scatterCoreUM = [2.2, 2.0, 1.6]
    static let scatterTailUM = [9.3, 9.7, 9.1]
    static let scatterTailWeight = [0.78, 0.65, 0.67]
    static let bounceCount = 3
    static let bounceDecay = 0.5

    // The original exponential PSF is approximated by these exact same
    // source-model Gaussian-mixture fit constants, from
    // src/spektrafilm/utils/fast_gaussian_filter.py.
    static let exponentialMixture: [(weight: Double, radiusRatio: Double)] = [
        (0.1633, 0.5360),
        (0.6496, 1.5236),
        (0.1870, 2.7684)
    ]

    /// Input and output are sRGB CIImages; filters run on a linearized image.
    /// Must be applied to the final preview/export resolution *before* LUT.
    static func apply(to image: CIImage, settings: SpatialOpticsSettings) -> CIImage {
        guard settings.enabled, !image.extent.isEmpty else { return image }
        let exposure = image.applyingFilter("CISRGBToneCurveToLinear")
        let longSide = max(1.0, image.extent.width, image.extent.height)
        // The original film exposure size defaults to 36x24mm; avoid fixed
        // pixel-radius halos that change physical width between preview/export.
        let micrometersPerPixel = 36_000.0 / longSide
        let scattered = scatter(exposure, amount: settings.scatterAmount,
                                micrometersPerPixel: micrometersPerPixel)
        let final = halation(scattered, amount: settings.halationAmount,
                             micrometersPerPixel: micrometersPerPixel,
                             preset: Preset.forFilm(
                                use: settings.filmUse,
                                antihalation: settings.antihalation
                             ))
        return final.applyingFilter("CILinearToSRGBToneCurve")
            .cropped(to: image.extent)
    }

    /// Original:
    /// E1=(1-s)E0 + s[(1-w)*Gaussian_core(E0)+w*Exponential_tail(E0)]
    private static func scatter(_ image: CIImage, amount: Double,
                                micrometersPerPixel: Double) -> CIImage {
        let s = min(1, max(0, amount))
        guard s > 0 else { return image }
        let coreRadius = scatterCoreUM.map { $0 / micrometersPerPixel }
        let tailRadius = scatterTailUM.map { $0 / micrometersPerPixel }
        let direct = weighted(image, [1-s, 1-s, 1-s])
        let core = gaussianWeighted(
            image, radii: coreRadius,
            weights: scatterTailWeight.map { s * (1-$0) }
        )
        var sum = add(direct, core)
        for mix in exponentialMixture {
            let part = gaussianWeighted(
                image,
                radii: tailRadius.map { $0 * mix.radiusRatio },
                weights: scatterTailWeight.map { s * $0 * mix.weight }
            )
            sum = add(sum, part)
        }
        return sum.cropped(to: image.extent)
    }

    /// Original:
    /// E2=(E1+Σ a_color * decay_k * G(sigma*sqrt(k))*E1)/(1+a_color)
    /// with k=1..3, rho=0.5 and per-film antihalation presets.
    private static func halation(_ image: CIImage, amount: Double,
                                 micrometersPerPixel: Double,
                                 preset: Preset) -> CIImage {
        let strength = min(3.0, max(0, amount))
        guard strength > 0 else { return image }

        let a = preset.strength.map { $0 * strength }
        let total = a.map { 1.0 / (1 + $0) }
        let radius = preset.sigmaHalationUM / micrometersPerPixel
        let normalizer = (0..<bounceCount).reduce(0.0) { sum, i in
            sum + pow(bounceDecay, Double(i))
        }
        var sum = weighted(image, total)

        for bounce in 1...bounceCount {
            let weight = pow(bounceDecay, Double(bounce-1)) / normalizer
            let part = gaussianWeighted(
                image, radii: Array(repeating: radius * sqrt(Double(bounce)), count: 3),
                weights: (0..<3).map { c in
                    a[c] * total[c] * weight
                }
            )
            sum = add(sum, part)
        }
        return sum.cropped(to: image.extent)
    }

    /// Select each channel from its own Gaussian blur. Source uses Gaussian
    /// reflect boundary; CI clamped-to-extent is a close GPU edge analog,
    /// with a different convolution implementation.
    private static func gaussianWeighted(
        _ image: CIImage, radii: [Double], weights: [Double]
    ) -> CIImage {
        var combined: CIImage?
        for channel in 0..<3 {
            if abs(weights[channel]) < 1e-12 { continue }
            let blurred: CIImage
            if radii[channel] <= 0.12 {
                blurred = image
            } else {
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = image.clampedToExtent()
                filter.radius = Float(min(120, radii[channel]))
                blurred = (filter.outputImage ?? image).cropped(to: image.extent)
            }
            let channelWeights = (0..<3).map { $0 == channel ? weights[channel] : 0 }
            let part = weighted(blurred, channelWeights)
            combined = combined.map { add($0, part) } ?? part
        }
        return combined ?? weighted(image, [0, 0, 0])
    }

    private static func weighted(_ image: CIImage, _ w: [Double]) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: w[0], y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: w[1], z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: w[2], w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    private static func add(_ lhs: CIImage, _ rhs: CIImage) -> CIImage {
        let f = CIFilter.additionCompositing()
        f.inputImage = rhs
        f.backgroundImage = lhs
        return (f.outputImage ?? lhs).cropped(to: lhs.extent)
    }

    /// Pure coefficients: tested independently against source-model formula.
    static func scatterKernelWeights(amount: Double, channel: Int) -> [Double] {
        let s = min(1, max(0, amount))
        let tail = scatterTailWeight[channel]
        return [1-s, s*(1-tail)] +
            exponentialMixture.map { s*tail*$0.weight }
    }

    static func halationKernelWeights(amount: Double,
                                      channel: Int,
                                      preset: Preset) -> [Double] {
        let a = preset.strength[channel] * min(3, max(0, amount))
        let normalizer = (0..<bounceCount).reduce(0.0) {
            $0 + pow(bounceDecay, Double($1))
        }
        return [1.0/(1+a)] + (1...bounceCount).map { k in
            a / (1+a) * pow(bounceDecay, Double(k-1)) / normalizer
        }
    }
}
