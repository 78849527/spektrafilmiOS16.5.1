import Foundation

/// iOS 16.5.1 measured-spectra photo simulation.
/// Ported ORIGINAL Spektrafilm components: Hanatos2025 colour-to-raw LUT,
/// reflected Mitchell cubic sampling with per-film sensitivity adaptation,
/// plus the alternative Mallett2019 basis integration,
/// D55 camera light, sample-wise log-sensitivity, normalized H-D interpolation,
/// spectral negative/paper Beer-Lambert density, Schott KG3 3400K enlarger
/// plus original 0/65/55 CMY filtration, D50 viewing and CIE 1931 2° CMFs.
/// Still pending: Hanatos2025 correction SURFACE (window is supported),
/// spatial DIR diffusion, print-curve morph, scattering/grain/halation, glare,
/// and full scanner calibration. Native original nonspatial DIR chemistry is included.
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
        let densityCurvesLayers: [Float]  // 256 x 3 layers x 3 CMY
        let minimumDensity: [Double]    // upstream nanmin per colour channel
        let dirCorrectedCurves: [Float]  // upstream pre-DIR normalized H-D
        let dirMatrix: [Double]          // donor (row) -> receiver (column)
        let densityMaximum: [Double]
        let polarity: String
        let viewingIlluminant: String
        let id: String

        init(id: String) throws {
            guard let record = GeneratedSpectralData.profiles[id] else {
                throw PhysicsError.invalid("没有该胶片／相纸的实测曲线：" + id)
            }
            self.id = id
            logSensitivity = try Self.decode(record.logSensitivity, count: 243)
            channelDensity = try Self.decode(record.channelDensity, count: 243)
            baseDensity = try Self.decode(record.baseDensity, count: 81)
            logExposure = try Self.decode(record.logExposure, count: 256)
            densityCurves = try Self.decode(record.densityCurves, count: 768)
            densityCurvesLayers = record.densityCurvesLayers.isEmpty
                ? [] : try Self.decode(record.densityCurvesLayers, count: 2304)
            if let dir = GeneratedDIRData.records[id] {
                dirCorrectedCurves = try Self.decode(dir.correctedCurves, count: 768)
                dirMatrix = dir.donorReceiverMatrix
                densityMaximum = dir.sourceDensityMax
            } else {
                // Print media do not use negative-film DIR inhibition.
                dirCorrectedCurves = []
                dirMatrix = Array(repeating: 0.0, count: 9)
                densityMaximum = Array(repeating: 0.0, count: 3)
            }
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

        func curve(_ logE: Double, channel: Int,
                   correctedBeforeDIR: Bool = false) -> Double {
            let first = Double(logExposure[0])
            let last = Double(logExposure[255])
            let useCorrected = correctedBeforeDIR && !dirCorrectedCurves.isEmpty
            let curves = useCorrected ? dirCorrectedCurves : densityCurves
            let minDensity = useCorrected ? 0 : minimumDensity[channel]
            if logE <= first {
                return max(0, Double(curves[channel]) - minDensity)
            }
            if logE >= last {
                return max(0, Double(curves[255 * 3 + channel]) - minDensity)
            }
            let u = (logE - first) / (last - first) * 255
            let index = min(254, max(0, Int(floor(u))))
            let weight = min(1, max(0, u - Double(index)))
            let y0 = Double(curves[index * 3 + channel])
            let y1 = Double(curves[(index + 1) * 3 + channel])
            return max(0, y0 + (y1 - y0) * weight - minDensity)
        }

        /// Original interp_density_cmy_layers(): invert each stock's
        /// measured normalized total H-D characteristic and sample its
        /// measured 3 separate sublayer densities at that same exposure.
        /// Reversal stocks invert with -density / -curve so the lookup
        /// direction is monotonically increasing (model/density_curves.py).
        func layerDensity(total: Double, channel: Int, sublayer: Int) -> Double {
            guard !densityCurvesLayers.isEmpty else { return 0 }
            let sign = polarity == "positive" ? -1.0 : 1.0
            let desired = total * sign
            func domain(_ index: Int) -> Double {
                (Double(densityCurves[index * 3 + channel]) -
                 minimumDensity[channel]) * sign
            }
            func value(_ index: Int) -> Double {
                Double(densityCurvesLayers[
                    index * 9 + sublayer * 3 + channel
                ])
            }
            if desired <= domain(0) { return max(0, value(0)) }
            if desired >= domain(255) { return max(0, value(255)) }
            var lo = 0
            var hi = 255
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if domain(mid) <= desired { lo = mid }
                else { hi = mid }
            }
            let delta = domain(hi) - domain(lo)
            if delta <= 1e-12 { return max(0, value(hi)) }
            let t = min(1, max(0, (desired-domain(lo))/delta))
            return max(0, value(lo)+(value(hi)-value(lo))*t)
        }

        var sublayerMaxima: [Double] {
            guard !densityCurvesLayers.isEmpty else { return [] }
            return (0..<9).map { k in
                (0..<256).reduce(0.0) { maximum, i in
                    max(maximum, Double(densityCurvesLayers[i*9+k]))
                }
            }
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
    private let opticalPreflashRaw: [Double]
    private let useOriginalPrintOptics: Bool
    private let scanWeights: [[Double]]   // wavelength -> CIE XYZ
    private let mediaWhiteXYZ: [Double]
    private let printReference: Double
    private let neutralOutputRGB: [Double]
    private let useOriginalScanner: Bool
    private let useReferenceBlackWhite: Bool
    private let useExposureCorrectedPrintReference: Bool
    private let printMorphCurve: OriginalPrintMorph.PreparedCurve?
    private var correctedPrintExposureEV = 0.0
    private var correctedReferenceBlack: Double?
    private var correctedReferenceWhite: Double?
    private let defaultCAM16Gamut: Bool
    private let viewingStock: String
    private let viewingNormalization: Double
    private let scannedReferenceYBlack: Double
    private let scannedReferenceYWhite: Double

    /// Independent source H-D layer interpolation diagnostics for v1.6.
    /// Each layer is in optical density (never display RGB).
    static func measuredSublayers(
        filmID: String, normalizedTotal: [Double]
    ) throws -> (layers: [Double], maxima: [Double]) {
        guard normalizedTotal.count == 3,
              normalizedTotal.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw PhysicsError.invalid("无效的测量亚层密度向量")
        }
        let measured = try Profile(id: filmID)
        guard measured.sublayerMaxima.count == 9 else {
            throw PhysicsError.invalid("缺少实测亚层曲线")
        }
        return (
            (0..<3).flatMap { layer in
                (0..<3).map { channel in
                    measured.layerDensity(
                        total: normalizedTotal[channel],
                        channel: channel,
                        sublayer: layer
                    )
                }
            },
            measured.sublayerMaxima
        )
    }

    static var supportedFilmIDs: [String] { GeneratedSpectralData.filmIDs }
    static var supportedPaperIDs: [String] { GeneratedSpectralData.printMediumIDs }
    static var positiveFilmIDs: [String] { GeneratedSpectralData.positiveFilmIDs }
    static func isPositiveFilm(_ id: String) -> Bool {
        positiveFilmIDs.contains(id)
    }

    init(filmID: String, paperID: String,
         sourceScanner: Bool = false, scannerBlackWhite: Bool = false,
         cam16Gamut: Bool = false,
         printReferenceCorrection: Bool = false,
         printMorph: OriginalPrintMorph.Settings = .init(),
         printOptics: OriginalPrintOptics.Settings = .init(),
         cameraExposureEV: Double = 0) throws {
        guard Self.supportedFilmIDs.contains(filmID),
              Self.supportedPaperIDs.contains(paperID) else {
            throw PhysicsError.invalid("该胶片／相纸组合尚未接入光谱计算")
        }
        let originalFilm = try Profile(id: filmID)
        let originalPaper = try Profile(id: paperID)
        let originalHanatos = try OriginalHanatosResponse(filmID: filmID)
        let positive = originalFilm.polarity == "positive"
        guard !printOptics.enabled || printOptics.isValid else {
            throw PhysicsError.invalid("原版印相滤色或预闪光参数超出范围")
        }
        useOriginalPrintOptics = !positive && printOptics.enabled
        let viewed = positive ? originalFilm : originalPaper
        film = originalFilm
        paper = originalPaper
        hanatos = originalHanatos
        isPositive = positive
        useOriginalScanner = sourceScanner
        useReferenceBlackWhite = scannerBlackWhite
        defaultCAM16Gamut = cam16Gamut
        useExposureCorrectedPrintReference = !positive &&
            sourceScanner && scannerBlackWhite && printReferenceCorrection
        printMorphCurve = positive ? nil : OriginalPrintMorph.prepare(
            stock: paperID, logExposure: originalPaper.logExposure,
            settings: printMorph, positive: originalPaper.polarity == "positive"
        )

        let basis = try Self.readOriginalFloat32(
            GeneratedOriginalOptics.mallettBasis, count: 81 * 3
        )
        let d55 = try Self.readOriginalFloat32(GeneratedOriginalOptics.d55, count: 81)
        let viewingIlluminant = viewed.viewingIlluminant == "K75P"
            ? GeneratedOriginalOptics.k75p : GeneratedOriginalOptics.d50
        let viewing = try Self.readOriginalFloat32(viewingIlluminant, count: 81)
        let stock = viewed.viewingIlluminant == "K75P" ? "K75P" : "D50"
        viewingStock = stock
        viewingNormalization = GeneratedScannerReference.xyzYNormalization[stock] ?? 1
        let cie = try Self.readOriginalFloat32(
            GeneratedOriginalOptics.cie1931, count: 81 * 3
        )
        // Original print balance database selects filter CC values per
        // film + printing-stock pair; do not reuse one neutral spectrum.
        let printKey = filmID + "|" + paperID
        let sourceIlluminant =
            GeneratedOriginalOptics.printIlluminantByPair[printKey] ??
            GeneratedOriginalOptics.enlargerNeutral
        let opticalLighting: OriginalPrintOptics.Prepared?
        if useOriginalPrintOptics {
            let unfiltered = try Self.readOriginalFloat32(
                GeneratedOriginalOptics.enlargerSource, count: 81
            )
            let mediaSensitivities = (0..<81).map { index in
                (0..<3).map { originalPaper.sensitivity(index, $0) }
            }
            opticalLighting = OriginalPrintOptics.prepare(
                source: unfiltered,
                neutralCC: GeneratedOriginalOptics.neutralCMYByPair[printKey]
                    ?? [0, 65, 55],
                settings: printOptics,
                filmBase: (0..<81).map { originalFilm.base($0) },
                paperSensitivity: mediaSensitivities
            )
        } else {
            opticalLighting = nil
        }
        opticalPreflashRaw = opticalLighting?.preflashRaw ?? [0, 0, 0]
        let enlarger = try opticalLighting?.printIlluminant ??
            Self.readOriginalFloat32(sourceIlluminant, count: 81)
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

        // The upstream print reference uses develop_simple (NO couplers),
        // while the actual film processing uses the original DIR chemistry.
        let midFilmReference = Self.filmDensities(
            [0.184, 0.184, 0.184], film: originalFilm,
            hanatos: originalHanatos, exposureEV: 0,
            applyDIR: false
        )
        let midFilm = Self.filmDensities(
            [0.184, 0.184, 0.184], film: originalFilm,
            hanatos: originalHanatos, exposureEV: 0, applyDIR: true
        )
        let midMedium: [Double]
        if positive {
            // Original pipeline topology: positive reversal film is SCANNED
            // DIRECTLY after development. No printing medium or enlarger.
            printReference = 1.0
            midMedium = midFilm
        } else {
            let ref = Self.printRaw(
                filmDensities: midFilmReference, film: originalFilm,
                weights: pWeights, clampDensity: !useOriginalPrintOptics
            )
            if useOriginalPrintOptics {
                // Original four-mode branch in PrintingStage's midgray
                // exposure compensation. The source computes both 0 EV
                // and camera-compensated 18.4% gray using develop_simple.
                let referenceComp: [Double]
                if printOptics.printExposureCompensation {
                    let compensatedDensity = Self.filmDensities(
                        [0.184, 0.184, 0.184], film: originalFilm,
                        hanatos: originalHanatos,
                        exposureEV: cameraExposureEV,
                        applyDIR: false
                    )
                    referenceComp = Self.printRaw(
                        filmDensities: compensatedDensity,
                        film: originalFilm, weights: pWeights,
                        clampDensity: false
                    )
                } else {
                    referenceComp = ref
                }
                printReference = OriginalPrintOptics.referenceDivisor(
                    midgrayRaw: ref, compensatedRaw: referenceComp,
                    normalize: printOptics.normalizePrintExposure,
                    compensate: printOptics.printExposureCompensation
                )
            } else {
                printReference = exp(
                    ref.reduce(0.0) { $0 + log(max($1, 1e-14)) } / 3.0
                )
            }
            midMedium = Self.paperDensities(
                midFilm, film: originalFilm, paper: originalPaper,
                weights: pWeights, reference: printReference, printEV: 0.0,
                preflashRaw: opticalPreflashRaw,
                opticalPrint: useOriginalPrintOptics
            )
        }
        let midLinear = Self.scanLinear(
            midMedium, paper: viewed, weights: xyzWeights, mediaWhite: white
        )
        neutralOutputRGB = midLinear.map { max(1e-4, $0) }

        // In the original ColorReferenceService, the white/black
        // reference for printed negatives comes from printing calibrated
        // black/white densities; this mobile variant currently estimates
        // them from measured H-D endpoints and labels the UI accordingly.
        let densityMax = (0..<3).map { ch -> Double in
            let maximum = (0..<256).map { i in
                Double(viewed.densityCurves[i*3+ch])
            }.max() ?? 0
            return max(0, maximum-viewed.minimumDensity[ch])
        }
        let y0 = Self.scanPhysicalXYZ(
            densities: [0,0,0], paper: viewed, weights: xyzWeights,
            normalization: viewingNormalization
        )[1]
        let y1 = Self.scanPhysicalXYZ(
            densities: densityMax, paper: viewed, weights: xyzWeights,
            normalization: viewingNormalization
        )[1]
        scannedReferenceYBlack = min(y0, y1)
        scannedReferenceYWhite = max(y0, y1)

        if useExposureCorrectedPrintReference {
            // Source PrintingStage.expose: film black = -grain density_min,
            // film white = raw maximum of the three measured density curves.
            // Unlike v1.2 endpoint-only calibration this runs both through
            // the film->enlarger->paper H-D response and then through the
            // CIE viewing scanner. It also inverts the H-D midgray response
            // to obtain the source-style print exposure compensation.
            let filmBlack = [-0.03,-0.03,-0.03]
            let filmWhite = (0..<3).map { ch -> Double in
                (0..<256).map {
                    Double(originalFilm.densityCurves[$0*3+ch])
                }.max() ?? 0
            }
            let paperBlack = Self.paperDensities(
                filmBlack, film: originalFilm, paper: originalPaper,
                weights: pWeights, reference: printReference, printEV: 0,
                preflashRaw: opticalPreflashRaw,
                opticalPrint: useOriginalPrintOptics
            )
            let paperWhite = Self.paperDensities(
                filmWhite, film: originalFilm, paper: originalPaper,
                weights: pWeights, reference: printReference, printEV: 0,
                preflashRaw: opticalPreflashRaw,
                opticalPrint: useOriginalPrintOptics
            )
            let measuredBlack = Self.scanPhysicalXYZ(
                densities: paperBlack, paper: originalPaper,
                weights: xyzWeights, normalization: viewingNormalization
            )[1]
            let measuredWhite = Self.scanPhysicalXYZ(
                densities: paperWhite, paper: originalPaper,
                weights: xyzWeights, normalization: viewingNormalization
            )[1]
            // Original reference ordering is the printing path's
            // film-black -> dark print; film-white -> bright print.
            if let correction = OriginalPrintReference.apply(
                yBlack: measuredBlack, yWhite: measuredWhite,
                logExposure: originalPaper.logExposure,
                rawCurves: originalPaper.densityCurves,
                spectralBase: originalPaper.baseDensity
            ) {
                correctedPrintExposureEV = correction.exposureEV
                correctedReferenceBlack = correction.yBlack
                correctedReferenceWhite = correction.yWhite
            }
        }
    }

    static func makeCubeData(filmID: String, paperID: String,
                             exposureEV: Double, paperEV: Double,
                             size: Int = 17,
                             sourceScanner: Bool = false,
                             scannerBlackWhite: Bool = false,
                             cam16Gamut: Bool = false,
                             printReferenceCorrection: Bool = false,
                             printMorph: OriginalPrintMorph.Settings = .init(),
                             printOptics: OriginalPrintOptics.Settings = .init()
    ) throws -> Data {
        guard (9...33).contains(size),
              exposureEV.isFinite, paperEV.isFinite,
              abs(exposureEV) <= 4, abs(paperEV) <= 4 else {
            throw PhysicsError.invalid("无效的光谱模拟参数")
        }
        let engine = try SpectralPhysics(
            filmID: filmID, paperID: paperID,
            sourceScanner: sourceScanner, scannerBlackWhite: scannerBlackWhite,
            cam16Gamut: cam16Gamut,
            printReferenceCorrection: printReferenceCorrection,
            printMorph: printMorph, printOptics: printOptics,
            cameraExposureEV: exposureEV
        )
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

    /// Build two native CIColorCube stages:
    /// sRGB -> original Hanatos + DIR film *densities* -> optical print/scan.
    /// Unlike putting noise on final RGB, this permits a stochastic density
    /// layer between physical film development and photographic printing.
    /// Cubic interpolation is the mobile approximation to full per-pixel
    /// spectral inversion, not byte-exact source rendering.
    struct DensityStageData {
        let inputCube: Data
        let printCube: Data
        let ranges: [Double]       // normalize 3 film optical-density channels
        let size: Int
        let sublayerCubes: [Data]    // each 3D cube: source total D -> one real sublayer
        let sublayerRawMaxima: [Double] // 3 sublayers x CMY
    }

    static func makeDensityStageData(
        filmID: String, paperID: String,
        exposureEV: Double, paperEV: Double, size: Int = 17,
        sourceScanner: Bool = false, scannerBlackWhite: Bool = false,
        cam16Gamut: Bool = false,
        printReferenceCorrection: Bool = false,
        printMorph: OriginalPrintMorph.Settings = .init(),
        printOptics: OriginalPrintOptics.Settings = .init()
    ) throws -> DensityStageData {
        guard (9...33).contains(size), exposureEV.isFinite, paperEV.isFinite,
              abs(exposureEV) <= 4, abs(paperEV) <= 4 else {
            throw PhysicsError.invalid("无效的胶片密度分段计算参数")
        }
        let engine = try SpectralPhysics(
            filmID: filmID, paperID: paperID,
            sourceScanner: sourceScanner, scannerBlackWhite: scannerBlackWhite,
            cam16Gamut: cam16Gamut,
            printReferenceCorrection: printReferenceCorrection,
            printMorph: printMorph, printOptics: printOptics,
            cameraExposureEV: exposureEV
        )
        let ranges = engine.film.densityMaximum.map { max(0.25, $0 + 0.25) }
        let layerMaxima = engine.film.sublayerMaxima
        let step = 1.0 / Double(size-1)
        var input = [Float]()
        var printMap = [Float]()
        var sublayerMaps = [[Float]](
            repeating: [], count: 3
        )
        input.reserveCapacity(size*size*size*4)
        printMap.reserveCapacity(size*size*size*4)
        for sub in 0..<3 {
            sublayerMaps[sub].reserveCapacity(size*size*size*4)
        }
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rgb = [Double(r)*step, Double(g)*step, Double(b)*step]
                    let linear = rgb.map { decodeSRGB(clamp($0)) }
                    let density = filmDensities(
                        linear, film: engine.film, hanatos: engine.hanatos,
                        exposureEV: exposureEV
                    )
                    for channel in 0..<3 {
                        input.append(Float(clamp(density[channel]/ranges[channel])))
                    }
                    input.append(1.0)
                    let filmDensity = (0..<3).map { rgb[$0] * ranges[$0] }
                    if layerMaxima.count == 9 {
                        for layer in 0..<3 {
                            for channel in 0..<3 {
                                let measured = engine.film.layerDensity(
                                    total: filmDensity[channel],
                                    channel: channel, sublayer: layer
                                )
                                // Normalize to per-layer raw optical maxima.
                                let peak = max(
                                    1e-5,
                                    layerMaxima[layer*3+channel]
                                )
                                sublayerMaps[layer].append(
                                    Float(clamp(measured/peak))
                                )
                            }
                            sublayerMaps[layer].append(1)
                        }
                    }
                    let finalRGB = engine.scanFilmDensity(filmDensity, paperEV: paperEV)
                    printMap.append(Float(finalRGB[0]))
                    printMap.append(Float(finalRGB[1]))
                    printMap.append(Float(finalRGB[2]))
                    printMap.append(1.0)
                }
            }
        }
        let cubeA = input.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: $0.count * MemoryLayout<Float>.size)
        }
        let cubeB = printMap.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: $0.count * MemoryLayout<Float>.size)
        }
        let layerCubes = sublayerMaps.compactMap { values -> Data? in
            guard values.count == size*size*size*4 else { return nil }
            return values.withUnsafeBufferPointer { pointer in
                Data(bytes: pointer.baseAddress!,
                     count: pointer.count * MemoryLayout<Float>.size)
            }
        }
        return DensityStageData(
            inputCube: cubeA, printCube: cubeB, ranges: ranges, size: size,
            sublayerCubes: layerCubes,
            sublayerRawMaxima: layerMaxima
        )
    }

    /// Build source DIR spatial inputs from the SAME Hanatos raw light
    /// and measured H-D curves used by the existing nonspatial branch.
    /// The iOS spatial GPU stage acts on intermediate *film* buffers;
    /// the final printCube remains the source spectral paper/scan route.
    static func makeSpatialDIRStageData(
        filmID: String, paperID: String,
        exposureEV: Double, paperEV: Double,
        size: Int = 17, correctedSize: Int = 33,
        sourceScanner: Bool = false, scannerBlackWhite: Bool = false,
        cam16Gamut: Bool = false,
        printReferenceCorrection: Bool = false,
        printMorph: OriginalPrintMorph.Settings = .init(),
        printOptics: OriginalPrintOptics.Settings = .init()
    ) throws -> SpatialDIRStage {
        guard (9...33).contains(size), (17...33).contains(correctedSize),
              exposureEV.isFinite, abs(exposureEV) <= 4 else {
            throw PhysicsError.invalid("无效的 DIR 空间显影参数")
        }
        let pair = try makeDensityStageData(
            filmID: filmID, paperID: paperID, exposureEV: exposureEV,
            paperEV: paperEV, size: size,
            sourceScanner: sourceScanner, scannerBlackWhite: scannerBlackWhite,
            cam16Gamut: cam16Gamut,
            printReferenceCorrection: printReferenceCorrection,
            printMorph: printMorph, printOptics: printOptics
        )
        let stock = try Profile(id: filmID)
        let response = try OriginalHanatosResponse(filmID: filmID)
        guard !stock.dirCorrectedCurves.isEmpty &&
              stock.dirMatrix.count == 9 else {
            throw PhysicsError.invalid("缺失原版 DIR 化学数据：" + filmID)
        }
        let logMin = Double(stock.logExposure[0])
        let span = max(1e-5,
            Double(stock.logExposure[255]) - logMin
        )
        let spans = [Double](repeating: span, count: 3)
        let step = 1.0 / Double(size - 1)
        var rawMap = [Float]()
        var initialMap = [Float]()
        rawMap.reserveCapacity(size*size*size*4)
        initialMap.reserveCapacity(size*size*size*4)

        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rgb = [Double(r)*step, Double(g)*step,
                               Double(b)*step]
                    let linear = rgb.map { decodeSRGB(clamp($0)) }
                    let measuredRaw = response.raw(linearRGB: linear)
                    for channel in 0..<3 {
                        let logE = log10(max(1e-10, measuredRaw[channel])) +
                            exposureEV * 0.301029995664
                        rawMap.append(Float(clamp((logE-logMin)/span)))
                        let initial = stock.curve(logE, channel: channel)
                        initialMap.append(Float(
                            clamp(initial/pair.ranges[channel])
                        ))
                    }
                    rawMap.append(1)
                    initialMap.append(1)
                }
            }
        }

        // After subtracting spatially diffused inhibitors, apply the
        // *original* computed pre-DIR H-D characteristic (not an RGB curve).
        let correctedStep = 1.0 / Double(correctedSize-1)
        var developed = [Float]()
        developed.reserveCapacity(correctedSize*correctedSize*correctedSize*4)
        for b in 0..<correctedSize {
            for g in 0..<correctedSize {
                for r in 0..<correctedSize {
                    let normalized = [
                        Double(r)*correctedStep,
                        Double(g)*correctedStep,
                        Double(b)*correctedStep
                    ]
                    for channel in 0..<3 {
                        let logE = logMin + normalized[channel]*span
                        let opticalD = stock.curve(
                            logE, channel: channel, correctedBeforeDIR: true
                        )
                        developed.append(Float(
                            clamp(opticalD/pair.ranges[channel])
                        ))
                    }
                    developed.append(1)
                }
            }
        }
        func cube(_ values: [Float]) -> Data {
            values.withUnsafeBufferPointer { pointer in
                Data(bytes: pointer.baseAddress!,
                     count: pointer.count * MemoryLayout<Float>.size)
            }
        }
        return SpatialDIRStage(
            rawLogCube: cube(rawMap),
            initialDensityCube: cube(initialMap),
            correctedDensityCube: cube(developed),
            printCube: pair.printCube,
            sourceCubeSize: size,
            correctedCubeSize: correctedSize,
            densityRanges: pair.ranges,
            densityMaximum: stock.densityMaximum,
            logExposureSpans: spans,
            donorReceiverMatrix: stock.dirMatrix,
            positive: stock.polarity == "positive"
        )
    }

    /// Diagnostics: inspect the actual negative/reversal developed
    /// densities to compare CIColorCube source values against original maths.
    func developedFilmDensity(_ srgb: [Double], exposureEV: Double) -> [Double] {
        let linear = srgb.map { Self.decodeSRGB(Self.clamp($0)) }
        return Self.filmDensities(
            linear, film: film, hanatos: hanatos, exposureEV: exposureEV
        )
    }

    /// Encoded sRGB -> approximately measured negative and paper -> encoded sRGB.
    func render(_ srgb: [Double], exposureEV: Double, paperEV: Double) -> [Double] {
        let linear = srgb.map { Self.decodeSRGB(Self.clamp($0)) }
        let filmDensity = Self.filmDensities(
            linear, film: film, hanatos: hanatos, exposureEV: exposureEV
        )
        return scanFilmDensity(filmDensity, paperEV: paperEV)
    }

    /// After film development (and stochastic optical-density grain, if
    /// enabled), apply the original substrate-specific printing/scanning
    /// pipeline. A reversal film bypasses printing.
    func scanFilmDensity(_ filmDensity: [Double], paperEV: Double) -> [Double] {
        let resultDensity: [Double]
        let substrate: Profile
        if isPositive {
            resultDensity = filmDensity
            substrate = film
        } else {
            resultDensity = Self.paperDensities(
                filmDensity, film: film, paper: paper, weights: paperWeights,
                reference: printReference,
                printEV: paperEV + correctedPrintExposureEV,
                morph: printMorphCurve,
                preflashRaw: opticalPreflashRaw,
                opticalPrint: useOriginalPrintOptics
            )
            substrate = paper
        }
        if useOriginalScanner {
            var xyz = Self.scanPhysicalXYZ(
                densities: resultDensity, paper: substrate,
                weights: scanWeights, normalization: viewingNormalization
            )
            if useReferenceBlackWhite {
                xyz = OriginalScannerMath.correctBlackWhiteXYZ(
                    xyz,
                    yBlack: correctedReferenceBlack ?? scannedReferenceYBlack,
                    yWhite: correctedReferenceWhite ?? scannedReferenceYWhite
                )
            }
            let linear = OriginalScannerMath.linearSRGB(
                xyz: xyz, viewing: viewingStock
            )
            // Source default output option CAM16-UCS (64×720 Cmax +
            // Reinhard knees) is precomputed into a 33³ extended-gamut
            // table from the upstream Python implementation. Native
            // trilinear interpolation is an approximation between nodes.
            // ACES is the original source's supported alternative.
            let compressed = defaultCAM16Gamut
                ? OriginalCAM16Gamut.compress(linear)
                : OriginalScannerMath.compressACESRGC(linear)
            return compressed.map {
                OriginalScannerMath.encodeSRGB(Self.clamp($0))
            }
        }
        let linOutput = Self.scanLinear(
            resultDensity, paper: substrate,
            weights: scanWeights, mediaWhite: mediaWhiteXYZ
        )
        // This display neutralisation is the existing mobile approximation,
        // not the full original Python scanning/colour-reference module.
        return (0..<3).map { ch in
            let balanced = linOutput[ch] * (0.184 / neutralOutputRGB[ch])
            return Self.encodeSRGB(Self.clamp(balanced))
        }
    }

    /// Stage-level numerical probe for a source positive-film scan.
    /// This runs the same native functions as scanFilmDensity and does not
    /// change the production image-rendering path or enable approximation.
    struct DirectPositiveScannerStages {
        let xyz: [Double]
        let linear: [Double]
        let compressed: [Double]
        let encoded: [Double]
    }

    func directPositiveScannerStages(
        _ filmDensity: [Double]
    ) throws -> DirectPositiveScannerStages {
        guard isPositive, useOriginalScanner, !useReferenceBlackWhite,
              !defaultCAM16Gamut, filmDensity.count == 3,
              filmDensity.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid(
                "原版 RGB 分段诊断仅支持正片直扫、关闭黑白校准、源 ACES RGC")
        }
        let xyz = Self.scanPhysicalXYZ(
            densities: filmDensity, paper: film,
            weights: scanWeights, normalization: viewingNormalization
        )
        let linear = OriginalScannerMath.linearSRGB(
            xyz: xyz, viewing: viewingStock
        )
        let compressed = OriginalScannerMath.compressACESRGC(linear)
        let encoded = compressed.map {
            OriginalScannerMath.encodeSRGB(Self.clamp($0))
        }
        guard (xyz + linear + compressed + encoded)
            .allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版扫描 RGB 分段诊断产生非有限数值")
        }
        return DirectPositiveScannerStages(
            xyz: xyz, linear: linear, compressed: compressed,
            encoded: encoded
        )
    }

    /// Diagnostic source references, independent of any image output.
    func originalPrintCalibration() -> (yBlack:Double,yWhite:Double,ev:Double)? {
        guard let b=correctedReferenceBlack,
              let w=correctedReferenceWhite else { return nil }
        return (b,w,correctedPrintExposureEV)
    }

    func originalPrintMorphDelta(logExposure: Double, channel: Int) -> Double {
        printMorphCurve?.densityDelta(logExposure,channel:channel) ?? 0
    }

    /// Original DIR nonspatial inhibition chemistry from
    /// model/couplers.py with film-specific params_builder presets.
    /// Spatial diffusion is disabled while baking the color cube,
    /// exactly as source debug.lut_mode requires.
    private static func developLogExposure(
        _ logRaw: [Double], film: Profile, applyDIR: Bool
    ) -> [Double] {
        let densityInitial = (0..<3).map { ch in
            film.curve(logRaw[ch], channel: ch)
        }
        guard applyDIR, !film.dirCorrectedCurves.isEmpty else {
            return densityInitial
        }

        // Original: silver = d_max - density for reversal, else density.
        let silver = (0..<3).map { donor -> Double in
            film.polarity == "positive"
                ? film.densityMaximum[donor] - densityInitial[donor]
                : densityInitial[donor]
        }
        // Original np.einsum('ijk,km->ijm'): donor rows, receiver cols.
        let logCorrected = (0..<3).map { receiver -> Double in
            let inhibitor = (0..<3).reduce(0.0) { total, donor in
                total + silver[donor] *
                    film.dirMatrix[donor * 3 + receiver]
            }
            return logRaw[receiver] - inhibitor
        }
        return (0..<3).map { channel in
            film.curve(
                logCorrected[channel],
                channel: channel, correctedBeforeDIR: true
            )
        }
    }

    /// Unit-test access to film chemistry independently of RGB/scan math.
    func dirDevelopedDensity(logRaw: [Double]) -> [Double] {
        guard logRaw.count == 3 else { return [] }
        return Self.developLogExposure(logRaw, film: film, applyDIR: true)
    }

    private static func filmDensities(_ linear: [Double],
                                      film: Profile,
                                      hanatos: OriginalHanatosResponse,
                                      exposureEV: Double,
                                      applyDIR: Bool = true) -> [Double] {
        let raw = hanatos.raw(linearRGB: linear)
        let logRaw = (0..<3).map { ch in
            log10(max(1e-10, raw[ch])) + exposureEV * 0.301029995664
        }
        return developLogExposure(logRaw, film: film, applyDIR: applyDIR)
    }

    private static func printRaw(filmDensities: [Double], film: Profile,
                                 weights: [[Double]],
                                 clampDensity: Bool = true) -> [Double] {
        var raw = [0.0, 0.0, 0.0]
        for i in 0..<81 {
            var spectralDensity = film.base(i)
            for c in 0..<3 {
                spectralDensity += film.dyeAbsorbance(i, c) * filmDensities[c]
            }
            let adjustedDensity = clampDensity ? max(0, spectralDensity) : spectralDensity
            let transmission = pow(10.0, -adjustedDensity)
            for c in 0..<3 { raw[c] += weights[i][c] * transmission }
        }
        return raw
    }

    private static func paperDensities(_ filmDensities: [Double], film: Profile,
                                       paper: Profile, weights: [[Double]],
                                       reference: Double, printEV: Double,
                                       morph: OriginalPrintMorph.PreparedCurve? = nil,
                                       preflashRaw: [Double] = [0, 0, 0],
                                       opticalPrint: Bool = false
    ) -> [Double] {
        let raw = printRaw(
            filmDensities: filmDensities, film: film, weights: weights,
            clampDensity: !opticalPrint
        )
        let originalExposure = opticalPrint
            ? OriginalPrintOptics.paperLogExposure(
                raw: raw, reference: reference, preflash: preflashRaw,
                printEV: printEV
              ) : []
        return (0..<3).map { c in
            let logE = opticalPrint ? originalExposure[c]
                : log10(max(1e-14, raw[c]) / reference) +
                    printEV * 0.301029995664
            let measured = paper.curve(logE, channel: c)
            guard let morph else { return measured }
            // Apply the ORIGINAL s023 CDF morphology delta on top of
            // previously verified measured H-D response. The source
            // fitted CDF baseline is not bit-identical to the measured
            // 256 sample curve, so delta is needed for zero-effect parity.
            let maximum = (0..<256).map {
                Double(paper.densityCurves[$0*3+c])
            }.max() ?? paper.minimumDensity[c]
            let limit = max(0,maximum-paper.minimumDensity[c])
            return max(0,min(limit,measured +
                morph.densityDelta(logE,channel:c)))
        }
    }

    /// Source _return_callable_cmy_to_log_xyz exact spectral sum:
    /// sum_wl(viewing * CIE1931 * 10^(-film dye density)) /
    /// sum_wl(viewing * CIE1931 Ybar), before output color transforms.
    private static func scanPhysicalXYZ(
        densities: [Double], paper: Profile, weights: [[Double]],
        normalization: Double
    ) -> [Double] {
        var xyz = [0.0, 0.0, 0.0]
        for wl in 0..<81 {
            var density = paper.base(wl)
            for channel in 0..<3 {
                density += paper.dyeAbsorbance(wl,channel)*densities[channel]
            }
            let transmitted = pow(10.0,-density)
            for channel in 0..<3 {
                xyz[channel] += transmitted*weights[wl][channel]
            }
        }
        let safe = max(1e-12,normalization)
        return xyz.map { max(0,$0/safe) }
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
