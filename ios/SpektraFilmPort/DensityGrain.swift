import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// On-device optical-density grain, between original film H-D development
/// and measured optical paper + viewing illuminant scan.
///
/// Original Spektrafilm (model/grain.py) builds random particles:
/// p=(density+d_min)/(d_max+d_min); saturation=1-p*uniformity;
/// seeds~Poisson(n/saturation); developed~Binomial(seeds,p);
/// D=(dmax/n)*developed*saturation - d_min.
/// This renderer uses the analytically equivalent mean/variance and a
/// normal approximation for Poisson-binomial particle counts, sampled
/// deterministically per pixel on the GPU. It is not an *exact* Poisson
/// draw and does not yet reproduce the source's 3 emulsion sublayers.
struct DensityGrainStage {
    let toDensity: Data
    let fromDensity: Data
    let cubeDimension: Int
    let maxDensity: [Double]    // normalized 0-1 cube channel -> optical D
    // v1.6 source measured 256×3×3 film H-D layers, cube per sublayer.
    var sublayerCubes: [Data] = []
    var sublayerRawMaxima: [Double] = []
}

struct DensityGrainSettings {
    let stage: DensityGrainStage
    var amount: Double = 1.0
    var seed: Double = 8888.0
    // Opt-in. Original v1.5 Poisson-binomial moment renderer remains
    // identical unless the user explicitly selects measured sublayers.
    var measuredSublayersEnabled = false
    // Source discrete Poisson-thinned particle samples instead of the
    // v1.6 Gaussian moment approximation. Requires measured sublayers.
    var discreteParticlesEnabled = false
    // v1.8 source-order Metal dye-cloud / clumping / reflect-convolution.
    // Strict opt-in: failures are thrown, never reverted to fast grain.
    var originalMetalEnabled = false
    // v1.8.5 opt-in source-sequential SciPy Poisson -> Binomial count stream;
    // unchanged original Metal hash particles remain the default.
    var sourceSciPySampling = false
}

enum DensityGrain {
    static let particleAreaUM2 = 0.2
    static let particleScale = [1.6, 1.6, 3.2]
    static let densityMinimum = [0.03, 0.03, 0.03]
    static let uniformity = [0.97, 0.99, 0.97]

    /// Standard deviation of upstream Poisson/binomial grain:
    ///   n=(pixel_um²)/(particle_area_um² * channel_scale)
    ///   saturation = 1-p*uniformity*(1-1e-6)
    ///   Var(D) = d_max² * p * saturation / n.
    /// This is the EXACT first and second moment of the upstream model,
    /// before sublayer simulation and particle blur.
    static func expectedVariance(density: Double, maximum: Double,
                                 pixelUM: Double, channel: Int) -> Double {
        guard (0..<3).contains(channel), maximum > 0, pixelUM > 0 else { return 0 }
        let dmin = densityMinimum[channel]
        let dmax = maximum + dmin
        let p = min(1-1e-6, max(1e-6, (density + dmin)/dmax))
        let saturation = 1 - p * uniformity[channel] * (1-1e-6)
        let n = pixelUM*pixelUM / (particleAreaUM2*particleScale[channel])
        return dmax*dmax*p*saturation/max(n, 1e-6)
    }

    /// Core Image kernels are evaluated on output pixels; destination pixels
    /// and seed generate repeatable hashes so slider refreshes are stable.
    /// We perturb real 3-channel film optical density from the first LUT,
    /// not post-scanner display RGB; the second LUT performs paper+scan.
    private static let densityParticleKernel = CIColorKernel(source: """
        float grainHash(vec2 p) {
            return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453);
        }
        float gaussianNoise(vec2 p, float seed) {
            float a = max(0.000001, grainHash(p + vec2(seed, seed*0.173)));
            float b = grainHash(p + vec2(seed*0.319 + 51.0, seed*0.777));
            return sqrt(-2.0 * log(a)) * cos(6.2831853 * b);
        }
        kernel vec4 densityParticles(
            __sample density, float maxR, float maxG, float maxB,
            float pixelUM, float amount, float seed
        ) {
            vec2 pos = destCoord();
            vec3 dmax = vec3(maxR,maxG,maxB);
            vec3 dm = vec3(0.03,0.03,0.03);
            vec3 fullMax = dmax + dm;
            vec3 d = clamp(density.rgb, 0.0, 1.0) * dmax;
            vec3 p = clamp((d + dm)/fullMax, 0.000001, 0.999999);
            vec3 saturation = 1.0 -
                p * vec3(0.97,0.99,0.97) * (1.0-0.000001);
            float pixelArea = pixelUM * pixelUM;
            vec3 n = pixelArea / (0.2 * vec3(1.6,1.6,3.2));
            vec3 dev = fullMax * sqrt(p * saturation / max(n, vec3(0.000001)));
            vec3 noise = vec3(
                gaussianNoise(pos + vec2(7.31, 0.19), seed),
                gaussianNoise(pos + vec2(37.81, 101.9), seed + 11.0),
                gaussianNoise(pos + vec2(231.7, 41.83), seed + 29.0)
            );
            vec3 outD = clamp(d + amount * dev * noise, vec3(0.0), dmax);
            return vec4(outD / dmax, 1.0);
        }
        """)

    static func apply(to source: CIImage,
                      settings: DensityGrainSettings) throws -> CIImage? {
        let stage = settings.stage
        guard stage.maxDensity.count == 3, stage.maxDensity.allSatisfy({
            $0.isFinite && $0 > 0
        }), stage.cubeDimension >= 9 else { return nil }

        let toDensity = CIFilter.colorCube()
        toDensity.inputImage = source
        toDensity.cubeDimension = Float(stage.cubeDimension)
        toDensity.cubeData = stage.toDensity
        guard let d = toDensity.outputImage else { return nil }

        // Original 36mm capture width mapped to the image's long axis.
        // This keeps approximately the same material grain scale across
        // preview and JPEG export dimensions.
        let pixelUM = 36_000.0 / max(source.extent.width, source.extent.height, 1)
        guard let scattered = try perturbDensityImage(
            d, settings: settings, pixelUM: pixelUM
        ) else { return nil }

        let paper = CIFilter.colorCube()
        paper.inputImage = scattered
        paper.cubeDimension = Float(stage.cubeDimension)
        paper.cubeData = stage.fromDensity
        return paper.outputImage?.cropped(to: source.extent)
    }

    /// Shared emulsion-density stage used by both v1.5 spatial DIR and
    /// the v1.2 standard density->paper path. This keeps full-res exports
    /// identical to previews apart from their physical pixel scale.
    static func perturbDensityImage(
        _ normalizedDensity: CIImage,
        settings: DensityGrainSettings,
        pixelUM: Double
    ) throws -> CIImage? {
        let stage = settings.stage
        if settings.originalMetalEnabled {
            guard settings.measuredSublayersEnabled else {
                throw OriginalMetalGrain.Failure.invalid(
                    "原版 Metal 模式必须开启实测三乳剂亚层"
                )
            }
            return try OriginalMetalGrain.render(
                normalizedDensity: normalizedDensity,
                sublayerCubes: stage.sublayerCubes,
                rawLayerMaxima: stage.sublayerRawMaxima,
                totalRanges: stage.maxDensity,
                cubeDimension: stage.cubeDimension,
                pixelUM: pixelUM, amount: settings.amount,
                seed: settings.seed,
                sourceSciPySampling: settings.sourceSciPySampling
            )
        }
        if settings.measuredSublayersEnabled {
            if settings.discreteParticlesEnabled {
                return OriginalDiscreteGrain.perturb(
                    normalizedDensity,
                    sublayerCubes: stage.sublayerCubes,
                    rawLayerMaxima: stage.sublayerRawMaxima,
                    totalRanges: stage.maxDensity,
                    cubeDimension: stage.cubeDimension,
                    pixelUM: pixelUM,
                    amount: settings.amount,
                    seed: settings.seed
                )
            }
            // Fail instead of silently using post-scan RGB or pretending
            // the old single-layer grain is the original sublayer model.
            return OriginalSublayerGrain.perturb(
                normalizedDensity,
                sublayerCubes: stage.sublayerCubes,
                rawLayerMaxima: stage.sublayerRawMaxima,
                totalRanges: stage.maxDensity,
                cubeDimension: stage.cubeDimension,
                pixelUM: pixelUM,
                amount: settings.amount,
                seed: settings.seed
            )
        }
        return perturbDensityImage(
            normalizedDensity,
            maxDensity: stage.maxDensity,
            pixelUM: pixelUM,
            amount: settings.amount,
            seed: settings.seed
        )
    }

    /// For independent native statistical tests only; zero-amount output
    /// should remain the unperturbed 0..1 optical density.
    static func perturbDensityImage(
        _ image: CIImage, maxDensity: [Double], pixelUM: Double,
        amount: Double, seed: Double
    ) -> CIImage? {
        guard maxDensity.count == 3, let kernel = densityParticleKernel else {
            return nil
        }
        return kernel.apply(
            extent: image.extent,
            arguments: [
                image,
                Float(maxDensity[0]), Float(maxDensity[1]), Float(maxDensity[2]),
                Float(pixelUM), Float(amount), Float(seed)
            ]
        )
    }
}
