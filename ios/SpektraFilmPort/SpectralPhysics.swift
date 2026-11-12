import Foundation

/// iOS 16.5.1 measured-spectra photo simulation.
/// Ported ORIGINAL Spektrafilm components: Hanatos2025 colour-to-raw LUT,
/// reflected Mitchell cubic sampling with per-film sensitivity adaptation,
/// plus the alternative Mallett2019 basis integration,
/// D55 camera light, sample-wise log-sensitivity, normalized H-D interpolation,
/// spectral negative/paper Beer-Lambert density, Schott KG3 3400K enlarger
/// plus original 0/65/55 CMY filtration, D50 viewing and CIE 1931 2° CMFs.
/// Still pending: Hanatos2025 correction SURFACE (window is supported),
/// DIR couplers, print-curve morph, scattering/grain/halation, glare, full scanner
/// white/black correction and gamut mapping. Outputs are NOT byte-for-byte
/// identical to a full original Spektrafilm render.
/// The per-pixel calculation is accelerated through a dynamic CIColorCube.
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
        let minimumDensity: [Double]    // upstream nanmin per colour channel
        let polarity: String
        let viewingIlluminant: String

        init(id: String) throws {
            guard let record = GeneratedSpectralData.profiles[id] else {
                throw PhysicsError.invalid("没有该胶片／相纸的实测曲线：" + id)
            }
            logSensitivity = try Self.decode(record.logSensitivity, count: 243)
            channelDensity = try Self.decode(record.channelDensity, count: 243)
            baseDensity = try Self.decode(record.baseDensity, count: 81)
            logExposure = try Self.decode(record.logExposure, count: 256)
            densityCurves = try Self.decode(record.densityCurves, count: 768)
            polarity = record.polarity
            viewingIlluminant = record.viewingIlluminant
            guard logExposure[0] < logExposure[255] else {
                throw PhysicsError.invalid("光谱数据的曝光曲线无效：" + id)
            }
            // spektrafilm.model.develop.develop() subtracts the full channel
            // minimum (not just densityCurves[0]) before interpolating.
            let measuredCurves = densityCurves
            minimumDensity = (0..<3).map { ch in
                (0..<256).map { i in
                    Double(measuredCurves[i * 3 + ch])
                }.min() ?? 0.0
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
            let lo = minimumDensity[channel]
            if logE <= first {
                return max(0, Double(densityCurves[channel]) - lo)
            }
            if logE >= last {
                return max(0, Double(densityCurves[255 * 3 + channel]) - lo)
            }
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
    private let isPositive: Bool
    private let hanatos: OriginalHanatosResponse
    private let filmMatrix: [[Double]]    // film channel -> source linear RGB
    private let paperWeights: [[Double]]  // wavelength -> paper channel
    private let scanWeights: [[Double]]   // wavelength -> CIE XYZ
    private let mediaWhiteXYZ: [Double]
    private let printReference: Double
    private let neutralOutputRGB: [Double]

    static var supportedFilmIDs: [String] { GeneratedSpectralData.filmIDs }
    static var supportedPaperIDs: [String] { GeneratedSpectralData.printMediumIDs }
    static var positiveFilmIDs: [String] { GeneratedSpectralData.positiveFilmIDs }
    static func isPositiveFilm(_ id: String) -> Bool {
        positiveFilmIDs.contains(id)
    }

    init(filmID: String, paperID: String) throws {
        guard Self.supportedFilmIDs.contains(filmID),
              Self.supportedPaperIDs.contains(paperID) else {
            throw PhysicsError.invalid("该胶片／相纸组合尚未接入光谱计算")
        }
        let originalFilm = try Profile(id: filmID)
        let originalPaper = try Profile(id: paperID)
        let originalHanatos = try OriginalHanatosResponse(filmID: filmID)
        let positive = originalFilm.polarity == "positive"
        let viewed = positive ? originalFilm : originalPaper
        film = originalFilm
        paper = originalPaper
        hanatos = originalHanatos
        isPositive = positive

        let basis = try Self.readOriginalFloat32(
            GeneratedOriginalOptics.mallettBasis, count: 81 * 3
        )
        let d55 = try Self.readOriginalFloat32(GeneratedOriginalOptics.d55, count: 81)
        let viewingIlluminant = viewed.viewingIlluminant == "K75P"
            ? GeneratedOriginalOptics.k75p : GeneratedOriginalOptics.d50
        let viewing = try Self.readOriginalFloat32(viewingIlluminant, count: 81)
        let cie = try Self.readOriginalFloat32(
            GeneratedOriginalOptics.cie1931, count: 81 * 3
        )
        // Original print balance database selects filter CC values per
        // film + printing-stock pair; do not reuse one neutral spectrum.
        let printKey = filmID + "|" + paperID
        let sourceIlluminant =
            GeneratedOriginalOptics.printIlluminantByPair[printKey] ??
            GeneratedOriginalOptics.enlargerNeutral
        let enlarger = try Self.readOriginalFloat32(
            sourceIlluminant, count: 81
        )
        var matrix = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var pWeights = Array(repeating: Array(repeating: 0.0, count: 3), count: 81)
        var xyzWeights = Array(repeating: Array(repeating: 0.0, count: 3), count: 81)
        var white = Array(repeating: 0.0, count: 3)

        // Exact original rgb_to_raw_mallett2019 einsum:
        // raw = sum(RGB[3] * basis[wl,3] * D55[wl] * sensitivity[wl,3])
        // and scalar normalisation against the green channel at 18.4% gray.
        var midgrayGreen = 0.0
        for i in 0..<81 {
            let light = d55[i]
            midgrayGreen += light * 0.184 * originalFilm.sensitivity(i, 1)
            for ch in 0..<3 {
                for rgb in 0..<3 {
                    matrix[ch][rgb] += basis[i * 3 + rgb] * light *
                        originalFilm.sensitivity(i, ch)
                }
                pWeights[i][ch] = enlarger[i] *
                    originalPaper.sensitivity(i, ch)
            }
            // Original scanning density-to-light and spectral integration
            // uses the 1931 2-degree CMFs and D50 viewing illumination.
            for ch in 0..<3 {
                xyzWeights[i][ch] = viewing[i] * cie[i * 3 + ch]
                white[ch] += xyzWeights[i][ch] *
                    pow(10.0, -viewed.base(i))
            }
        }
        guard midgrayGreen.isFinite && midgrayGreen > 1e-12 else {
            throw PhysicsError.invalid("原版 Mallett 光谱参考白归一化无效")
        }
        for ch in 0..<3 {
            for rgb in 0..<3 { matrix[ch][rgb] /= midgrayGreen }
        }
        filmMatrix = matrix
        paperWeights = pWeights
        scanWeights = xyzWeights
        mediaWhiteXYZ = white

        let midFilm = Self.filmDensities(
            [0.184, 0.184, 0.184], film: originalFilm,
            hanatos: originalHanatos, exposureEV: 0.0
        )
        let midMedium: [Double]
        if positive {
            // Original pipeline topology: positive reversal film is SCANNED
            // DIRECTLY after development. No printing medium or enlarger.
            printReference = 1.0
            midMedium = midFilm
        } else {
            let ref = Self.printRaw(
                filmDensities: midFilm, film: originalFilm, weights: pWeights
            )
            printReference = exp(
                ref.reduce(0.0) { $0 + log(max($1, 1e-14)) } / 3.0
            )
            midMedium = Self.paperDensities(
                midFilm, film: originalFilm, paper: originalPaper,
                weights: pWeights, reference: printReference, printEV: 0.0
            )
        }
        let midLinear = Self.scanLinear(
            midMedium, paper: viewed, weights: xyzWeights, mediaWhite: white
        )
        neutralOutputRGB = midLinear.map { max(1e-4, $0) }
    }

    static func makeCubeData(filmID: String, paperID: String,
                             exposureEV: Double, paperEV: Double,
                             size: Int = 17) throws -> Data {
        guard (9...33).contains(size),
              exposureEV.isFinite, paperEV.isFinite,
              abs(exposureEV) <= 4, abs(paperEV) <= 4 else {
            throw PhysicsError.invalid("无效的光谱模拟参数")
        }
        let engine = try SpectralPhysics(filmID: filmID, paperID: paperID)
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
            linear, film: film, hanatos: hanatos, exposureEV: exposureEV
        )
        let resultDensity: [Double]
        let substrate: Profile
        if isPositive {
            // Bypass printing exactly as upstream SimulationPipeline does
            // when io.scan_film is true for a reversal stock.
            resultDensity = filmDensity
            substrate = film
        } else {
            resultDensity = Self.paperDensities(
                filmDensity, film: film, paper: paper, weights: paperWeights,
                reference: printReference, printEV: paperEV
            )
            substrate = paper
        }
        let linOutput = Self.scanLinear(
            resultDensity, paper: substrate,
            weights: scanWeights, mediaWhite: mediaWhiteXYZ
        )
        // Display-neutral calibration for the iOS preview. The upstream
        // full scanner colour-reference calibration is a separate stage.
        return (0..<3).map { ch in
            let balanced = linOutput[ch] * (0.184 / neutralOutputRGB[ch])
            return Self.encodeSRGB(Self.clamp(balanced))
        }
    }

    private static func filmDensities(_ linear: [Double],
                                      film: Profile,
                                      hanatos: OriginalHanatosResponse,
                                      exposureEV: Double) -> [Double] {
        // This uses upstream Hanatos2025 irradiance LUT and CAT16/TC mapping,
        // rather than the earlier Mallett2019 alternative.
        let raw = hanatos.raw(linearRGB: linear)
        return (0..<3).map { channel in
            let response = max(1e-10, raw[channel])
            return film.curve(
                log10(response) + exposureEV * 0.301029995664,
                channel: channel
            )
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
                                       reference: Double, printEV: Double) -> [Double] {
        let raw = printRaw(filmDensities: filmDensities, film: film, weights: weights)
        return (0..<3).map { c in
            paper.curve(
                log10(max(1e-14, raw[c]) / reference) +
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

    /// Unaligned-safe little-endian Float32 decode, shared by the original
    /// reference spectra compiled into GeneratedOriginalOptics.swift.
    private static func readOriginalFloat32(_ encoded: String,
                                            count: Int) throws -> [Double] {
        guard let bytes = Data(base64Encoded: encoded),
              bytes.count == count * 4 else {
            throw PhysicsError.invalid("原版光谱参考数组数据损坏")
        }
        return bytes.withUnsafeBytes { raw in
            let data = raw.bindMemory(to: UInt8.self)
            return (0..<count).map { i in
                let j = i * 4
                let word = UInt32(data[j]) |
                    (UInt32(data[j + 1]) << 8) |
                    (UInt32(data[j + 2]) << 16) |
                    (UInt32(data[j + 3]) << 24)
                return Double(Float(bitPattern: word))
            }
        }
    }

    /// Diagnostic: numerically compare this Swift port's Mallett 2019 input
    /// against exact reference vectors produced by the original Python einsum.
    func mallettRaw(linearRGB: [Double]) -> [Double] {
        guard linearRGB.count == 3 else { return [] }
        return (0..<3).map { channel in
            max(0, (0..<3).reduce(0.0) {
                $0 + filmMatrix[channel][$1] * linearRGB[$1]
            })
        }
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
