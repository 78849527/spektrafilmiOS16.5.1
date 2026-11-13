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
        // Production source FIR/YVV and source NumPy references operate
        // on linear, unencoded film log/density values. Do not apply an
        // sRGB display transfer function when reading a numerical probe.
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull()
        ])
        var floatRGBA = [Float](repeating: 0, count: 4)
        floatRGBA.withUnsafeMutableBytes { buffer in
            context.render(
                image, toBitmap: buffer.baseAddress!,
                rowBytes: 4*MemoryLayout<Float>.size,
                bounds: CGRect(x: 12, y: 12, width: 1, height: 1),
                format: .RGBAf, colorSpace: nil
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
            var result = SpatialDIRStage(
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
            result.float64OpticalNodes = .identity(
                sourceSize: 9, correctedSize: 17
            )
            return result
        }

        let image = CIImage(color: CIColor(
            red: 0.4, green: 0.5, blue: 0.7, alpha: 1.0
        )).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let opts = SpatialDIRSettings(enabled: true)
        precondition(opts.valid && stage(positive: false).valid)
        for positive in [false, true] {
            guard let output = try SpatialDIR.apply(
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
        let offResult = try SpatialDIR.apply(
            to: image, stage: stage(positive: false),
            settings: off, grain: nil
        )
        precondition(offResult == nil)
        // A precise source-mode request without Double-calculated optical
        // nodes must FAIL. It cannot quietly consume mobile Float32 LUTs.
        var missing = stage(positive: false)
        missing.float64OpticalNodes = nil
        var rejected = false
        do {
            _ = try SpatialDIR.apply(
                to: image, stage: missing, settings: opts, grain: nil
            )
        } catch SourceSpatialDIRConvolution.Failure.invalid(let message) {
            precondition(message.contains("Float64"),
                         "Must identify exactly the missing Double LUT")
            rejected = true
        }
        precondition(rejected,
                     "Original source DIR silently downgraded to Float32 cubes")
        print("PASS: source exact path rejects missing Float64 optical nodes.")
        print("PASS: source FIR/YVV spatial DIR stage renders physical intermediate densities, both negative and reversal.")
        // Execute direct source 2D Python convolution references and the
        // exact same CoreImage spatial branch used by production photos.
        let evidence=try SourceSpatialDIR2DParity.evaluate()
        print(evidence.text)
        precondition(evidence.cases==3 && evidence.channels==1287,
                     "Expected 3 actual 13x11 upstream source images")
        precondition(evidence.numericOutside==0,
                     "SOURCE 2D DIR FIR/YVV: >0.002 Swift numeric deviation")
        precondition(evidence.productionOutside==0,
                     "SOURCE 2D DIR CIImage: >0.002 production deviation")
        precondition(evidence.directOutside==0,
                     "SOURCE 2D DIR Float64 arrays: >0.002 production deviation")
        // Regression reported on actual iPhone: 3888x2592 = 10,077,696
        // pixels. The original 16MP ImageIO→Double DIR route succeeds.
        // The separate physical chain must refuse its 2MP budget with
        // a truthful warning BEFORE launching the full-res decode/exports.
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:3888,height:2592,maximumAllowedPixels:16_000_000
        )
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:4000,height:4000,maximumAllowedPixels:16_000_000
        )
        try OriginalSourcePixelIO.validatePixelDimensions(
            width:1600,height:1250,maximumAllowedPixels:2_000_000
        )
        var physicalDenied = false
        do {
            try OriginalSourcePixelIO.validatePixelDimensions(
                width:3888,height:2592,maximumAllowedPixels:2_000_000
            )
        } catch OriginalSourcePixelIO.Failure.invalid(let reason) {
            physicalDenied = reason.contains("200 万像素") &&
                reason.contains("3888 × 2592") &&
                reason.contains("逐像素全光学") &&
                !reason.contains("最多 1600 万像素") &&
                reason.contains("不会擅自缩图")
        }
        precondition(physicalDenied,
                     "The 10MP original must be rejected as 2MP physical, " +
                     "not misreported as exceeding 16MP")
        var fullLimitDenied = false
        do {
            try OriginalSourcePixelIO.validatePixelDimensions(
                width:4001,height:4000,maximumAllowedPixels:16_000_000
            )
        } catch OriginalSourcePixelIO.Failure.invalid(let reason) {
            fullLimitDenied=reason.contains("1600 万像素")
        }
        precondition(fullLimitDenied,
                     "Direct source 16MP memory limit must remain intact")
        print("PASS: reported 3888x2592 source accepted in 16MP mode, " +
              "rejected in 2MP physical mode with accurate limit; " +
              "16MP limit unchanged and no automatic resize.")
        print(try OriginalSourcePixelIO.validate8BitRoundTrip())
        print(try OriginalSourcePixelIO.validateColorProfileGate())
        // v1.8.20: real upstream Python multi-size whole-frame data, not
        // the previous 13x11 samples or a fabricated Swift self-reference.
        try SourceFullFrameParity.evaluate(fixtures: URL(
            fileURLWithPath: "ios/verification/generated-fullframe-v1.8.20",
            isDirectory: true
        ))
    }
}
