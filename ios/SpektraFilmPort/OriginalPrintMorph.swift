import Foundation
import Darwin

/// Source spektrafilm/utils/morph_curves.py s023 printing chemistry.
/// Uses 3 fitted CDF sublayers per dye channel with coupled sigma/mu
/// gamma scaling and Gumbel developer exhaustion. All eight print media.
enum OriginalPrintMorph {
    struct Settings: Equatable {
        var gamma = 1.0
        var fast = 1.0
        var slow = 1.0
        var red = 1.0
        var green = 1.0
        var blue = 1.0
        var developerExhaustion = 0.0

        var isIdentity: Bool {
            gamma == 1 && fast == 1 && slow == 1 &&
            red == 1 && green == 1 && blue == 1 &&
            developerExhaustion == 0
        }
        var valid: Bool {
            [gamma,fast,slow,red,green,blue].allSatisfy({
                $0.isFinite && $0 > 0.0 && $0 <= 3.0
            }) && developerExhaustion.isFinite &&
                (0...1).contains(developerExhaustion)
        }
    }

    private static let gumbelLocation = -log(log(2.0))
    private static let gumbelWidth = 0.5 * log(2.0) * sqrt(2.0 * Double.pi)
    private static let rootTolerance = 1e-10

    private struct Layer {
        var center: Double
        var amplitude: Double
        var sigma: Double
    }

    private static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / sqrt(2.0))
    }

    private static func layerCDF(_ z: Double, positive: Bool,
                                 gumbelMix: Double) -> Double {
        let value = positive ? -z : z
        let gaussian = normalCDF(value)
        if gumbelMix <= 0 { return gaussian }
        let gumbel = exp(-exp(-(value/gumbelWidth + gumbelLocation)))
        return (1-gumbelMix)*gaussian + gumbelMix*gumbel
    }

    private static func evaluate(_ layers: [Layer], at exposure: Double,
                                 positive: Bool, exhaustion: Double,
                                 centerOffset: Double = 0) -> Double {
        layers.reduce(0.0) { total, layer in
            let z = (exposure - layer.center - centerOffset) / layer.sigma
            return total + layer.amplitude * layerCDF(
                z, positive: positive, gumbelMix: exhaustion
            )
        }
    }

    /// Original _developer_exhaustion_center_offset:
    /// find a common x-shift that preserves the original D(logE=0).
    private static func exhaustionOffset(
        _ layers: [Layer], positive: Bool, mix: Double
    ) -> Double {
        if mix <= 0 { return 0 }
        let target = evaluate(
            layers, at: 0, positive: positive, exhaustion: 0
        )
        func residual(_ shift: Double) -> Double {
            evaluate(layers, at: 0, positive: positive,
                     exhaustion: mix, centerOffset: shift) - target
        }
        let atZero = residual(0)
        if abs(atZero) <= 1e-12 { return 0 }

        var low = -0.25
        var high = 0.25
        var rl = residual(low)
        var rh = residual(high)
        for _ in 0..<12 {
            if rl == 0 { return low }
            if rh == 0 { return high }
            if rl * rh < 0 { break }
            low *= 2
            high *= 2
            rl = residual(low)
            rh = residual(high)
        }
        if !(rl*rh < 0) { return 0 }
        // Upstream uses brentq(..., xtol=1e-10).
        for _ in 0..<80 {
            let mid = (low+high)*0.5
            let rm = residual(mid)
            if abs(rm) < 1e-13 || (high-low) < rootTolerance {
                return mid
            }
            if rm*rl <= 0 {
                high = mid
            } else {
                low = mid
                rl = rm
            }
        }
        return (low+high)*0.5
    }

    private static func layers(
        stock: String, channel: Int
    ) -> [Layer]? {
        guard (0..<3).contains(channel),
              let record = GeneratedPrintMorphData.models[stock],
              record.centers.count == 9,
              record.amplitudes.count == 9,
              record.sigmas.count == 9 else { return nil }
        return (0..<3).map { i in
            let ix = channel*3+i
            return Layer(center: record.centers[ix],
                         amplitude: record.amplitudes[ix],
                         sigma: record.sigmas[ix])
        }
    }

    static func fittedDensity(
        stock: String, logExposure: Double, channel: Int,
        settings: Settings, positive: Bool = false
    ) -> Double? {
        guard settings.valid, logExposure.isFinite,
              var original = layers(stock: stock, channel: channel)
        else { return nil }

        // Fast means lowest center mu, independent of toe or shoulder.
        let speed = original.indices.sorted {
            original[$0].center < original[$1].center
        }
        let channelGamma = [settings.red,settings.green,settings.blue][channel]
        let fastIndex = speed[0]
        let midIndex = speed[1]
        let slowIndex = speed[2]
        for i in [fastIndex,midIndex,slowIndex] {
            let layerGamma = i == fastIndex ? settings.fast : settings.slow
            let factor = settings.gamma * channelGamma * layerGamma
            original[i].center /= factor
            original[i].sigma = max(0.05, original[i].sigma / factor)
        }
        let shift = exhaustionOffset(
            original, positive: positive, mix: settings.developerExhaustion
        )
        return evaluate(
            original, at: logExposure, positive: positive,
            exhaustion: settings.developerExhaustion, centerOffset: shift
        )
    }

    /// Source s023 change relative to original gamma=1 curve. The fitted
    /// absolute curve approximates measured 256-point material curves:
    /// using a delta preserves v1.2 measured tones when effects are off.
    static func densityDelta(
        stock: String, logExposure: Double, channel: Int,
        settings: Settings, positive: Bool = false
    ) -> Double {
        if settings.isIdentity { return 0 }
        guard let adjusted = fittedDensity(
            stock: stock, logExposure: logExposure, channel: channel,
            settings: settings, positive: positive
        ), let neutral = fittedDensity(
            stock: stock, logExposure: logExposure, channel: channel,
            settings: Settings(), positive: positive
        ) else { return 0 }
        return adjusted-neutral
    }

    static func fittedChannels(
        stock: String, logExposure: Double, settings: Settings,
        positive: Bool = false
    ) -> [Double] {
        (0..<3).map {
            fittedDensity(
                stock: stock, logExposure: logExposure, channel: $0,
                settings: settings, positive: positive
            ) ?? Double.nan
        }
    }
}
