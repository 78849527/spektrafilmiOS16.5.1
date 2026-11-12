import Foundation

/// Native Swift port of original Hanatos2025 film raw interpolation.
/// Data: upstream irradiance_xy_tc.npy integrated over each stock's actual
/// measured sensitivity and original UV/IR erf4 adaptation window at build.
/// The film-specific 2D TC response is stored as Float16 and interpolated
/// with the original reflected Mitchell-Netravali 4x4 kernel (B=C=1/3).
struct OriginalHanatosResponse {
    enum DecodeError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            if case let .unavailable(text) = self { return text }
            return nil
        }
    }

    private let rawLUT: [Double]
    private let rgbToXYZ: [Double]
    private let n: Int

    init(filmID: String) throws {
        guard let encoded = GeneratedHanatosData.lutByFilm[filmID] else {
            throw DecodeError.unavailable("Hanatos2025 没有该胶片的响应数据：" + filmID)
        }
        let n = GeneratedHanatosData.dimension
        guard n >= 32, let raw = Data(base64Encoded: encoded),
              raw.count == n * n * 3 * 2 else {
            throw DecodeError.unavailable("Hanatos2025 光谱数据数量不匹配")
        }
        guard let matrix = GeneratedHanatosData.sRGBToXYZByFilm[filmID],
              matrix.count == 9 else {
            throw DecodeError.unavailable("该胶片没有 CAT16 参考光源投影矩阵")
        }
        rgbToXYZ = matrix
        self.n = n
        // Decode from little-endian binary16 without assuming aligned pointers.
        // A direct counted loop avoids a costly nested generic type-check
        // of Data.withUnsafeBytes / Array.map in Swift 5 on Intel Xcode16.4.
        let bytes = [UInt8](raw)
        let itemCount = n * n * 3
        var decoded = [Double](repeating: 0, count: itemCount)
        for index in 0..<itemCount {
            let byteIndex = index * 2
            let low = UInt16(bytes[byteIndex])
            let high = UInt16(bytes[byteIndex + 1]) << 8
            decoded[index] = Self.binary16ToDouble(low | high)
        }
        rawLUT = decoded
    }

    /// Platform-independent IEEE-754 binary16 to Double conversion.
    /// Avoids Float16(bitPattern:) overload availability differences on
    /// macOS-15 Intel and the user's iOS 16.5.1 deployment target.
    private static func binary16ToDouble(_ bits: UInt16) -> Double {
        let sign = (bits & 0x8000) == 0 ? 1.0 : -1.0
        let exponent = Int((bits >> 10) & 0x1f)
        let fraction = Int(bits & 0x03ff)
        if exponent == 0 {
            return sign * Double(fraction) * pow(2.0, -24.0)
        }
        if exponent == 31 {
            return fraction == 0 ? sign * Double.infinity : Double.nan
        }
        return sign * Double(1024 + fraction) *
               pow(2.0, Double(exponent - 25))
    }

    func raw(linearRGB: [Double]) -> [Double] {
        guard linearRGB.count == 3 else { return [] }
        // Original _rgb_to_tc_b: input linear-sRGB -> XYZ-D55 with CAT16.
        // The adaptation matrix is generated via colour.RGB_to_XYZ at build.
        let m = rgbToXYZ
        let xyz = (0..<3).map { c in
            (0..<3).reduce(0.0) { sum, rgb in
                sum + m[rgb * 3 + c] * linearRGB[rgb]
            }
        }
        let brightness = xyz.reduce(0.0, +)
        let den = max(brightness, 1e-10)
        let x = xyz[0] / den
        let y = xyz[1] / den
        let tx = min(1.0, max(0.0, (1.0 - x) * (1.0 - x)))
        let ty = min(1.0, max(0.0, y / max(1.0 - x, 1e-10)))
        let lut = interpolateMitchell(x: tx, y: ty)
        return lut.map { $0 * brightness }
    }

    private func interpolateMitchell(x: Double, y: Double) -> [Double] {
        let upper = Double(n - 1)
        let xx = min(upper, max(0.0, x * upper))
        let yy = min(upper, max(0.0, y * upper))
        let baseX = min(n - 2, Int(floor(xx)))
        let baseY = min(n - 2, Int(floor(yy)))
        let fracX = xx - Double(baseX)
        let fracY = yy - Double(baseY)

        let wx = (0..<4).map { Self.mitchell(fracX + 1.0 - Double($0)) }
        let wy = (0..<4).map { Self.mitchell(fracY + 1.0 - Double($0)) }

        var result = [0.0, 0.0, 0.0]
        var total = 0.0
        for i in 0..<4 {
            let ix = Self.reflected(baseX - 1 + i, n)
            for j in 0..<4 {
                let iy = Self.reflected(baseY - 1 + j, n)
                let weight = wx[i] * wy[j]
                total += weight
                let offset = (ix * n + iy) * 3
                for c in 0..<3 { result[c] += weight * rawLUT[offset + c] }
            }
        }
        if total != 0 {
            for c in 0..<3 { result[c] /= total }
        }
        return result
    }

    private static func reflected(_ i: Int, _ n: Int) -> Int {
        if i < 0 { return -i }
        if i >= n { return 2 * (n - 1) - i }
        return i
    }

    private static func mitchell(_ t: Double) -> Double {
        let x = abs(t)
        let b = 1.0 / 3.0
        let c = 1.0 / 3.0
        if x < 1.0 {
            return ((12 - 9*b - 6*c)*pow(x,3) +
                    (-18 + 12*b + 6*c)*x*x + (6 - 2*b)) / 6.0
        }
        if x < 2.0 {
            return ((-b - 6*c)*pow(x,3) +
                    (6*b + 30*c)*x*x - (12*b + 48*c)*x +
                    (8*b + 24*c)) / 6.0
        }
        return 0
    }
}
