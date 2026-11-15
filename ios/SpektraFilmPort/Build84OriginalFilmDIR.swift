import Foundation

/// Build84 / 21–22: source-ordered film H-D and DIR chemistry in CPU Float64.
/// Python pins: model/density_curves.py, model/couplers.py, utils/fast_interp.py
/// at the fixed Build77 upstream contract. No Core Image or Float32 fallback.
/// The source itself expects monotonic characteristic axes for interpolation.
enum Build84OriginalFilmDIR {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let why) = self { return why }
            return nil
        }
    }

    /// Row: releasing/donor layer. Column: receiving/inhibited layer.
    /// Source computes M_self + M_inter, then multiplies by "amount".
    static func matrix(
        amount: Double = 1,
        inhibitionSameLayer: Double = 1,
        inhibitionInterlayer: Double = 1,
        gammaSameLayer: [Double] = [0.341, 0.324, 0.273],
        gammaRtoGB: [Double] = [0.355, 0.305],
        gammaGtoRB: [Double] = [0.154, 0.358],
        gammaBtoRG: [Double] = [0.171, 0.225]
    ) throws -> [Double] {
        let all = [amount, inhibitionSameLayer, inhibitionInterlayer] +
            gammaSameLayer + gammaRtoGB + gammaGtoRB + gammaBtoRG
        guard gammaSameLayer.count == 3,
              gammaRtoGB.count == 2, gammaGtoRB.count == 2,
              gammaBtoRG.count == 2, all.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("Build84 源 DIR 9 项矩阵参数无效")
        }
        return [
            gammaSameLayer[0] * inhibitionSameLayer,
            gammaRtoGB[0] * inhibitionInterlayer,
            gammaRtoGB[1] * inhibitionInterlayer,
            gammaGtoRB[0] * inhibitionInterlayer,
            gammaSameLayer[1] * inhibitionSameLayer,
            gammaGtoRB[1] * inhibitionInterlayer,
            gammaBtoRG[0] * inhibitionInterlayer,
            gammaBtoRG[1] * inhibitionInterlayer,
            gammaSameLayer[2] * inhibitionSameLayer
        ].map { $0 * amount }
    }

    /// Exact original runtime/params_builder.py::_apply_film_specifics
    /// film-stock DIR presets, including the two distinct reversal films.
    /// This is used for full 256-node source validation; production's
    /// existing GeneratedDIRData presets remain unchanged until certified.
    static func stockMatrix(
        stock: String, positive: Bool,
        amount: Double = 1,
        inhibitionSameLayer: Double = 1,
        inhibitionInterlayer: Double = 1
    ) throws -> [Double] {
        let same: [Double]
        let rg: [Double]
        let gr: [Double]
        let br: [Double]
        if stock == "fujifilm_velvia_100" {
            guard positive else {
                throw Failure.invalid("Velvia DIR 胶片类型与原版信息冲突")
            }
            same=[0.108,0.072,0.054]
            rg=[0.108,0.054]
            gr=[0.072,0.054]
            br=[0.054,0.054]
        } else if stock == "fujifilm_provia_100f" {
            guard positive else {
                throw Failure.invalid("Provia DIR 胶片类型与原版信息冲突")
            }
            same=[0.156,0.104,0.078]
            rg=[0.156,0.078]
            gr=[0.104,0.078]
            br=[0.078,0.078]
        } else if positive {
            same=[0.12,0.08,0.06]
            rg=[0.12,0.06]
            gr=[0.08,0.06]
            br=[0.06,0.06]
        } else {
            same=[0.336,0.319,0.273]
            rg=[0.353,0.302]
            gr=[0.154,0.353]
            br=[0.168,0.226]
        }
        return try matrix(
            amount:amount,
            inhibitionSameLayer:inhibitionSameLayer,
            inhibitionInterlayer:inhibitionInterlayer,
            gammaSameLayer:same, gammaRtoGB:rg,
            gammaGtoRB:gr, gammaBtoRG:br
        )
    }

    /// Equivalent to the source normalized_density_curves =
    /// density_curves - np.nanmin(density_curves, axis=0) for finite input.
    static func normalize(_ curves: [Double]) throws -> [Double] {
        guard curves.count >= 6, curves.count % 3 == 0,
              curves.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("Build84 H-D 原始曲线必须为有限 N×3")
        }
        let n = curves.count / 3
        var mins = [Double](repeating: Double.infinity, count: 3)
        for k in 0..<n {
            for ch in 0..<3 { mins[ch] = min(mins[ch], curves[k*3+ch]) }
        }
        return curves.enumerated().map { i, v in v - mins[i%3] }
    }

    /// Source np.interp: right-sided exact matches, endpoint extension.
    /// Does not sort nodes or silently replace a non-monotonic source axis.
    private static func npInterp(
        _ x: Double, axis: [Double], values: [Double]
    ) -> Double {
        let n = axis.count
        if x <= axis[0] { return values[0] }
        if x >= axis[n-1] { return values[n-1] }
        var low = 0
        var high = n
        while low < high {
            let mid = (low + high) / 2
            if x < axis[mid] { high = mid }
            else { low = mid + 1 }
        }
        let lo = low - 1
        let dx = axis[low] - axis[lo]
        let t = (x - axis[lo]) * (dx == 0 ? 0 : 1.0/dx)
        return values[lo] + t * (values[low] - values[lo])
    }

    /// Source compute_density_curves_before_dir_couplers:
    /// 256×3 measured density, same-layer/inter-layer coupled silver,
    /// per-receiver corrected exposure axis, np.interp, reversal sign.
    static func curvesBeforeDIR(
        logExposure: [Double], densityCurves: [Double],
        matrix: [Double], positive: Bool
    ) throws -> [Double] {
        let n = logExposure.count
        guard n >= 2, densityCurves.count == n*3, matrix.count == 9,
              (logExposure+densityCurves+matrix).allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("Build84 校正前 H-D 需要完整 Float64 N×3 曲线与 DIR 矩阵")
        }
        let maxima = (0..<3).map { ch in
            (0..<n).reduce(-Double.infinity) {
                max($0, densityCurves[$1*3+ch])
            }
        }
        var warped = [Double](repeating: 0, count: n*3)
        for i in 0..<n {
            for receiver in 0..<3 {
                var inhib = 0.0
                for donor in 0..<3 {
                    let d = densityCurves[i*3+donor]
                    let silver = positive ? maxima[donor]-d : d
                    inhib += silver * matrix[donor*3+receiver]
                }
                warped[i*3+receiver] = logExposure[i] - inhib
            }
        }
        var corrected = [Double](repeating: 0, count: n*3)
        for ch in 0..<3 {
            let axis = (0..<n).map { warped[$0*3+ch] }
            let sign = positive ? -1.0 : 1.0
            let values = (0..<n).map { sign*densityCurves[$0*3+ch] }
            for k in 0..<n {
                corrected[k*3+ch] = sign*npInterp(
                    logExposure[k],axis:axis,values:values
                )
            }
        }
        guard corrected.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("Build84 校正前 H-D 产生非有限值")
        }
        return corrected
    }

    /// Original fast_interp() for RGB log exposure and per-channel gamma.
    /// Unlike a uniform 256-bin LUT, retains original x knots and right bias.
    static func developDensity(
        logRaw: [Double], logExposure: [Double],
        densityCurves: [Double], gammaRGB: [Double] = [1, 1, 1]
    ) throws -> [Double] {
        let n = logExposure.count
        guard n >= 2, logRaw.count%3 == 0,
              densityCurves.count == n*3, gammaRGB.count == 3,
              (logRaw+logExposure+densityCurves+gammaRGB).allSatisfy({ $0.isFinite }),
              gammaRGB.allSatisfy({ $0 > 0 }) else {
            throw Failure.invalid("Build84 源 H-D 插值参数或 gamma 无效")
        }
        var result = [Double](repeating: 0, count: logRaw.count)
        for ch in 0..<3 {
            let axis = logExposure.map { $0 / gammaRGB[ch] }
            let values = (0..<n).map { densityCurves[$0*3+ch] }
            for pixel in 0..<(logRaw.count/3) {
                result[pixel*3+ch] = npInterp(
                    logRaw[pixel*3+ch],axis:axis,values:values
                )
            }
        }
        return result
    }

    /// Source density_silver = positive ? density_max - density_cmy :
    /// density_cmy; optional high-exposure source branch then donor×receiver.
    /// Upstream FilmingStage currently passes a zero shift by default.
    static func inhibitors(
        density: [Double], maximum: [Double], matrix: [Double],
        positive: Bool, highExposureShift: Double = 0
    ) throws -> [Double] {
        guard density.count == 3, maximum.count == 3, matrix.count == 9,
              (density+maximum+matrix+[highExposureShift])
                  .allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("Build84 原版 DIR 银密度或矩阵无效")
        }
        let silver = (0..<3).map { donor -> Double in
            let original = positive
                ? maximum[donor] - density[donor] : density[donor]
            return original + highExposureShift*original*original
        }
        var result = [Double](repeating: 0, count: 3)
        for receiver in 0..<3 {
            for donor in 0..<3 {
                result[receiver] += silver[donor]*matrix[donor*3+receiver]
            }
        }
        guard result.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("Build84 原版 DIR 抑制量溢出")
        }
        return result
    }
}
