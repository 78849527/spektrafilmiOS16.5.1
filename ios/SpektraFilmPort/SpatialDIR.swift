import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Opt-in source DIR *spatial* coupler stage.
/// This is NOT a post-RGB filter: the inputs are Hanatos log10 film exposure
/// and the measured initial emulsion optical densities. Source sequence:
/// initial H-D -> density/silver -> donor/receiver matrix -> spatial diffusion
/// -> subtract inhibitor from log10 exposure -> pre-DIR corrected H-D curve
/// -> density grain -> spectral paper printing -> scanning.
/// Source-accurate FIR/YVV Float64 convolution is the default when spatial
/// DIR is enabled. CIImage Float32 intermediate buffers and cube LUT
/// interpolation remain separately approximate. A source-convolution error
/// throws rather than silently reverting to a CI Gaussian.
struct SpatialDIRStage {
    let rawLogCube: Data
    let initialDensityCube: Data
    let correctedDensityCube: Data
    let printCube: Data
    let sourceCubeSize: Int
    let correctedCubeSize: Int
    let densityRanges: [Double]
    let densityMaximum: [Double]
    let logExposureSpans: [Double]
    let donorReceiverMatrix: [Double]  // flattened donor row, receiver column
    let positive: Bool

    /// Four true Double source optical-cube node buffers. The exact DIR
    /// renderer must NEVER silently use the old Float32 LUT payload.
    /// Mobile CoreImage fast mode continues to use the packed Float32 cubes.
    struct Float64OpticalNodes {
        let raw: [Double]
        let initial: [Double]
        let corrected: [Double]
        let printed: [Double]

        func valid(sourceSize: Int, correctedSize: Int) -> Bool {
            let n = sourceSize * sourceSize * sourceSize * 4
            let m = correctedSize * correctedSize * correctedSize * 4
            return raw.count == n && initial.count == n &&
                corrected.count == m && printed.count == n &&
                (raw + initial + corrected + printed)
                    .allSatisfy { $0.isFinite }
        }

        /// Test-only identity optical baseline used by the existing
        /// independent upstream 2D physical-DIR fixtures.
        static func identity(sourceSize: Int, correctedSize: Int)
            -> Float64OpticalNodes {
            func cube(_ side: Int) -> [Double] {
                let delta = 1.0 / Double(side - 1)
                var samples = [Double]()
                samples.reserveCapacity(side * side * side * 4)
                for b in 0..<side {
                    for g in 0..<side {
                        for r in 0..<side {
                            samples.append(contentsOf: [
                                Double(r) * delta, Double(g) * delta,
                                Double(b) * delta, 1.0
                            ])
                        }
                    }
                }
                return samples
            }
            let source = cube(sourceSize)
            return Float64OpticalNodes(
                raw: source, initial: source,
                corrected: cube(correctedSize), printed: source
            )
        }
    }

    var float64OpticalNodes: Float64OpticalNodes? = nil

    var valid: Bool {
        sourceCubeSize >= 9 && correctedCubeSize >= 17 &&
        densityRanges.count == 3 && densityMaximum.count == 3 &&
        logExposureSpans.count == 3 && donorReceiverMatrix.count == 9 &&
        densityRanges.allSatisfy { $0.isFinite && $0 > 0 } &&
        logExposureSpans.allSatisfy { $0.isFinite && $0 > 0 }
        && (float64OpticalNodes?.valid(
            sourceSize: sourceCubeSize, correctedSize: correctedCubeSize
        ) ?? true)
    }
}

struct SpatialDIRSettings {
    var enabled = false
    var diffusionRadiusScale = 1.0
    var tailWeight = 0.06
    /// Enabled by default in the opt-in spatial DIR stage. The previous CI
    /// Gaussian approximation is opt-in only, never an implicit fallback.
    var sourceConvolutionEnabled = true
    /// Fixed microns-per-pixel only for the 2D Python/Swift test fixture.
    /// Production ALWAYS uses 36,000 μm divided by actual image long side.
    var referencePixelSizeUM: Double? = nil

    var valid: Bool {
        diffusionRadiusScale.isFinite &&
        (0.25...3.0).contains(diffusionRadiusScale) &&
        tailWeight.isFinite && (0...0.25).contains(tailWeight) &&
        (referencePixelSizeUM == nil ||
         (referencePixelSizeUM!.isFinite && referencePixelSizeUM! > 0))
    }
}

enum SpatialDIR {
    static let gaussianSigmaUM = 20.0
    static let exponentialTailUM = 200.0
    // Same Gaussian mixture used by original fast_exponential_filter.
    static let exponentialMixture: [(weight: Double, ratio: Double)] = [
        (0.1633, 0.5360),
        (0.6496, 1.5236),
        (0.1870, 2.7684)
    ]

    /// Pure CPU source einsum, for independent numeric regression.
    static func inhibition(density: [Double], maximum: [Double],
                           matrix: [Double], positive: Bool) -> [Double] {
        precondition(density.count == 3 && maximum.count == 3 &&
                     matrix.count == 9)
        let silver = (0..<3).map {
            positive ? maximum[$0] - density[$0] : density[$0]
        }
        return (0..<3).map { receiver in
            (0..<3).reduce(0.0) { accumulator, donor in
                accumulator + silver[donor]*matrix[donor*3+receiver]
            }
        }
    }

    private static let tailKernel = CIColorKernel(source: """
        kernel vec4 sourceDIRDiffusion(__sample core, __sample one,
                                      __sample two, __sample three,
                                      float tailWeight) {
            vec3 tail = 0.1633 * one.rgb + 0.6496 * two.rgb
                        + 0.1870 * three.rgb;
            return vec4((1.0-tailWeight)*core.rgb +
                        tailWeight*tail, 1.0);
        }
        """)

    private static let subtractionKernel = CIColorKernel(source: """
        kernel vec4 sourceDIRSubtract(__sample originalLog,
                                      __sample inhibitor,
                                      float spanR, float spanG, float spanB) {
            vec3 spans = vec3(spanR, spanG, spanB);
            vec3 corrected = originalLog.rgb -
                             inhibitor.rgb / spans;
            return vec4(clamp(corrected, 0.0, 1.0), 1.0);
        }
        """)

    private static func gaussian(_ image: CIImage, sigma: Double) -> CIImage {
        if sigma < 0.12 { return image }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        // Source physical sigmas remain resolution-aware; CoreImage
        // Gaussian radius is an approximation at reflect image boundaries.
        blur.radius = Float(min(120, sigma))
        return (blur.outputImage ?? image).cropped(to: image.extent)
    }

    /// Computes source inhibitor correction at actual output-pixel scale.
    /// Both preview and export invoke this SAME code path at their own sizes.
    static func apply(to source: CIImage, stage: SpatialDIRStage,
                      settings: SpatialDIRSettings,
                      grain: DensityGrainSettings?,
                      stageObserver: ((String, CIImage) -> Void)? = nil
    ) throws -> CIImage? {
        guard settings.enabled, settings.valid, stage.valid,
              !source.extent.isEmpty else { return nil }
        if settings.sourceConvolutionEnabled {
            // Native source-precision mode: Float32 image/cube boundary,
            // Double trilinear 3D LUT and upstream FIR/YVV on the actual
            // 2D frame. No cascading CIColorCube quantization, no silent
            // fallback to the mobile Core Image approximation.
            return try SourceSpatialDIRConvolution.applyExactImagePath(
                to:source,stage:stage,settings:settings,grain:grain,
                stageObserver:stageObserver
            )
        }
        guard let tailKernel, let subtractionKernel else {
            throw SourceSpatialDIRConvolution.Failure.invalid(
                "显式移动快速 DIR 选项缺少 Core Image 内核"
            )
        }

        let rawCube = CIFilter.colorCube()
        rawCube.inputImage = source
        rawCube.cubeDimension = Float(stage.sourceCubeSize)
        rawCube.cubeData = stage.rawLogCube
        guard let raw = rawCube.outputImage else { return nil }
        stageObserver?("raw",raw)

        let initCube = CIFilter.colorCube()
        initCube.inputImage = source
        initCube.cubeDimension = Float(stage.sourceCubeSize)
        initCube.cubeData = stage.initialDensityCube
        guard let initial = initCube.outputImage else { return nil }
        stageObserver?("initial",initial)

        // CIColorMatrix computes source contract('ijk,km->ijm').
        // Inputs are normalized densities, so matrix columns include
        // per-channel density range. Reversal uses silver = max - density.
        let sign = stage.positive ? -1.0 : 1.0
        var coefficients = [[Double]](
            repeating: [Double](repeating: 0, count: 3), count: 3
        )
        var bias = [Double](repeating: 0, count: 3)
        for receiver in 0..<3 {
            for donor in 0..<3 {
                let m = stage.donorReceiverMatrix[donor*3+receiver]
                coefficients[receiver][donor] =
                    sign*m*stage.densityRanges[donor]
                if stage.positive {
                    bias[receiver] += m*stage.densityMaximum[donor]
                }
            }
        }

        let color = CIFilter.colorMatrix()
        color.inputImage = initial
        color.rVector = CIVector(x: coefficients[0][0],
                                 y: coefficients[0][1],
                                 z: coefficients[0][2], w: 0)
        color.gVector = CIVector(x: coefficients[1][0],
                                 y: coefficients[1][1],
                                 z: coefficients[1][2], w: 0)
        color.bVector = CIVector(x: coefficients[2][0],
                                 y: coefficients[2][1],
                                 z: coefficients[2][2], w: 0)
        color.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        color.biasVector = CIVector(x: bias[0], y: bias[1],
                                    z: bias[2], w: 0)
        guard let inhibitors = color.outputImage?.cropped(to: source.extent)
        else { return nil }
        stageObserver?("inhibitors",inhibitors)

        let imageLongSide = max(1, source.extent.width, source.extent.height)
        let pixelUM = settings.referencePixelSizeUM ?? (36_000.0 / imageLongSide)
        let coreSigma = gaussianSigmaUM*settings.diffusionRadiusScale/pixelUM
        let tailSigma = exponentialTailUM*settings.diffusionRadiusScale/pixelUM
        // Explicit mobile fast mode ONLY. Source mode returned earlier.
        let core = gaussian(inhibitors,sigma:coreSigma)
        let tail0 = gaussian(
            inhibitors,sigma:tailSigma*exponentialMixture[0].ratio
        )
        let tail1 = gaussian(
            inhibitors,sigma:tailSigma*exponentialMixture[1].ratio
        )
        let tail2 = gaussian(
            inhibitors,sigma:tailSigma*exponentialMixture[2].ratio
        )
        guard let diffused=tailKernel.apply(
            extent:source.extent,
            arguments:[core,tail0,tail1,tail2,Float(settings.tailWeight)]
        ) else {
            throw SourceSpatialDIRConvolution.Failure.invalid(
                "移动快速 Core Image DIR 扩散内核生成失败"
            )
        }

        stageObserver?("diffused",diffused)
        // Exposure subtraction before pre-DIR corrected paper H-D/scan.
        guard let logCorrected = subtractionKernel.apply(
            extent: source.extent,
            arguments: [raw, diffused,
                        Float(stage.logExposureSpans[0]),
                        Float(stage.logExposureSpans[1]),
                        Float(stage.logExposureSpans[2])]
        ) else { return nil }
        stageObserver?("log",logCorrected)

        let correctedCube = CIFilter.colorCube()
        correctedCube.inputImage = logCorrected
        correctedCube.cubeDimension = Float(stage.correctedCubeSize)
        correctedCube.cubeData = stage.correctedDensityCube
        guard var density = correctedCube.outputImage else { return nil }

        stageObserver?("densityPreGrain",density)
        if let grain, grain.amount > 0 {
            guard let result = try DensityGrain.perturbDensityImage(
                density, settings: grain, pixelUM: pixelUM
            ) else { return nil }
            density = result
        }
        let printed = CIFilter.colorCube()
        printed.inputImage = density
        printed.cubeDimension = Float(stage.sourceCubeSize)
        printed.cubeData = stage.printCube
        let result=printed.outputImage?.cropped(to: source.extent)
        if let result { stageObserver?("printed",result) }
        return result
    }
}
