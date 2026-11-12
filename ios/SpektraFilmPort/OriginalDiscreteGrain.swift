import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Original spektrafilm.model.grain.layer_particle_model discrete particle
/// law, evaluated BEFORE spectral printing/scanning. Source draws
/// N ~ Poisson(n/saturation), then K | N ~ Binomial(N, p).
///
/// By Poisson thinning, marginal K is EXACTLY Poisson(n*p/saturation).
/// We draw that single Poisson directly: no post-RGB approximation.
/// For lambda < 30, inverse-CDF is exact modulo Float32 rounding.
/// For lambda >= 30, PTRS transformed rejection uses a Stirling-corrected
/// log-factorial; bounded GPU iterations have a very rare normal fallback.
/// This reproduces the source's ONE-PIXEL distribution, not Python's
/// particular RNG sequence. Original dye-cloud/microstructure/blur and
/// full spectral pixel pipeline still have documented mobile differences.
enum OriginalDiscreteGrain {
    /// The source particle D for a given integer developed count.
    static func opticalDensity(
        count: Double, densityMaximum: Double, layerMinimum: Double,
        numberOfParticles: Double, saturation: Double
    ) -> Double {
        (densityMaximum + layerMinimum) /
            max(1e-8, numberOfParticles) * saturation * count
    }

    /// Original particle count after Poisson thinning: exact marginal
    /// distribution for Poisson-seeded Binomial development.
    static func poissonRate(n: Double, probability: Double,
                            saturation: Double) -> Double {
        max(0, n * probability / max(1e-8, saturation))
    }

    private static let discreteKernel = CIColorKernel(source: """
        float pHash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453);
        }
        float pUniform(vec2 pos, float seed, float iteration) {
            vec2 jitter = vec2(
                seed*0.12413 + iteration*13.781,
                seed*0.71427 + iteration*3.179
            );
            return clamp(pHash(pos + jitter), 0.000001, 0.999999);
        }
        float pGaussian(vec2 pos, float seed) {
            float u = pUniform(pos, seed, 17.1);
            float v = pUniform(pos, seed, 41.7);
            return sqrt(-2.0*log(u))*cos(6.28318530718*v);
        }
        float pLogFactorial(float k) {
            if (k < 2.0) { return 0.0; }
            if (k < 30.0) {
                float logfac = 0.0;
                for (int i = 2; i < 30; i++) {
                    if (float(i) > k) { break; }
                    logfac += log(float(i));
                }
                return logfac;
            }
            float inv = 1.0/k;
            float inv2 = inv*inv;
            return (k+0.5)*log(k)-k+0.9189385332046727 +
                   inv/12.0 - inv*inv2/360.0 +
                   inv*inv2*inv2/1260.0;
        }
        float pDrawPoisson(float lambda, vec2 pos, float seed) {
            if (lambda <= 0.0) { return 0.0; }
            if (lambda < 30.0) {
                // Exact inverse Poisson CDF, one independent uniform.
                float u = pUniform(pos, seed, 0.0);
                float prob = exp(-lambda);
                float cdf = prob;
                float result = 0.0;
                for (int i = 1; i <= 160; i++) {
                    if (u <= cdf) { break; }
                    prob *= lambda / float(i);
                    cdf += prob;
                    result = float(i);
                }
                return result;
            }
            // Hoermann PTRS, an efficient transformed-rejection Poisson
            // sampler. Float32 Stirling correction is accurate at >=30.
            float root = sqrt(lambda);
            float b = 0.931 + 2.53*root;
            float a = -0.059 + 0.02483*b;
            float invAlpha = 1.1239 + 1.1328/(b-3.4);
            float vR = 0.9277 - 3.6224/(b-2.0);
            for (int i = 0; i < 40; i++) {
                float u = pUniform(pos, seed, float(i)*2.0+1.0)-0.5;
                float v = pUniform(pos, seed, float(i)*2.0+2.0);
                float us = 0.5-abs(u);
                if (us < 0.000001) { continue; }
                float k = floor((2.0*a/us+b)*u+lambda+0.43);
                if (k < 0.0) { continue; }
                if (us >= 0.07 && v <= vR) { return k; }
                if (us < 0.013 && v > us) { continue; }
                float ratio = v*invAlpha/(a/(us*us)+b);
                float target = -lambda+k*log(lambda)-pLogFactorial(k);
                if (log(max(0.0000000001,ratio)) <= target) {
                    return k;
                }
            }
            // Numerical path only, if rejection exceeds 40 attempts.
            return max(0.0,floor(lambda + root*pGaussian(pos,seed)+0.5));
        }
        vec3 pLayer(vec3 normalizedD, vec3 peak, vec3 fraction,
                    float layerScale, float pixelUM, float seed,
                    float layerOffset, vec2 pos) {
            vec3 dm = fraction*vec3(0.03,0.03,0.03);
            vec3 fullMax = peak+dm;
            vec3 d = clamp(normalizedD,0.0,1.0)*peak;
            vec3 p = clamp((d+dm)/max(fullMax,vec3(0.000001)),
                           0.000001,0.999999);
            vec3 saturation =
                1.0-p*vec3(0.97,0.99,0.97)*(1.0-0.000001);
            vec3 n = pixelUM*pixelUM*fraction /
                     (0.2*vec3(1.6,1.6,3.2)*layerScale);
            vec3 rate = n*p/saturation;
            vec3 k = vec3(
                pDrawPoisson(rate.r,pos+vec2(7.31+layerOffset,0.19),
                             seed+layerOffset),
                pDrawPoisson(rate.g,pos+vec2(37.81,101.90+layerOffset),
                             seed+11.0+layerOffset),
                pDrawPoisson(rate.b,pos+vec2(231.7+layerOffset,41.83),
                             seed+29.0+layerOffset)
            );
            return fullMax/max(n,vec3(0.000001))*saturation*k;
        }
        kernel vec4 discreteSublayerParticles(
            __sample base, __sample sl0, __sample sl1, __sample sl2,
            vec4 totalRanges, vec4 maximum0, vec4 maximum1, vec4 maximum2,
            vec4 fractions0, vec4 fractions1, vec4 fractions2,
            float pixelUM, float amount, float seed
        ) {
            vec2 pos = destCoord();
            vec3 particles = pLayer(sl0.rgb,maximum0.rgb,fractions0.rgb,
                                    2.0,pixelUM,seed,0.0,pos);
            particles += pLayer(sl1.rgb,maximum1.rgb,fractions1.rgb,
                                1.0,pixelUM,seed,71.0,pos);
            particles += pLayer(sl2.rgb,maximum2.rgb,fractions2.rgb,
                                0.5,pixelUM,seed,163.0,pos);
            vec3 sampledDensity = particles-vec3(0.03,0.03,0.03);
            vec3 originalDensity = base.rgb*totalRanges.rgb;
            vec3 resultDensity = clamp(
                originalDensity+amount*(sampledDensity-originalDensity),
                vec3(0.0), totalRanges.rgb
            );
            return vec4(resultDensity/totalRanges.rgb,1.0);
        }
        """)

    static func perturb(
        _ density: CIImage,
        sublayerCubes: [Data], rawLayerMaxima: [Double],
        totalRanges: [Double], cubeDimension: Int,
        pixelUM: Double, amount: Double, seed: Double
    ) -> CIImage? {
        guard sublayerCubes.count == 3,
              rawLayerMaxima.count == 9,
              totalRanges.count == 3,
              let kernel = discreteKernel,
              (9...33).contains(cubeDimension),
              pixelUM > 0, pixelUM.isFinite,
              amount.isFinite && (0...3).contains(amount),
              seed.isFinite,
              rawLayerMaxima.allSatisfy({ $0 > 0 && $0.isFinite }),
              totalRanges.allSatisfy({ $0 > 0 && $0.isFinite })
        else { return nil }
        if amount <= 0 { return density }
        let count = cubeDimension*cubeDimension*cubeDimension*16
        guard sublayerCubes.allSatisfy({ $0.count == count }) else {
            return nil
        }
        var layers = [CIImage]()
        for data in sublayerCubes {
            let cube = CIFilter.colorCube()
            cube.inputImage = density
            cube.cubeDimension = Float(cubeDimension)
            cube.cubeData = data
            guard let output = cube.outputImage else { return nil }
            layers.append(output)
        }
        var fractions = [Double](repeating: 0, count: 9)
        for channel in 0..<3 {
            let sum = (0..<3).reduce(0.0) { $0 +
                rawLayerMaxima[$1*3+channel]
            }
            if sum <= 0 { return nil }
            for layer in 0..<3 {
                fractions[layer*3+channel] =
                    rawLayerMaxima[layer*3+channel]/sum
            }
        }
        func vector(_ values: [Double]) -> CIVector {
            CIVector(x: values[0], y: values[1], z: values[2], w: 0)
        }
        let peaks = (0..<3).map { layer in
            vector(Array(rawLayerMaxima[layer*3..<(layer+1)*3]))
        }
        let weights = (0..<3).map { layer in
            vector(Array(fractions[layer*3..<(layer+1)*3]))
        }
        guard let out = kernel.apply(
            extent: density.extent,
            arguments: [
                density, layers[0], layers[1], layers[2],
                vector(totalRanges),
                peaks[0], peaks[1], peaks[2],
                weights[0], weights[1], weights[2],
                Float(pixelUM), Float(amount), Float(seed)
            ]
        ) else { return nil }
        // Maintain physical optical-density order and legacy v1.6
        // post-formation spatial grain blur; do not process scan RGB.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = out.clampedToExtent()
        blur.radius = Float(OriginalSublayerGrain.finalBlurPixels)
        return (blur.outputImage ?? out).cropped(to: density.extent)
    }
}
