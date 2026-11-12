import Foundation

@main
struct SpectralValidation {
    static func main() throws {
        let films = SpectralPhysics.supportedFilmIDs
        let papers = SpectralPhysics.supportedPaperIDs
        precondition(films.count == 6, "Expected six measured negative stocks")
        precondition(papers.count == 3, "Expected three measured papers")
        precondition(Set(films).count == films.count, "Duplicate film IDs")
        precondition(Set(papers).count == papers.count, "Duplicate paper IDs")

        func luminance(_ rgb: [Double]) -> Double {
            0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
        }
        func check(_ rgb: [Double], _ label: String) {
            precondition(rgb.count == 3 && rgb.allSatisfy {
                $0.isFinite && $0 >= 0 && $0 <= 1
            }, "\(label) is not finite sRGB")
        }

        let midGray = [0.4663, 0.4663, 0.4663]
        let dark = [0.08, 0.08, 0.08]
        let bright = [0.85, 0.85, 0.85]
        let red = [0.85, 0.15, 0.15]
        var fingerprints: [String: [Double]] = [:]

        for film in films {
            for paper in papers {
                let pair = film + " / " + paper
                let engine = try SpectralPhysics(filmID: film, paperID: paper)
                let middle = engine.render(midGray, exposureEV: 0, paperEV: 0)
                let shadow = engine.render(dark, exposureEV: 0, paperEV: 0)
                let light = engine.render(bright, exposureEV: 0, paperEV: 0)
                let chroma = engine.render(red, exposureEV: 0, paperEV: 0)
                let filmPlus = engine.render(midGray, exposureEV: 1, paperEV: 0)
                let paperPlus = engine.render(midGray, exposureEV: 0, paperEV: 1)

                [middle, shadow, light, chroma, filmPlus, paperPlus].forEach {
                    check($0, pair)
                }
                precondition(luminance(light) > luminance(shadow) + 0.05,
                             "Tonal direction is invalid: \(pair)")
                precondition(luminance(filmPlus) > luminance(middle) + 0.02,
                             "Camera exposure should brighten: \(pair)")
                precondition(luminance(paperPlus) < luminance(middle) - 0.02,
                             "Print exposure should darken: \(pair)")
                fingerprints[pair] = chroma
                print("PASS \(pair), red=\(chroma)")
            }
        }
        let a = fingerprints["kodak_portra_160 / kodak_portra_endura"]!
        let b = fingerprints["kodak_portra_800 / kodak_portra_endura"]!
        let c = fingerprints["kodak_portra_160 / fujifilm_crystal_archive_typeii"]!
        func maximumDelta(_ x: [Double], _ y: [Double]) -> Double {
            zip(x, y).map { abs($0.0 - $0.1) }.max() ?? 0
        }
        precondition(maximumDelta(a, b) > 0.005, "Film choice does not change simulated RGB")
        precondition(maximumDelta(a, c) > 0.005, "Paper choice does not change simulated RGB")

        let cube = try SpectralPhysics.makeCubeData(
            filmID: "kodak_portra_400",
            paperID: "kodak_portra_endura",
            exposureEV: 0, paperEV: 0, size: 9
        )
        precondition(cube.count == 9 * 9 * 9 * 4 * MemoryLayout<Float>.size,
                     "Wrong Core Image RGBA cube size")

        do {
            _ = try SpectralPhysics(filmID: "fujifilm_provia_100f",
                                    paperID: "kodak_portra_endura")
            preconditionFailure("Positive film must not silently simulate as negative")
        } catch is SpectralPhysics.PhysicsError {
            // Expected rejection of unsupported reverse-film processing.
        }

        print("PASS: 18 measured film/paper combinations and exposure/tonality checks.")
        print("PASS: different films and different papers change RGB independently.")
        print("PASS: generated internal 9^3 LUT size, unsupported stock rejected.")
    }
}
