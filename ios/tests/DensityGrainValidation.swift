import Foundation
import CoreGraphics
import CoreImage

@main
struct DensityGrainValidation {
    static func assertNear(_ x: Double, _ y: Double, tolerance: Double,
                           _ explanation: String) {
        precondition(abs(x-y) < tolerance, "\(explanation) \(x) vs \(y)")
    }

    static func render(_ image: CIImage, side: Int) -> [Float] {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.useSoftwareRenderer: true])
        var data = [Float](repeating: 0, count: side*side*4)
        data.withUnsafeMutableBytes { raw in
            context.render(
                image,
                toBitmap: raw.baseAddress!,
                rowBytes: side*4*MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: side, height: side),
                format: .RGBAf,
                colorSpace: space
            )
        }
        return data
    }

    static func main() {
        setbuf(stdout, nil)
        print("START: original density-grain statistical validation")

        // Upstream Poisson/binomial particle moments, in optical D.
        let area = 0.2 * 1.6
        let pixelUM = 25.0
        let n = pixelUM*pixelUM/area
        let dMax = 2.25
        let d = 0.9
        let p = (d+0.03)/(dMax+0.03)
        let saturation = 1 - p*0.97*(1-1e-6)
        let expected = (dMax+0.03)*(dMax+0.03)*p*saturation/n
        assertNear(
            DensityGrain.expectedVariance(
                density: d, maximum: dMax, pixelUM: pixelUM, channel: 0
            ), expected, tolerance: 1e-12,
            "Poisson/Binomial density variance"
        )
        for ch in 0..<3 {
            let zero = DensityGrain.expectedVariance(
                density: 0, maximum: dMax, pixelUM: pixelUM, channel: ch
            )
            let middle = DensityGrain.expectedVariance(
                density: d, maximum: dMax, pixelUM: pixelUM, channel: ch
            )
            precondition(zero.isFinite && middle.isFinite && middle > zero)
        }
        print("PASS: original Poisson/Binomial density-dependent moments.")

        let side = 192
        let source = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let dMaxes = [2.25, 2.25, 2.25]
        guard let identity = DensityGrain.perturbDensityImage(
            source, maxDensity: dMaxes, pixelUM: pixelUM,
            amount: 0, seed: 8888
        ), let noise = DensityGrain.perturbDensityImage(
            source, maxDensity: dMaxes, pixelUM: pixelUM,
            amount: 1, seed: 8888
        ), let noiseAgain = DensityGrain.perturbDensityImage(
            source, maxDensity: dMaxes, pixelUM: pixelUM,
            amount: 1, seed: 8888
        ), let otherSeed = DensityGrain.perturbDensityImage(
            source, maxDensity: dMaxes, pixelUM: pixelUM,
            amount: 1, seed: 7777
        ) else {
            preconditionFailure("iOS 16 Core Image density grain kernel failed to compile")
        }
        let base = render(source, side: side)
        let noStrength = render(identity, side: side)
        let grains = render(noise, side: side)
        let grainsAgain = render(noiseAgain, side: side)
        let other = render(otherSeed, side: side)
        let red = stride(from: 0, to: base.count, by: 4)
        var mean = 0.0
        var squared = 0.0
        var count = 0.0
        var changed = 0
        var seedChanged = 0
        for ix in red {
            assertNear(Double(noStrength[ix]), Double(base[ix]),
                       tolerance: 0.0002, "Grain 0 must be identity")
            assertNear(Double(grains[ix]), Double(grainsAgain[ix]),
                       tolerance: 0.0000005, "Fixed seed is deterministic")
            let delta = Double(grains[ix] - base[ix])
            mean += delta
            squared += delta*delta
            count += 1
            if abs(delta) > 0.001 { changed += 1 }
            if abs(Double(grains[ix] - other[ix])) > 0.001 { seedChanged += 1 }
            precondition(grains[ix].isFinite && grains[ix] >= 0 && grains[ix] <= 1)
        }
        let average = mean/count
        let variance = squared/count - average*average
        let varianceD = variance*dMax*dMax
        let expectedD = DensityGrain.expectedVariance(
            density: 0.4*dMax, maximum: dMax,
            pixelUM: pixelUM, channel: 0
        )
        precondition(abs(average) < 0.02 && changed > Int(count*0.1),
                     "Density grain should be random, near-zero-mean and visible")
        precondition(seedChanged > Int(count*0.1),
                     "Changing grain seed should change particle pattern")
        // CIColorKernel hash/Box-Muller gives approximate unit-variance
        // normal noise. Allow GPU precision and color-space differences.
        precondition(varianceD > expectedD*0.35 &&
                     varianceD < expectedD*2.5,
                     "Grain variance does not follow upstream statistics: " +
                     "\(varianceD) expected \(expectedD)")
        print("PASS: Core Image density grain noise variance, mean, seed repeatability.")
        print("PASS: zero-strength identity; deterministic optical-density perturbation.")
    }
}
