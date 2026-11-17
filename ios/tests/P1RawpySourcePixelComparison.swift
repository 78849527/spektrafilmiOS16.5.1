import Foundation

/// Test-only comparison against rawpy-linear-aces-f32le.rgb, produced by the
/// frozen Python raw_file_processor. Pure tap comparison: no retagging,
/// clipping, resampling or CCTF decoding. It never upgrades certification
/// based on a threshold alone.
enum P1RawpySourcePixelComparison {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }

    struct Metrics {
        let width: Int
        let height: Int
        let samples: Int
        let mae: Double
        let rmse: Double
        let maximum: Double
        let worstIndex: Int
        let exactChannels: Int
    }

    static func evaluate(
        source: P1OriginalRawACESIngress.Source,
        pythonFloat32LE: Data,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> Metrics {
        guard expectedWidth == source.width,
              expectedHeight == source.height,
              source.width > 0, source.height > 0,
              source.width <= 45_000_000 / source.height else {
            throw Failure.invalid("P1 RAW 参考图与 LibRaw 实际尺寸不一致")
        }
        let count = source.width * source.height * 3
        guard source.packedRGB16.count == count * 2,
              pythonFloat32LE.count == count * 4 else {
            throw Failure.invalid("P1 RAW 参考 Float32 / 原始 UInt16 字节数量不匹配")
        }
        var total = 0.0
        var squares = 0.0
        var maximum = 0.0
        var worstIndex = -1
        var exact = 0

        try source.packedRGB16.withUnsafeBytes { rawBytes in
            try pythonFloat32LE.withUnsafeBytes { referenceBytes in
                let raw = rawBytes.bindMemory(to: UInt8.self)
                let ref = referenceBytes.bindMemory(to: UInt8.self)
                for i in 0..<count {
                    let sample = UInt16(raw[i*2]) |
                        (UInt16(raw[i*2+1]) << 8)
                    let observed = Float(sample) / Float(65535.0)
                    let offset = i * 4
                    let bits = UInt32(ref[offset]) |
                        (UInt32(ref[offset+1]) << 8) |
                        (UInt32(ref[offset+2]) << 16) |
                        (UInt32(ref[offset+3]) << 24)
                    let expected = Float(bitPattern: bits)
                    guard observed.isFinite, expected.isFinite else {
                        throw Failure.invalid("P1 RAW 原版/原生包含 NaN 或 Inf")
                    }
                    if observed.bitPattern == expected.bitPattern {
                        exact += 1
                    }
                    let error = abs(Double(observed) - Double(expected))
                    total += error
                    squares += error * error
                    if error > maximum {
                        maximum = error
                        worstIndex = i
                    }
                }
            }
        }
        let n = Double(count)
        return Metrics(
            width: source.width, height: source.height,
            samples: count, mae: total / n,
            rmse: sqrt(squares / n), maximum: maximum,
            worstIndex: worstIndex, exactChannels: exact
        )
    }
}
