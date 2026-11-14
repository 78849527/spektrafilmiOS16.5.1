import Foundation
import Darwin

/// Literal Float64 port of upstream model.color_filters:
/// sigmoid_erf() and compute_band_pass_filter().
///
/// Python's source camera step changes film sensitivities by:
///   S_filtered[wl,c] = S[wl,c] * filter[wl] / normalization[c]
/// where normalization[c] is the ratio of sensitivity-weighted
/// illuminant exposure with/without the filter. The normalization is
/// performed in SpectralPhysics before Mallett's native einsum matrix.
///
/// IMPORTANT: The current Hanatos TC LUT is baked at build time for each
/// unfiltered stock. When bandpass is enabled, use Mallett 2019 rather
/// than incorrectly reusing the unfiltered Hanatos LUT.
enum OriginalSourceCameraBandpass {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    struct Edge {
        var amount: Double
        var centerNM: Double
        var widthNM: Double

        func validate(name: String) throws {
            guard amount.isFinite, (0...1).contains(amount),
                  centerNM.isFinite, (380...780).contains(centerNM),
                  widthNM.isFinite, (0.1...100).contains(widthNM) else {
                throw Failure.invalid(
                    name + " UV/IR 滤镜无效：强度 0–1、截止波长 380–780nm、宽度 0.1–100nm"
                )
            }
        }
    }

    struct Settings {
        // Upstream CameraParams defaults: (0,410,8), (0,675,15).
        var uv = Edge(amount: 0, centerNM: 410, widthNM: 8)
        var ir = Edge(amount: 0, centerNM: 675, widthNM: 15)

        var active: Bool { uv.amount > 0 || ir.amount > 0 }

        func validate() throws {
            try uv.validate(name: "UV")
            try ir.validate(name: "IR")
        }
    }

    static func transmission(wavelengthNM: Double,
                             settings: Settings) -> Double {
        // Original:
        // uv = 1-amp_uv + amp_uv*(erf((wl-c_uv)/width_uv)/2 + 0.5)
        // ir = 1-amp_ir + amp_ir*(erf((wl-c_ir)/(-width_ir))/2 + 0.5)
        // result = uv * ir
        let uv = settings.uv.amount == 0 ? 1.0 :
            1.0 - settings.uv.amount + settings.uv.amount *
            (Darwin.erf((wavelengthNM - settings.uv.centerNM) /
                         settings.uv.widthNM) * 0.5 + 0.5)
        let ir = settings.ir.amount == 0 ? 1.0 :
            1.0 - settings.ir.amount + settings.ir.amount *
            (Darwin.erf((wavelengthNM - settings.ir.centerNM) /
                        -settings.ir.widthNM) * 0.5 + 0.5)
        return uv * ir
    }
}
