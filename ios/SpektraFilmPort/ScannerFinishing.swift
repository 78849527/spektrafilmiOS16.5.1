import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Image-space output scanner finishing. Upstream ScanningStage uses
/// add_glare in XYZ *before* gamut compression, then lens blur and
/// unsharp mask in linear RGB. This lightweight iOS approximation
/// applies the identical per-channel unsharp formula to linearized
/// display RGB and a low-energy print glare approximation.
/// It does NOT claim the original XYZ/spectral ordering.
struct ScannerFinishSettings {
    var enabled = false
    var applyGlare = false
    var unsharpAmount = 0.7
    var glarePercent = 0.03
    var seed = 8888.0
}

enum ScannerFinishing {
    /// Source model.glare.compute_random_glare_amount draws a
    /// lognormal distribution with mean percent and std
    /// roughness * percent, then filters sigma 0.5 and divides by 100.
    /// Here tiny glare is simulated via deterministic per-pixel
    /// lognormal RGB additions BEFORE unsharp but AFTER LUT.
    /// Film direct-scan does not have print glare.
    private static let printGlareKernel = CIColorKernel(source: """
        float scannerHash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453);
        }
        kernel vec4 sourcePrintGlare(
            __sample image, float glarePercent, float seed
        ) {
            vec2 xy = destCoord();
            float u1 = max(0.000001, scannerHash(xy+vec2(seed,17.0)));
            float u2 = scannerHash(xy+vec2(seed*0.731,213.0));
            float z = sqrt(-2.0*log(u1)) * cos(6.283185307*u2);
            float sigma = sqrt(log(1.0+0.7*0.7));
            float mean = log(max(0.0000001,glarePercent))-0.5*sigma*sigma;
            float luminance = exp(mean+sigma*z) * 0.01;
            return vec4(image.rgb+vec3(luminance),image.a);
        }
        """)

    /// Explicit energy-combining RGB kernel; Porter-Duff compositing
    /// is not valid for signed unsharp subtraction.
    private static let unsharpKernel = CIColorKernel(source: """
        kernel vec4 scannerUnsharp(__sample original, __sample blurred,
                                  float amount) {
            return vec4(original.rgb + amount*(original.rgb-blurred.rgb),
                        original.a);
        }
        """)

    static func apply(to image: CIImage, settings: ScannerFinishSettings) -> CIImage {
        guard settings.enabled, !image.extent.isEmpty else { return image }
        var linear = image.applyingFilter("CISRGBToneCurveToLinear")
        if settings.applyGlare && settings.glarePercent > 0,
           let kernel = printGlareKernel,
           let raw = kernel.apply(
                extent: linear.extent,
                arguments: [linear, Float(settings.glarePercent), Float(settings.seed)]
           ) {
            // Upstream glare is blurred with sigma=.5 pixel in XYZ.
            let f = CIFilter.gaussianBlur()
            f.inputImage = raw.clampedToExtent()
            f.radius = 0.5
            linear = (f.outputImage ?? raw).cropped(to: linear.extent)
        }
        let amount = min(2.0,max(0,settings.unsharpAmount))
        if amount > 0.0001 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = linear.clampedToExtent()
            blur.radius = 0.7
            let softened = (blur.outputImage ?? linear).cropped(to: linear.extent)
            if let kernel = unsharpKernel,
               let sharp = kernel.apply(
                    extent: linear.extent,
                    arguments: [linear, softened, Float(amount)]
               ) {
                linear = sharp
            }
        }
        return linear.applyingFilter("CILinearToSRGBToneCurve")
            .cropped(to: image.extent)
    }

    static func unsharpScalar(original: Double, blurred: Double,
                              amount: Double) -> Double {
        original+amount*(original-blurred)
    }
}
