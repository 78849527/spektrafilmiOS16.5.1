import Foundation
import CoreImage

/// Source DIR physical exposure tests: Float64 NumPy matrix parity and
/// macOS Core Image pipeline exercise (real kernels, not source grep).
@main
struct SpatialDIRValidation {
    static func close(_ actual: Double, _ source: Double,
                      label: String, tolerance: Double = 1e-7) {
        precondition(actual.isFinite &&
                     abs(actual-source) <= tolerance,
                     "\(label): actual \(actual), source \(source)")
    }

    static func makeIdentityCube(_ size: Int) -> Data {
        var result = [Float]()
        let step = 1.0 / Float(size-1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    result.append(contentsOf: [
                        Float(r)*step, Float(g)*step, Float(b)*step, 1.0
                    ])
                }
            }
        }
        return result.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: $0.count*4)
        }
    }

    static func sample(_ image: CIImage) -> [Double]? {
        let context = CIContext()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var floatRGBA = [Float](repeating: 0, count: 4)
        floatRGBA.withUnsafeMutableBytes { buffer in
            context.render(
                image, toBitmap: buffer.baseAddress!,
                rowBytes: 4*MemoryLayout<Float>.size,
                bounds: CGRect(x: 12, y: 12, width: 1, height: 1),
                format: .RGBAf, colorSpace: space
            )
        }
        return floatRGBA.prefix(3).map { Double($0) }
    }

    static func main() throws {
        let samples = GeneratedDIRSpatialReference.samples
        precondition(samples.count == 16,
                     "16 upstream Float64 DIR inhibition probes required")
        for ref in samples {
            guard let stock = GeneratedDIRData.records[ref.stock] else {
                fatalError("Original film-specific DIR matrix missing")
            }
            let observed = SpatialDIR.inhibition(
                density: ref.density, maximum: ref.maximum,
                matrix: stock.donorReceiverMatrix, positive: ref.positive
            )
            for c in 0..<3 {
                close(observed[c], ref.inhibition[c],
                      label: "source DIR NumPy matrix \(ref.stock):\(c)")
            }
        }
        print("PASS: 16 original Python/NumPy donor-receiver inhibition vectors.")

        let identitySource = makeIdentityCube(9)
        let identityCorrected = makeIdentityCube(17)
        let diagonal = [
            0.10, 0.0, 0.0,
            0.0, 0.10, 0.0,
            0.0, 0.0, 0.10
        ]
        func stage(positive: Bool) -> SpatialDIRStage {
            SpatialDIRStage(
                rawLogCube: identitySource,
                initialDensityCube: identitySource,
                correctedDensityCube: identityCorrected,
                printCube: identitySource,
                sourceCubeSize: 9, correctedCubeSize: 17,
                densityRanges: [1, 1, 1],
                densityMaximum: [1, 1, 1],
                logExposureSpans: [2, 2, 2],
                donorReceiverMatrix: diagonal,
                positive: positive
            )
        }

        let image = CIImage(color: CIColor(
            red: 0.4, green: 0.5, blue: 0.7, alpha: 1.0
        )).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let opts = SpatialDIRSettings(enabled: true)
        precondition(opts.valid && stage(positive: false).valid)
        for positive in [false, true] {
            guard let output = SpatialDIR.apply(
                to: image, stage: stage(positive: positive),
                settings: opts, grain: nil
            ), let values = sample(output) else {
                fatalError("DIR CoreImage kernels failed to render")
            }
            let source = [0.4, 0.5, 0.7]
            for c in 0..<3 {
                let silver = positive ? 1.0-source[c] : source[c]
                let expected = source[c]-silver*0.10/2.0
                close(values[c], expected,
                      label: "uniform DIR spatial inhibition (reversal \(positive))",
                      tolerance: 0.045)
            }
        }
        let off = SpatialDIRSettings()
        precondition(SpatialDIR.apply(
            to: image, stage: stage(positive: false),
            settings: off, grain: nil
        ) == nil)
        print("PASS: CoreImage DIR Gaussian + exponential-tail stage renders physical intermediate densities, both negative and reversal.")
    }
}
