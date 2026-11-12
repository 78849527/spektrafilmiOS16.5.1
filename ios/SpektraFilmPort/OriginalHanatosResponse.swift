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

    private final class CachedLUT: NSObject {
        let values: [Double]
        init(_ values:[Double]) { self.values=values;super.init() }
    }
    // Source Float64 is memory-heavy but decoding all 192²x3 points
    // EVERY TIME the user moves a slider is unnecessary. NSCache is
    // thread-safe and may evict stock data under real-device pressure.
    // This caches ONLY source values and never changes their precision.
    private static let originalCache=NSCache<NSString,CachedLUT>()
    private static let mobileCache=NSCache<NSString,CachedLUT>()

    private let rawLUT: [Double]
    private let rgbToXYZ: [Double]
    private let n: Int

    /// Source-precision mode is the default. The previous Float16 storage
    /// remains available explicitly as a faster, quantized mobile alternative.
    /// Precision selects LUT STORAGE, not a different interpolation algorithm.
    enum Precision: Sendable {
        case originalFloat64
        case mobileFloat16
    }

    init(filmID: String, precision: Precision = .originalFloat64) throws {
        let n = GeneratedHanatosData.dimension
        guard n >= 32,
              let matrix = GeneratedHanatosData.sRGBToXYZByFilm[filmID],
              matrix.count == 9 else {
            throw DecodeError.unavailable("该胶片缺少原版 Hanatos CAT16 参考矩阵")
        }
        rgbToXYZ = matrix
        self.n = n
        let itemCount = n*n*3
        switch precision {
        case .originalFloat64:
            if let cached=Self.originalCache.object(forKey:filmID as NSString) {
                rawLUT=cached.values
                break
            }
            guard GeneratedHanatosPreciseData.dimension == n,
                  GeneratedHanatosPreciseData.sourceSHA256 ==
                    GeneratedHanatosData.sourceSHA256,
                  let encoded = GeneratedHanatosPreciseData.lutByFilm[filmID],
                  let data = Data(base64Encoded: encoded),
                  data.count == itemCount*8 else {
                throw DecodeError.unavailable(
                    "原版 Float64 Hanatos 光谱数据缺失，禁止降级 Float16：" + filmID
                )
            }
            let bytes = [UInt8](data)
            var values = [Double](repeating:0,count:itemCount)
            for i in 0..<itemCount {
                let k=i*8
                var bits:UInt64=0
                for j in 0..<8 {
                    bits |= UInt64(bytes[k+j]) << UInt64(j*8)
                }
                values[i]=Double(bitPattern:bits)
            }
            guard values.allSatisfy({ $0.isFinite }) else {
                throw DecodeError.unavailable("原版 Float64 光谱 LUT 包含非有限数：" + filmID)
            }
            rawLUT=values
            Self.originalCache.setObject(
                CachedLUT(values),forKey:filmID as NSString,
                cost:itemCount*8
            )
        case .mobileFloat16:
            if let cached=Self.mobileCache.object(forKey:filmID as NSString) {
                rawLUT=cached.values
                break
            }
            guard let encoded=GeneratedHanatosData.lutByFilm[filmID],
                  let data=Data(base64Encoded:encoded),
                  data.count == itemCount*2 else {
                throw DecodeError.unavailable("移动 Float16 光谱 LUT 缺失：" + filmID)
            }
            let bytes=[UInt8](data)
            var values=[Double](repeating:0,count:itemCount)
            for i in 0..<itemCount {
                let k=i*2
                values[i]=Self.binary16ToDouble(
                    UInt16(bytes[k]) | (UInt16(bytes[k+1]) << 8)
                )
            }
            guard values.allSatisfy({ $0.isFinite }) else {
                throw DecodeError.unavailable("移动 Float16 光谱 LUT 数值无效：" + filmID)
            }
            rawLUT=values
            Self.mobileCache.setObject(
                CachedLUT(values),forKey:filmID as NSString,
                cost:itemCount*8
            )
        }
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
