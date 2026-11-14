import Foundation

/// Exact port of the source raw_file_processor._apply_tint_adjustment
/// ARITHMETIC ONLY (NumPy float32 multiplication, green channel).
///
/// Original Python applies this after linear ACES2065-1 white adaptation.
/// Do not feed Apple extendedLinearSRGB into it and claim RAW parity.
/// Original tint is a green multiplier (1.0 neutral), NOT Apple's
/// CIRAWFilter neutralTint offset (-150...150).
enum Build80OriginalRAWTint {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let text) = self { return text }
            return nil
        }
    }

    static func apply(_ rgb: [Float], tint: Double?) throws -> [Float] {
        guard rgb.count.isMultiple(of: 3) else {
            throw Failure.invalid("Python RAW Tint 输入必须有完整 RGB 三通道")
        }
        guard let tint else { return rgb }

        // numpy.isclose(tint, 1.0): rtol=1e-5, atol=1e-8,
        // target is 1.0, equal_nan=False. Exactly original source default.
        if abs(tint - 1.0) <= 1e-8 + 1e-5 * abs(1.0) {
            return rgb
        }
        let green = Float(tint)  // np.array(..., dtype=np.float32)
        var result = rgb
        for i in stride(from: 1, to: rgb.count, by: 3) {
            result[i] = result[i] * green  // Float32, not CPU Double
        }
        return result
    }
}
