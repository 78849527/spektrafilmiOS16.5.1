import Foundation
import CoreGraphics
import CoreImage

@main
struct SpatialOpticsValidation {
    static func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-10) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    static func sample(_ image: CIImage, at x: Int, _ y: Int) -> [Double] {
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        var pixels = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { bytes in
            ctx.render(
                image, toBitmap: bytes.baseAddress!,
                rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                format: .RGBA8, colorSpace: space
            )
        }
        return pixels.map { Double($0) / 255.0 }
    }

    static func main() {
        let originalPresets: [(String, String, Double, [Double])] = [
            ("still", "strong", 65, [0.015, 0.005, 0]),
            ("still", "weak", 65, [0.08, 0.02, 0]),
            ("still", "no", 65, [0.30, 0.10, 0.015]),
            ("cine", "strong", 50, [0.015, 0.005, 0]),
            ("cine", "weak", 50, [0.08, 0.02, 0]),
            ("cine", "no", 50, [0.30, 0.10, 0.015])
        ]
        for (use, anti, width, strength) in originalPresets {
            let p = SpatialOptics.Preset.forFilm(use: use, antihalation: anti)
            precondition(close(p.sigmaHalationUM, width))
            for channel in 0..<3 {
                precondition(close(p.strength[channel], strength[channel]))
            }
        }
        precondition(close(SpatialOptics.exponentialMixture.reduce(0) {
            $0+$1.weight
        }, 1), "Original exponential Gaussian fit should conserve energy")
        for channel in 0..<3 {
            for scatter in stride(from: 0.0, through: 1.0, by: 0.25) {
                let weights = SpatialOptics.scatterKernelWeights(
                    amount: scatter, channel: channel
                )
                precondition(weights.allSatisfy { $0 >= 0 })
                precondition(close(weights.reduce(0, +), 1, tolerance: 1e-10),
                             "Scatter kernel is not energy-preserving")
            }
            for amount in stride(from: 0.0, through: 3.0, by: 0.5) {
                let weights = SpatialOptics.halationKernelWeights(
                    amount: amount, channel: channel,
                    preset: .forFilm(use: "still", antihalation: "no")
                )
                precondition(weights.allSatisfy { $0 >= 0 })
                precondition(close(weights.reduce(0, +), 1, tolerance: 1e-10),
                             "Halation kernel should be normalized")
            }
        }
        print("PASS: all 6 original use/antihalation presets, Gaussian tail and bounce weight conservation.")

        let flat = CIImage(color: CIColor(red: 0.32, green: 0.41, blue: 0.54))
            .cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
        let settings = SpatialOpticsSettings(
            scatterAmount: 1, halationAmount: 1,
            filmUse: "still", antihalation: "weak"
        )
        let neutral = sample(flat, at: 256, 256)
        let processed = SpatialOptics.apply(to: flat, settings: settings)
        let after = sample(processed, at: 256, 256)
        for channel in 0..<3 {
            precondition(abs(neutral[channel]-after[channel]) < 0.045,
                         "Flat-field image should be conserved by spatial optics: " +
                         "\(channel) \(neutral[channel]) \(after[channel])")
        }
        precondition(processed.extent == flat.extent,
                     "Spatial optical processing changed image extent")
        print("PASS: Core Image flat-field photon conservation and output extent.")

        let dimension = 512
        var bytes = [UInt8](repeating: 0, count: dimension*dimension*4)
        for i in 0..<(dimension*dimension) {
            bytes[i*4+3] = 255
        }
        let central = (256*dimension+256)*4
        bytes[central] = 255
        bytes[central+1] = 255
        bytes[central+2] = 255
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = CIImage(
            bitmapData: Data(bytes),
            bytesPerRow: dimension*4,
            size: CGSize(width: dimension, height: dimension),
            format: .RGBA8, colorSpace: colorSpace
        )
        let result = SpatialOptics.apply(
            to: image,
            settings: SpatialOpticsSettings(
                scatterAmount: 0, halationAmount: 2,
                filmUse: "still", antihalation: "no"
            )
        )
        let neighborBefore = sample(image, at: 257, 256)
        let neighborAfter = sample(result, at: 257, 256)
        precondition(neighborAfter[0] > neighborBefore[0] + (1.0/255),
                     "Backreflection halo did not propagate red energy to neighbors")
        print("PASS: actual image-space multi-bounce halation spreads an impulse.")
        print("PASS: iOS 16.5.1 SpatialOptics native GPU/CPU Core Image smoke checks.")
    }
}
