import Foundation

/// Experimental, native iOS 16.5.1 spectral negative->paper calculation.
///
/// This physically motivated *subset* uses upstream Portra 400 / Portra
/// Endura measured sensitivity, H-D characteristic curves and wavelength-
/// dependent dye absorbances. It does NOT yet port original Hanatos spectral
/// upsampling, enlarger heat filters, color reference balancing, couplers,
/// film grain, halation, glare, or complete spectral rendering parity.
/// A small, runtime-generated CoreImage color cube accelerates pixel preview.
struct SpectralPhysics {
    enum PhysicsError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    private struct Profile {
        let logSensitivity: [Float]       // 81 x 3, wavelength-major
        let channelDensity: [Float]       // 81 x 3, wavelength-major
        let baseDensity: [Float]          // 81
        let logExposure: [Float]          // 256
        let densityCurves: [Float]        // 256 x 3, exposure-major

        init(prefix: String) throws {
            func encoded(_ key: String) -> String {
                switch (prefix, key) {
                case ("film", "log_sensitivity"): return GeneratedSpectralData.film_log_sensitivity
                case ("film", "channel_density"): return GeneratedSpectralData.film_channel_density
                case ("film", "base_density"): return GeneratedSpectralData.film_base_density
                case ("film", "log_exposure"): return GeneratedSpectralData.film_log_exposure
                case ("film", "density_curves"): return GeneratedSpectralData.film_density_curves
                case ("paper", "log_sensitivity"): return GeneratedSpectralData.paper_log_sensitivity
                case ("paper", "channel_density"): return GeneratedSpectralData.paper_channel_density
                case ("paper", "base_density"): return GeneratedSpectralData.paper_base_density
                case ("paper", "log_exposure"): return GeneratedSpectralData.paper_log_exposure
                case ("paper", "density_curves"): return GeneratedSpectralData.paper_density_curves
                default: return ""
                }
            }
            logSensitivity = try Self.decode(encoded("log_sensitivity"), count: 243)
            channelDensity = try Self.decode(encoded("channel_density"), count: 243)
            baseDensity = try Self.decode(encoded("base_density"), count: 81)
            logExposure = try Self.decode(encoded("log_exposure"), count: 256)
            densityCurves = try Self.decode(encoded("density_curves"), count: 768)
            guard logExposure[0] < logExposure[255] else {
                throw PhysicsError.invalid("光谱数据的曝光曲线无效")
            }
        }

        /// Explicit little-endian decode avoids unaligned Float pointers on
        /// some iOS 16 Data implementations.
        private static func decode(_ string: String, count: Int) throws -> [Float] {
            guard let data = Data(base64Encoded: string),
                  data.count == count * MemoryLayout<Float>.size else {
                throw PhysicsError.invalid("测量数据损坏或缺少：\(count) 个采样")
            }
            return data.withUnsafeBytes { unsafeBytes in
                let bytes = unsafeBytes.bindMemory(to: UInt8.self)
                return (0..<count).map { i in
                    let base = i * 4
                    let bits = UInt32(bytes[base])
                        | UInt32(bytes[base + 1]) << 8
                        | UInt32(bytes[base + 2]) << 16
                        | UInt32(bytes[base + 3]) << 24
                    return Float(bitPattern: bits)
                }
            }
        }

        func curve(_ logE: Double, channel: Int) -> Double {
            let first = Double(logExposure[0])
            let last = Double(logExposure[255])
            let lo = Double(densityCurves[channel])
            if logE <= first { return max(0, lo) }
            if logE >= last { return max(0, Double(densityCurves[255 * 3 + channel])) }
            // The original profile sampled the same log-exposure grid in each
            // channel, preserving native linear interpolation.
            let u = (logE - first) / (last - first) * 255.0
            let index = min(254, max(0, Int(floor(u))))
            let weight = min(1, max(0, u - Double(index)))
            let start = Double(densityCurves[index * 3 + channel])
            let end = Double(densityCurves[(index + 1) * 3 + channel])
            return max(0, start + (end - start) * weight - lo)
        }

        func sensitivity(_ wavelengthIndex: Int, _ ch: Int) -> Double {
            pow(10.0, Double(logSensitivity[wavelengthIndex * 3 + ch]))
        }

        func dyeAbsorbance(_ wavelengthIndex: Int, _ ch: Int) -> Double {
            Double(channelDensity[wavelengthIndex * 3 + ch])
        }

        func base(_ wavelengthIndex: Int) -> Double {
            Double(baseDensity[wavelengthIndex])
        }
    }

    private let film: Profile
    private let paper: Profile
    private let filmMatrix: [[Double]]    // film channel -> source linear RGB
    private let paperWeights: [[Double]]  // wavelength -> paper channel
    private let scanWeights: [[Double]]   // wavelength -> CIE XYZ
    private let mediaWhiteXYZ: [Double]
    private let printReference: [Double]
    private let neutralOutputRGB: [Double]

    init() throws {
        film = try Profile(prefix: "film")
        paper = try Profile(prefix: "paper")

        var matrix = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var pWeights = Array(repeating: Array(repeating: 0.0, count: 3), count: 81)
        var xyzWeights = Array(repeating: Array(repeating: 0.0, count: 3), count: 81)
        var white = Array(repeating: 0.0, count: 3)

        for i in 0..<81 {
            let wavelength = 380.0 + Double(i) * 5.0
            let daylight = Self.blackBody(wavelength, 5500)
            let enlarger = Self.blackBody(wavelength, 3400)
            let viewing = Self.blackBody(wavelength, 5000)
            let bases = [
                Self.gaussian(wavelength, 615, 44),
                Self.gaussian(wavelength, 545, 37),
                Self.gaussian(wavelength, 457, 32)
            ]
            for ch in 0..<3 {
                for rgb in 0..<3 {
                    matrix[ch][rgb] += daylight * bases[rgb] * film.sensitivity(i, ch)
                }
                pWeights[i][ch] = enlarger * paper.sensitivity(i, ch)
            }

            let cie = Self.cie1931(wavelength)
            let whiteLight = viewing * pow(10.0, -paper.base(i))
            for ch in 0..<3 {
                xyzWeights[i][ch] = viewing * cie[ch]
                white[ch] += xyzWeights[i][ch] * pow(10.0, -paper.base(i))
            }
            _ = whiteLight
        }
        // Calibrate each film-sensitivity channel so linear sRGB midgray maps
        // to log10 exposure=0. The spectral upsampling is an approximation,
        // NOT the original project's Hanatos 2025 transform.
        for ch in 0..<3 {
            let mid = max(1e-14, matrix[ch].reduce(0, +) * 0.184)
            for rgb in 0..<3 { matrix[ch][rgb] /= mid }
        }
        filmMatrix = matrix
        paperWeights = pWeights
        scanWeights = xyzWeights
        mediaWhiteXYZ = white

        let midFilm = Self.filmDensities(
            [0.184, 0.184, 0.184], film: film, matrix: matrix, exposureEV: 0.0
        )
        let ref = Self.printRaw(filmDensities: midFilm, film: film, weights: pWeights)
        printReference = ref.map { max($0, 1e-14) }

        let midPaper = Self.paperDensities(
            midFilm, film: film, paper: paper, weights: pWeights,
            reference: printReference, printEV: 0.0
        )
        let midLinear = Self.scanLinear(
            midPaper, paper: paper, weights: xyzWeights, mediaWhite: white
        )
        neutralOutputRGB = midLinear.map { max(1e-4, $0) }
    }

    static func makeCubeData(exposureEV: Double, paperEV: Double,
                             size: Int = 17) throws -> Data {
        guard (9...33).contains(size),
              exposureEV.isFinite, paperEV.isFinite,
              abs(exposureEV) <= 4, abs(paperEV) <= 4 else {
            throw PhysicsError.invalid("无效的光谱模拟参数")
        }
        let engine = try SpectralPhysics()
        let interval = 1.0 / Double(size - 1)
        var output = [Float]()
        output.reserveCapacity(size * size * size * 4)
        // Adobe .cube / Core Image: red changes fastest, then green, blue.
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rgb = engine.render(
                        [Double(r) * interval, Double(g) * interval, Double(b) * interval],
                        exposureEV: exposureEV, paperEV: paperEV
                    )
                    output.append(contentsOf: [Float(rgb[0]), Float(rgb[1]),
                                               Float(rgb[2]), 1])
                }
            }
        }
        return output.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: $0.count * MemoryLayout<Float>.size)
        }
    }

    /// Encoded sRGB -> approximately measured negative and paper -> encoded sRGB.
    func render(_ srgb: [Double], exposureEV: Double, paperEV: Double) -> [Double] {
        let linear = srgb.map { Self.decodeSRGB(Self.clamp($0)) }
        let filmDensity = Self.filmDensities(
            linear, film: film, matrix: filmMatrix, exposureEV: exposureEV
        )
        let paperDensity = Self.paperDensities(
            filmDensity, film: film, paper: paper, weights: paperWeights,
            reference: printReference, printEV: paperEV
        )
        let linOutput = Self.scanLinear(
            paperDensity, paper: paper, weights: scanWeights, mediaWhite: mediaWhiteXYZ
        )
        // Midgray scanner calibration, leaving paper's tonal response intact.
        return (0..<3).map { ch in
            let balanced = linOutput[ch] * (0.184 / neutralOutputRGB[ch])
            return Self.encodeSRGB(Self.clamp(balanced))
        }
    }

    private static func filmDensities(_ linear: [Double], film: Profile,
                                      matrix: [[Double]], exposureEV: Double) -> [Double] {
        (0..<3).map { ch in
            let response = max(1e-12, (0..<3).reduce(0.0) {
                $0 + matrix[ch][$1] * linear[$1]
            })
            return film.curve(log10(response) + exposureEV * 0.301029995664, channel: ch)
        }
    }

    private static func printRaw(filmDensities: [Double], film: Profile,
                                 weights: [[Double]]) -> [Double] {
        var raw = [0.0, 0.0, 0.0]
        for i in 0..<81 {
            var spectralDensity = film.base(i)
            for c in 0..<3 {
                spectralDensity += film.dyeAbsorbance(i, c) * filmDensities[c]
            }
            let transmission = pow(10.0, -max(0, spectralDensity))
            for c in 0..<3 { raw[c] += weights[i][c] * transmission }
        }
        return raw
    }

    private static func paperDensities(_ filmDensities: [Double], film: Profile,
                                       paper: Profile, weights: [[Double]],
                                       reference: [Double], printEV: Double) -> [Double] {
        let raw = printRaw(filmDensities: filmDensities, film: film, weights: weights)
        return (0..<3).map { c in
            paper.curve(
                log10(max(1e-14, raw[c]) / reference[c]) +
                    printEV * 0.301029995664, channel: c
            )
        }
    }

    private static func scanLinear(_ densities: [Double], paper: Profile,
                                   weights: [[Double]], mediaWhite: [Double]) -> [Double] {
        var xyz = [0.0, 0.0, 0.0]
        for i in 0..<81 {
            var density = paper.base(i)
            for c in 0..<3 {
                density += paper.dyeAbsorbance(i, c) * densities[c]
            }
            let trans = pow(10.0, -max(0, density))
            for c in 0..<3 { xyz[c] += trans * weights[i][c] }
        }
        // Adapt measured paper base white to display D65. This is a simple
        // white calibration, not upstream CAT16 / glare / gamut compression.
        let x = xyz[0] / max(mediaWhite[0], 1e-14) * 0.95047
        let y = xyz[1] / max(mediaWhite[1], 1e-14)
        let z = xyz[2] / max(mediaWhite[2], 1e-14) * 1.08883
        return [
            3.2406 * x - 1.5372 * y - 0.4986 * z,
           -0.9689 * x + 1.8758 * y + 0.0415 * z,
            0.0557 * x - 0.2040 * y + 1.0570 * z,
        ]
    }

    private static func cie1931(_ wl: Double) -> [Double] {
        // Wyman/Sloan/Shirley (2013) smooth CIE 1931 2-degree approximation.
        [
            1.056 * gaussian(wl, 599.8, 37.9) +
            0.362 * gaussian(wl, 442.0, 16.0) -
            0.065 * gaussian(wl, 501.1, 20.4),
            0.821 * gaussian(wl, 568.8, 46.9) +
            0.286 * gaussian(wl, 530.9, 16.3),
            1.217 * gaussian(wl, 437.0, 11.8) +
            0.681 * gaussian(wl, 459.0, 26.0),
        ]
    }
    private static func gaussian(_ x: Double, _ center: Double, _ sigma: Double) -> Double {
        let d = (x - center) / sigma
        return exp(-0.5 * d * d)
    }
    private static func blackBody(_ nm: Double, _ kelvin: Double) -> Double {
        // Relative Planck radiance; absolute normalization cancels.
        let meters = nm * 1e-9
        let exponent = 0.0143877696 / (meters * kelvin)
        return 1.0 / (pow(meters * 1e6, 5) * expm1(exponent))
    }
    private static func clamp(_ x: Double) -> Double {
        min(1, max(0, x.isFinite ? x : 0))
    }
    private static func decodeSRGB(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }
    private static func encodeSRGB(_ x: Double) -> Double {
        x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
    }
}
