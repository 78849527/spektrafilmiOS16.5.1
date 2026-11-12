import Foundation
import CoreGraphics
import CoreImage

/// Float64 upstream NumPy sublayer moment and native CoreImage nine-noise
/// density simulation checks. Tests the actual GPU-compatible CIColorKernel.
@main
struct SublayerGrainValidation {
    static func near(_ observed: Double, _ expected: Double,
                     _ title: String, tolerance: Double) {
        precondition(observed.isFinite &&
                     abs(observed-expected) <= tolerance,
                     "\(title): \(observed) != \(expected)")
    }

    static func identityCube(_ size: Int) -> Data {
        var f = [Float]()
        let step = Float(1.0/Double(size-1))
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    f.append(contentsOf: [
                        Float(r)*step,Float(g)*step,Float(b)*step,1
                    ])
                }
            }
        }
        return f.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: $0.count*4)
        }
    }

    static func render(_ image: CIImage, side: Int) -> [Float] {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var output = [Float](repeating: 0, count: side*side*4)
        output.withUnsafeMutableBytes { raw in
            context.render(
                image, toBitmap: raw.baseAddress!,
                rowBytes: side*16,
                bounds: CGRect(x: 0,y: 0,width: side,height: side),
                format: .RGBAf, colorSpace: space
            )
        }
        return output
    }

    static func main() {
        setbuf(stdout, nil)
        precondition(GeneratedSublayerGrainReference.samples.count == 16)
        for sample in GeneratedSublayerGrainReference.samples {
            let result = OriginalSublayerGrain.moments(
                densityLayers: sample.layers,
                rawLayerMaxima: sample.layerRawMaximum,
                pixelUM: GeneratedSublayerGrainReference.pixelUM
            )
            for channel in 0..<3 {
                near(result.mean[channel],sample.mean[channel],
                     "NumPy source sublayer expected mean",tolerance:1e-11)
                near(result.variance[channel],sample.variance[channel],
                     "NumPy source Poisson/Binomial variance",tolerance:1e-11)
            }
        }
        print("PASS: 16 original NumPy grain moments (4 measured film stocks × 4 densities), 9 independent emulsion layers.")

        let side = 160
        let source = CIImage(color: CIColor(red:0.4,green:0.4,blue:0.4))
            .cropped(to: CGRect(x:0,y:0,width:side,height:side))
        let maxima = [
            0.7,0.7,0.7, 0.8,0.6,0.8, 0.7,0.9,0.8
        ]
        let total = [2.2,2.2,2.3]
        let lut = identityCube(9)
        let args = (
            sublayerCubes:[lut,lut,lut],
            rawLayerMaxima:maxima,
            totalRanges:total
        )
        guard let identity = OriginalSublayerGrain.perturb(
            source, sublayerCubes: args.sublayerCubes,
            rawLayerMaxima: args.rawLayerMaxima,
            totalRanges: args.totalRanges,
            cubeDimension: 9, pixelUM: 9, amount: 0, seed: 8888
        ), let noisy = OriginalSublayerGrain.perturb(
            source, sublayerCubes: args.sublayerCubes,
            rawLayerMaxima: args.rawLayerMaxima,
            totalRanges: args.totalRanges,
            cubeDimension: 9, pixelUM: 9, amount: 1, seed: 8888
        ), let again = OriginalSublayerGrain.perturb(
            source, sublayerCubes: args.sublayerCubes,
            rawLayerMaxima: args.rawLayerMaxima,
            totalRanges: args.totalRanges,
            cubeDimension: 9, pixelUM: 9, amount: 1, seed: 8888
        ), let newSeed = OriginalSublayerGrain.perturb(
            source, sublayerCubes: args.sublayerCubes,
            rawLayerMaxima: args.rawLayerMaxima,
            totalRanges: args.totalRanges,
            cubeDimension: 9, pixelUM: 9, amount: 1, seed: 7777
        ) else {
            fatalError("Source three-layer CoreImage grain kernel failed")
        }
        let baseline = render(source, side: side)
        let still = render(identity, side: side)
        let processed = render(noisy, side: side)
        let repeatResult = render(again, side: side)
        let changedSeed = render(newSeed, side: side)
        var deltaSum = 0.0
        var deltaSquared = 0.0
        var count = 0
        var seedsDiffer = 0
        for i in stride(from: 0, to: processed.count, by: 4) {
            let d = Double(processed[i]-baseline[i])
            deltaSum += d
            deltaSquared += d*d
            count += 1
            near(Double(still[i]),Double(baseline[i]),
                 "zero intensity identity",tolerance:0.0001)
            near(Double(processed[i]),Double(repeatResult[i]),
                 "deterministic nine layer noise",tolerance:1e-5)
            if abs(Double(processed[i]-changedSeed[i])) > 0.0005 {
                seedsDiffer += 1
            }
            precondition(processed[i].isFinite &&
                         processed[i] >= 0 && processed[i] <= 1.01)
        }
        let mean = deltaSum/Double(count)
        let variance = deltaSquared/Double(count)-mean*mean
        let layerD = (0..<3).flatMap { sl in
            (0..<3).map { ch in maxima[sl*3+ch]*0.4 }
        }
        let expected = OriginalSublayerGrain.moments(
            densityLayers: layerD,rawLayerMaxima:maxima,pixelUM:9
        )
        let sourceVarianceNormalized = expected.variance[0]/(total[0]*total[0])
        precondition(abs(mean) < 0.045 && variance > sourceVarianceNormalized*0.025 &&
                     variance < sourceVarianceNormalized*5,
                     "Sublayer grain must have density-scaled variance")
        precondition(seedsDiffer > count/10,
                     "Seed change must change nine-layer random pattern")
        print("PASS: three emulsion CoreImage shader, zero-strength identity, seed repeatability, stochastic optical-density variance.")
    }
}
