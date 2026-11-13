import Foundation

/// Stage-scoped original Python fast_interp versus the SAME source Float64
/// film H-D interpolator used by the Swift production image engine.
/// Not a certification of Numba RNG, Metal GPU, RAW or the full app.
enum SourceHDInterpolationValidation {
    enum Failure: Error {
        case mismatch(String)
    }

    private static func decode(_ payload: String, label: String) throws -> [Double] {
        guard let data = Data(base64Encoded: payload),
              !data.isEmpty, data.count % 8 == 0 else {
            throw Failure.mismatch("Invalid binary64 source H-D " + label)
        }
        return data.withUnsafeBytes { bytes in
            let raw = bytes.bindMemory(to: UInt8.self)
            var result = [Double]()
            result.reserveCapacity(data.count / 8)
            for offset in stride(from: 0, to: data.count, by: 8) {
                var bits: UInt64 = 0
                for b in 0..<8 {
                    bits |= UInt64(raw[offset+b]) << (8*b)
                }
                result.append(Double(bitPattern: bits))
            }
            return result
        }
    }

    static func evaluate() throws {
        let cases = GeneratedSourceHDInterpolationReference.records
        guard cases.count == 20, Set(cases.map { $0.stock }).count == 20 else {
            throw Failure.mismatch("Missing 20 independent Python H-D film references")
        }
        var count = 0
        var peak = 0.0
        var total = 0.0
        for entry in cases {
            let x = try decode(entry.exposures, label: entry.stock+"/x")
            guard x.count >= 30, x.allSatisfy({ $0.isFinite }) else {
                throw Failure.mismatch("Insufficient original boundary probes " + entry.stock)
            }
            for corrected in [false, true] {
                let label = entry.stock + (corrected ? "/pre-DIR" : "/original")
                let expected = try decode(
                    corrected ? entry.correctedBeforeDIR : entry.original,
                    label: label
                )
                let actual = try SpectralPhysics.sourceHDInterpolationProbe(
                    filmID: entry.stock, exposures: x, correctedBeforeDIR: corrected
                )
                guard expected.count == x.count*3, actual.count == expected.count else {
                    throw Failure.mismatch("Source H-D channel count mismatch " + label)
                }
                for i in expected.indices {
                    let a = actual[i], b = expected[i]
                    guard a.isFinite && b.isFinite else {
                        throw Failure.mismatch("Source H-D NaN/Inf " + label)
                    }
                    let delta = abs(a-b)
                    peak = max(peak, delta)
                    total += delta
                    count += 1
                    guard delta <= 2e-11 else {
                        throw Failure.mismatch(
                            "Source original Float64 H-D mismatch " + label +
                            " index=\(i) Python=\(b) Swift=\(a) delta=\(delta)"
                        )
                    }
                }
            }
        }
        print("PASS upstream Python original Float64 H-D versus Swift " +
              "production curve: 20 films including 4 reversal, " +
              "\(count) channels; max=\(peak), MAE=\(total/Double(count)). " +
              "Stage-scoped only, not original full-image/GPU certification.")
    }
}
