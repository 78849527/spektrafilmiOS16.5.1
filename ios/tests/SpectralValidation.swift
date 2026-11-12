import Foundation

@main
struct SpectralValidation {
    static func main() throws {
        let engine = try SpectralPhysics()
        let neutral = [0.4663, 0.4663, 0.4663]
        let mid = engine.render(neutral, exposureEV: 0, paperEV: 0)
        let dark = engine.render([0.08, 0.08, 0.08], exposureEV: 0, paperEV: 0)
        let bright = engine.render([0.85, 0.85, 0.85], exposureEV: 0, paperEV: 0)
        let red = engine.render([0.85, 0.15, 0.15], exposureEV: 0, paperEV: 0)
        let green = engine.render([0.15, 0.85, 0.15], exposureEV: 0, paperEV: 0)
        let blue = engine.render([0.15, 0.15, 0.85], exposureEV: 0, paperEV: 0)
        let plusEV = engine.render(neutral, exposureEV: 1.0, paperEV: 0)
        let morePaper = engine.render(neutral, exposureEV: 0, paperEV: 1.0)

        let all = [mid, dark, bright, red, green, blue, plusEV, morePaper]
        for output in all {
            precondition(output.count == 3 && output.allSatisfy {
                $0.isFinite && $0 >= 0 && $0 <= 1
            }, "nonfinite/out-of-gamut physics output")
        }
        func luminance(_ values: [Double]) -> Double {
            values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        precondition(luminance(bright) > luminance(dark) + 0.05,
                     "neutral tone direction reversed")
        precondition(luminance(plusEV) > luminance(mid),
                     "film exposure not affecting brightness")
        precondition(luminance(morePaper) < luminance(mid),
                     "paper exposure not affecting brightness")
        precondition(abs(luminance(red) - luminance(blue)) > 0.001 ||
                     abs(red[0] - blue[0]) > 0.1,
                     "distinct colors collapsed")
        precondition(zip(mid, neutral).contains { abs($0.0 - $0.1) > 0.005 },
                     "physics unexpectedly exactly identity")
        let cube = try SpectralPhysics.makeCubeData(exposureEV: 0, paperEV: 0, size:9)
        precondition(cube.count == 9 * 9 * 9 * 4 * MemoryLayout<Float>.size,
                     "wrong Core Image cube byte size")
        print("PASS: native spectral calculations produce bounded RGB;")
        print("      increased film exposure brightens; increased paper exposure darkens;")
        print("      9^3 generated color cube has valid byte size.")
        print("MID=\(mid)  DARK=\(dark)  BRIGHT=\(bright)")
        print("RED=\(red)  GREEN=\(green)  BLUE=\(blue)")
        print("CAMERA+1EV=\(plusEV) PAPER+1EV=\(morePaper)")
    }
}
