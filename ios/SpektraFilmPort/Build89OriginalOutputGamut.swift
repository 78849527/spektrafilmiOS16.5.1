import Foundation

/// Source utils/gamut_compression.py::OutputGamutCompressSpec and
/// compress_rgb() dispatcher. The source default is CAM16-UCS.
/// "off" returns linear RGB unchanged including negative/overwhite.
/// ACES-RGC implements the ORIGINAL user knee (threshold,limit,power)
/// rather than a hard-coded default. CAM16-UCS is the actual CPU Double
/// per-pixel appearance model; 33^3 Float32 LUT is never called here.
///
/// Oklch and Oklrab use the source Colour Float64 Oklab (not a 3D
/// lookup). JzAzBz remains fail closed pending its separate PQ model.
enum Build89OriginalOutputGamut {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(m)=self{return m}
            return nil
        }
    }
    enum Algorithm:String,CaseIterable {
        case off="off"
        case acesRGC="aces_rgc"
        case cam16UCS="cam16ucs"
        case oklch="oklch"
        case oklrab="oklrab"
        case jzazbz="jzazbz"
    }
    enum OutputSpace:String,CaseIterable {
        case sRGB="sRGB"
        case displayP3="Display P3"
        case bt2020="ITU-R BT.2020"
    }
    struct Knee {
        var threshold=0.0
        var limit=1.0
        var power=6.0
        func validate() throws {
            // Exact original OutputGamutCompressSpec.__post_init__:
            // threshold in [0,1), limit > 0, power > 0;
            // it does NOT require limit > threshold.
            guard threshold.isFinite,limit.isFinite,power.isFinite,
                  threshold>=0,threshold<1,limit>0,power>0 else {
                throw Failure.invalid(
                    "原版输出色域压缩膝点要求 threshold [0,1)、" +
                    "limit>0、power>0，且均为 Float64 有限数"
                )
            }
        }
        var tuple:(Double,Double,Double) {
            (threshold,limit,power)
        }
    }
    struct Settings {
        // Upstream original OutputGamutCompressSpec() default.
        var algorithm:Algorithm = .cam16UCS
        var outputSpace:OutputSpace = .sRGB
        var knee=Knee()
        var lightness:Knee?=Knee(
            threshold:0.7,limit:1.0,power:2.2
        )
        func validate() throws {
            try knee.validate()
            try lightness?.validate()
            switch algorithm {
            case .off,.acesRGC,.cam16UCS,.oklch,.oklrab:break
            case .jzazbz:
                throw Failure.invalid(
                    "原版输出色域算法 \(algorithm.rawValue) " +
                    "尚未通过源 Float64 Cmax/感知变换对照；" +
                    "不能用 CAM16 33³ LUT 或 ACES 静默替代"
                )
            }
            guard GeneratedScannerReference.sourceOutputWhiteXYZ[
                outputSpace.rawValue
            ] != nil else {
                throw Failure.invalid(
                    "输出色彩空间 \(outputSpace.rawValue) " +
                    "缺少源 colour-science 精确白点参考，拒绝回退 sRGB"
                )
            }
        }
    }
    static func sourceKnee(_ x:Double,_ knee:Knee)->Double {
        // Upstream NumPy reinhard_knee d>threshold:
        // t + s * ((d-t)/s) / (1+((d-t)/s)^power)^(1/power).
        // No added gamut clamp, epsilon, or HDR highlight cap.
        guard x>knee.threshold else{return x}
        let scale=knee.limit-knee.threshold
        let normalized=(x-knee.threshold)/scale
        return knee.threshold+scale*normalized /
            pow(1+pow(normalized,knee.power),1/knee.power)
    }
    static func compressACES(
        _ rgb:[Double],knee:Knee
    ) throws ->[Double] {
        guard rgb.count==3,rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 ACES-RGC 需要有效线性 RGB")
        }
        let ach=rgb.max() ?? 0
        // Source ach<=1e-12 (black or negative) bypasses ALL channels.
        if ach<=1e-12{return rgb}
        let result=rgb.map { channel in
            let d=(ach-channel)/ach
            return ach*(1-sourceKnee(d,knee))
        }
        guard result.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "原版 ACES-RGC 自定义膝点产生非有限 RGB，" +
                "不能静默截断或使用其他压缩器"
            )
        }
        return result
    }
    static func compress(
        _ rgb:[Double],settings:Settings
    ) throws->[Double] {
        try settings.validate()
        guard rgb.count==3,rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "原版输出色域压缩输入无效，禁止 Float32/近似降级"
            )
        }
        switch settings.algorithm {
        case .off: return rgb
        case .acesRGC:
            return try compressACES(rgb,knee:settings.knee)
        case .cam16UCS:
            return try Build89OriginalCAM16.compress(
                rgb,space:settings.outputSpace.rawValue,
                knee:settings.knee.tuple,
                lightness:settings.lightness?.tuple
            )
        case .oklch:
            return try Build89bOriginalOklabGamut.compress(
                rgb,space:settings.outputSpace.rawValue,rebased:false,
                knee:settings.knee,lightness:settings.lightness
            )
        case .oklrab:
            return try Build89bOriginalOklabGamut.compress(
                rgb,space:settings.outputSpace.rawValue,rebased:true,
                knee:settings.knee,lightness:settings.lightness
            )
        case .jzazbz:
            throw Failure.invalid(
                "jzazbz 源 PQ + Cmax 未通过单独 Float64 测试，禁止近似替代"
            )
        }
    }
}
