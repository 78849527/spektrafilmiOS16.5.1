import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Experimental optical-density emulsion sublayer grain port from
/// spektrafilm.model.grain.apply_grain_to_density_layers.
///
/// Film-specific, measured 3 x 3 density_curves_layers are inverted from
/// the measured total density curve (negative AND positive/reversal).
/// Each dye sublayer has its own probability, maximum optical density,
/// seed count, particle scale and independent random draw. The source
/// samples Poisson(seed count) then Binomial; the iOS shader retains
/// its exact mean/variance analytically but draws a Gaussian surrogate.
/// It is NOT a claim of byte-identical Poisson/binomial distribution.
/// This operates before printing/scanning and never adds RGB screen noise.
enum OriginalSublayerGrain {
    static let sublayerScales: [Double] = [2.0, 1.0, 0.5]
    static let channelScales: [Double] = [1.6, 1.6, 3.2]
    static let densityMinimum: [Double] = [0.03, 0.03, 0.03]
    static let uniformity: [Double] = [0.97, 0.99, 0.97]
    static let particleAreaUM2 = 0.2
    static let finalBlurPixels = 0.65
    static let dyeCloudBlurUM = 1.0

    /// Faithful reference mean/variance BEFORE source's cloud blur,
    /// microstructure and final spatial Gaussian (model/grain.py).
    /// Array indexing: [sublayer * 3 + color].
    static func moments(
        densityLayers: [Double], rawLayerMaxima: [Double],
        pixelUM: Double
    ) -> (mean: [Double], variance: [Double]) {
        precondition(densityLayers.count == 9 && rawLayerMaxima.count == 9)
        precondition(pixelUM.isFinite && pixelUM > 0)
        var resultMean = [Double](repeating: 0, count: 3)
        var resultVariance = [Double](repeating: 0, count: 3)
        for channel in 0..<3 {
            let totalMaximum = (0..<3).reduce(0.0) { value, layer in
                value + max(0, rawLayerMaxima[layer*3 + channel])
            }
            precondition(totalMaximum > 0)
            for layer in 0..<3 {
                let rawMax = max(0, rawLayerMaxima[layer*3 + channel])
                let fraction = rawMax / totalMaximum
                let minLayer = densityMinimum[channel] * fraction
                let fullMax = rawMax + minLayer
                let d = densityLayers[layer*3 + channel]
                let p = min(1-1e-6, max(1e-6, (d+minLayer)/fullMax))
                let saturation = 1 - p*uniformity[channel]*(1-1e-6)
                let area = particleAreaUM2 * channelScales[channel] *
                    sublayerScales[layer]
                let n = pixelUM * pixelUM * fraction / area
                // source: E[particle D] = (fullMax/n)*(n/sat)*p*sat = p*fullMax
                resultMean[channel] += p*fullMax
                resultVariance[channel] += fullMax*fullMax*p*saturation /
                    max(n, 1e-6)
            }
            resultMean[channel] -= densityMinimum[channel]
        }
        return (resultMean, resultVariance)
    }

    private static let sublayersKernel = CIColorKernel(source: """
        float layerHash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453);
        }
        float layerGaussian(vec2 p, float seed) {
            float a = max(0.000001, layerHash(p + vec2(seed, seed*0.173)));
            float b = layerHash(p + vec2(seed*0.319+51.0, seed*0.777));
            return sqrt(-2.0 * log(a)) * cos(6.2831853*b);
        }
        vec3 layerPerturb(vec3 normalizedD, vec3 peak, vec3 fractions,
                          float layerScale, float pixelUM, float seed,
                          float layerOffset, vec2 pos) {
            vec3 dm = fractions * vec3(0.03,0.03,0.03);
            vec3 fullMax = peak + dm;
            vec3 d = clamp(normalizedD,0.0,1.0)*peak;
            vec3 p = clamp((d+dm)/max(fullMax,vec3(0.000001)),
                           0.000001,0.999999);
            vec3 sat = 1.0-p*vec3(0.97,0.99,0.97)*(1.0-0.000001);
            vec3 n = pixelUM*pixelUM*fractions /
                     (0.2*vec3(1.6,1.6,3.2)*layerScale);
            vec3 sd = fullMax * sqrt(
                p*sat/max(n,vec3(0.000001))
            );
            vec3 noise = vec3(
                layerGaussian(pos+vec2(7.31+layerOffset,0.19),seed+layerOffset),
                layerGaussian(pos+vec2(37.81,101.90+layerOffset),seed+11.0+layerOffset),
                layerGaussian(pos+vec2(231.7+layerOffset,41.83),seed+29.0+layerOffset)
            );
            return sd*noise;
        }
        kernel vec4 measuredThreeSublayers(
            __sample base, __sample sl0, __sample sl1, __sample sl2,
            vec4 totalRanges, vec4 maximum0, vec4 maximum1, vec4 maximum2,
            vec4 fractions0, vec4 fractions1, vec4 fractions2,
            float pixelUM, float amount, float seed
        ) {
            // Precisely nine independent source-model channel/sublayer
            // particle distributions; the normal approximation preserves
            // original first/second moments but not the discrete tails.
            vec2 pos = destCoord();
            vec3 noise = layerPerturb(sl0.rgb,maximum0.rgb,fractions0.rgb,
                                      2.0,pixelUM,seed,0.0,pos);
            noise += layerPerturb(sl1.rgb,maximum1.rgb,fractions1.rgb,
                                  1.0,pixelUM,seed,71.0,pos);
            noise += layerPerturb(sl2.rgb,maximum2.rgb,fractions2.rgb,
                                  0.5,pixelUM,seed,163.0,pos);
            vec3 outD = clamp(base.rgb*totalRanges.rgb + amount*noise,
                              vec3(0.0),totalRanges.rgb);
            return vec4(outD/totalRanges.rgb,1.0);
        }
        """)

    /// Source three emulsion sublayer densities and stock maxima are
    /// sampled through three original measured-H-D 3D LUTs. This is a
    /// distinct branch from the existing v1.2 single-density kernel.
    static func perturb(
        _ normalizedDensity: CIImage,
        sublayerCubes: [Data],
        rawLayerMaxima: [Double],
        totalRanges: [Double],
        cubeDimension: Int,
        pixelUM: Double,
        amount: Double,
        seed: Double
    ) -> CIImage? {
        guard let kernel = sublayersKernel, sublayerCubes.count == 3,
              rawLayerMaxima.count == 9, totalRanges.count == 3,
              (9...33).contains(cubeDimension), pixelUM > 0,
              pixelUM.isFinite, amount.isFinite, seed.isFinite,
              rawLayerMaxima.allSatisfy({ $0.isFinite && $0 > 0 }),
              totalRanges.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }
        let expectedBytes = cubeDimension*cubeDimension*cubeDimension*16
        guard sublayerCubes.allSatisfy({ $0.count == expectedBytes }) else {
            return nil
        }
        var layers = [CIImage]()
        for data in sublayerCubes {
            let filter = CIFilter.colorCube()
            filter.inputImage = normalizedDensity
            filter.cubeData = data
            filter.cubeDimension = Float(cubeDimension)
            guard let layer = filter.outputImage else { return nil }
            layers.append(layer)
        }
        var fractions = [Double](repeating: 0, count: 9)
        for channel in 0..<3 {
            let sum = (0..<3).reduce(0.0) { $0 + rawLayerMaxima[$1*3+channel] }
            guard sum > 0 else { return nil }
            for layer in 0..<3 {
                fractions[layer*3+channel] =
                    rawLayerMaxima[layer*3+channel]/sum
            }
        }
        func vector(_ values: [Double]) -> CIVector {
            CIVector(x: values[0], y: values[1], z: values[2], w: 0)
        }
        let peakVectors = (0..<3).map { layer in
            vector(Array(rawLayerMaxima[(layer*3)..<(layer*3+3)]))
        }
        let fractionVectors = (0..<3).map { layer in
            vector(Array(fractions[(layer*3)..<(layer*3+3)]))
        }
        let total = vector(totalRanges)
        guard let densityOut = kernel.apply(
            extent: normalizedDensity.extent,
            arguments: [
                normalizedDensity, layers[0], layers[1], layers[2],
                total, peakVectors[0], peakVectors[1], peakVectors[2],
                fractionVectors[0], fractionVectors[1], fractionVectors[2],
                Float(pixelUM), Float(min(3,max(0,amount))), Float(seed)
            ]
        ) else { return nil }
        if amount <= 0 { return normalizedDensity }
        // Upstream final grain.blur=0.65 px. Keep the same physical
        // post-density stage; original Poisson/dye-cloud blur and
        // tiny-scale lognormal microstructure remain approximations.
        let smoother = CIFilter.gaussianBlur()
        smoother.inputImage = densityOut.clampedToExtent()
        smoother.radius = Float(finalBlurPixels)
        return (smoother.outputImage ?? densityOut)
            .cropped(to: normalizedDensity.extent)
    }
}
