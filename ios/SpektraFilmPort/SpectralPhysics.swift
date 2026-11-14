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
    // Original runtime SettingsParams.rgb_to_raw_method choices.
    // Default source Hanatos LUT is unchanged; Mallett operates directly
    // on measured film Float64 spectral sensitivities.
    enum CameraRawMethod: String, CaseIterable, Hashable {
        case hanatos2025 = "hanatos2025"
        case mallett2019 = "mallett2019"

        var displayName: String {
            switch self {
            case .hanatos2025: return "Hanatos 2025（默认）"
            case .mallett2019: return "Mallett 2019（光谱积分）"
            }
        }
    }

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
        let baseDensity: [Float]          // 81; absent entries packed as zero
        let scannerWavelengthValid: [Bool] // 81 dye/base scanner validity
        let baseWavelengthValid: [Bool]    // 81 base-only preflash validity
        let sensitivitySampleValid: [Bool] // 243 paper sensitivity validity
        let logExposure: [Float]          // 256
        let densityCurves: [Float]        // 256 x 3, exposure-major
        let densityCurvesLayers: [Float]  // 256 x 3 layers x 3 CMY
        let minimumDensity: [Double]    // upstream nanmin per colour channel
        let dirCorrectedCurves: [Float]  // upstream pre-DIR normalized H-D
        let dirMatrix: [Double]          // donor (row) -> receiver (column)
        let densityMaximum: [Double]
        // Source mode keeps the ORIGINAL upstream JSON Float64 bits. These
        // buffers are absent in mobile fast mode (which remains unchanged).
        let sourceLogSensitivityF64: [Double]?
        let sourceChannelDensityF64: [Double]?
        let sourceBaseDensityF64: [Double]?
        let sourceLogExposureF64: [Double]?
        let sourceDensityCurvesF64: [Double]?
        let sourceDensityCurvesLayersF64: [Double]?
        let sourceCorrectedCurvesF64: [Double]?
        let polarity: String
        let referenceIlluminant: String
        let viewingIlluminant: String
        let id: String

        init(id: String, sourceMeasuredFloat64: Bool = false) throws {
            guard let record = GeneratedSpectralData.profiles[id] else {
                throw PhysicsError.invalid("没有该胶片／相纸的实测曲线：" + id)
            }
            self.id = id
            logSensitivity = try Self.decode(record.logSensitivity, count: 243)
            channelDensity = try Self.decode(record.channelDensity, count: 243)
            baseDensity = try Self.decode(record.baseDensity, count: 81)
            guard let valid = Data(base64Encoded: record.scannerValidWavelengths),
                  valid.count == 81,
                  valid.allSatisfy({ $0 == 0 || $0 == 1 }),
                  valid.contains(1) else {
                throw PhysicsError.invalid("原版扫描缺失波长标记无效：" + id)
            }
            scannerWavelengthValid = valid.map { $0 == 1 }
            guard let baseMask = Data(base64Encoded: record.baseValidWavelengths),
                  baseMask.count == 81,
                  baseMask.allSatisfy({ $0 == 0 || $0 == 1 }),
                  baseMask.contains(1) else {
                throw PhysicsError.invalid("原版片基光谱缺失值掩码无效：" + id)
            }
            baseWavelengthValid = baseMask.map { $0 == 1 }
            guard let sensitivityMask = Data(base64Encoded: record.sensitivityValidSamples),
                  sensitivityMask.count == 243,
                  sensitivityMask.allSatisfy({ $0 == 0 || $0 == 1 }),
                  sensitivityMask.contains(1) else {
                throw PhysicsError.invalid("原版感光度光谱缺失值掩码无效：" + id)
            }
            sensitivitySampleValid = sensitivityMask.map { $0 == 1 }
            logExposure = try Self.decode(record.logExposure, count: 256)
            densityCurves = try Self.decode(record.densityCurves, count: 768)
            densityCurvesLayers = record.densityCurvesLayers.isEmpty
                ? [] : try Self.decode(record.densityCurvesLayers, count: 2304)
            sourceLogSensitivityF64 = try Self.decodeOptionalSource(
                record.sourceLogSensitivityF64, count:243,
                enabled:sourceMeasuredFloat64
            )
            sourceChannelDensityF64 = try Self.decodeOptionalSource(
                record.sourceChannelDensityF64, count:243,
                enabled:sourceMeasuredFloat64
            )
            sourceBaseDensityF64 = try Self.decodeOptionalSource(
                record.sourceBaseDensityF64, count:81,
                enabled:sourceMeasuredFloat64
            )
            sourceLogExposureF64 = try Self.decodeOptionalSource(
                record.sourceLogExposureF64, count:256,
                enabled:sourceMeasuredFloat64
            )
            sourceDensityCurvesF64 = try Self.decodeOptionalSource(
                record.sourceDensityCurvesF64, count:768,
                enabled:sourceMeasuredFloat64
            )
            sourceDensityCurvesLayersF64 = try Self.decodeOptionalSource(
                record.sourceDensityCurvesLayersF64, count:2304,
                enabled:sourceMeasuredFloat64, allowEmpty:true
            )
            if let dir = GeneratedDIRData.records[id] {
                dirCorrectedCurves = try Self.decode(dir.correctedCurves, count: 768)
                sourceCorrectedCurvesF64 = try Self.decodeOptionalSource(
                    dir.sourceCorrectedCurvesF64, count:768,
                    enabled:sourceMeasuredFloat64
                )
                dirMatrix = dir.donorReceiverMatrix
                densityMaximum = dir.sourceDensityMax
            } else {
                // Print media do not use negative-film DIR inhibition.
                dirCorrectedCurves = []
                sourceCorrectedCurvesF64 = nil
                dirMatrix = Array(repeating: 0.0, count: 9)
                densityMaximum = Array(repeating: 0.0, count: 3)
            }
            polarity = record.polarity
            referenceIlluminant = record.referenceIlluminant
            viewingIlluminant = record.viewingIlluminant
            guard logExposure[0] < logExposure[255] else {
                throw PhysicsError.invalid("光谱数据的曝光曲线无效：" + id)
            }
            // spektrafilm.model.develop.develop() subtracts the full channel
            // minimum (not just densityCurves[0]) before interpolating.
            // Use explicit scalar loops: the Swift 5.9 type checker cannot
            // reliably infer nested Optional<Double> / Float / map.min()
            // over the 256-node source optical density curves. These loops
            // preserve the same per-channel minima in source Float64.
            var materialMinima = [Double](repeating: 0, count: 3)
            for channel in 0..<3 {
                var channelMin = Double.infinity
                for node in 0..<256 {
                    let index = node * 3 + channel
                    let measured: Double
                    if let exact = sourceDensityCurvesF64 {
                        measured = exact[index]
                    } else {
                        measured = Double(densityCurves[index])
                    }
                    if measured < channelMin { channelMin = measured }
                }
                guard channelMin.isFinite else {
                    throw PhysicsError.invalid("原版 H-D 密度最小值无效：" + id)
                }
                materialMinima[channel] = channelMin
            }
            minimumDensity = materialMinima
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

        /// Decode raw original JSON number binary64, never Float32-round
        /// first. The separate mobile arrays remain bit-for-bit unchanged.
        private static func decodeOptionalSource(
            _ string:String, count:Int, enabled:Bool,
            allowEmpty:Bool = false
        ) throws -> [Double]? {
            guard enabled else { return nil }
            if string.isEmpty && allowEmpty { return nil }
            guard let bytes=Data(base64Encoded:string),
                  bytes.count == count * MemoryLayout<Double>.size else {
                throw PhysicsError.invalid(
                    "原版 Float64 实测光谱或 H-D 缺失，禁止精确模式降级"
                )
            }
            return bytes.withUnsafeBytes { raw in
                (0..<count).map { i in
                    let offset=i*8
                    let value=raw.loadUnaligned(
                        fromByteOffset:offset,as:UInt64.self
                    )
                    return Double(bitPattern:UInt64(littleEndian:value))
                }
            }
        }

        var sourceExposureAxis: [Double] {
            sourceLogExposureF64 ?? logExposure.map(Double.init)
        }

        func densityAt(_ index:Int) -> Double {
            sourceDensityCurvesF64?[index] ?? Double(densityCurves[index])
        }

        func layerAt(_ index:Int) -> Double {
            sourceDensityCurvesLayersF64?[index] ??
                Double(densityCurvesLayers[index])
        }

        func curve(_ logE: Double, channel: Int,
                   correctedBeforeDIR: Bool = false) -> Double {
            let first = sourceLogExposureF64?[0] ?? Double(logExposure[0])
            let last = sourceLogExposureF64?[255] ?? Double(logExposure[255])
            let useCorrected = correctedBeforeDIR && !dirCorrectedCurves.isEmpty
            let curves = useCorrected ? dirCorrectedCurves : densityCurves
            let precise = useCorrected
                ? sourceCorrectedCurvesF64 : sourceDensityCurvesF64
            let minDensity = useCorrected ? 0 : minimumDensity[channel]
            func sample(_ index:Int) -> Double {
                precise?[index] ?? Double(curves[index])
            }
            if logE <= first {
                return max(0, sample(channel) - minDensity)
            }
            if logE >= last {
                return max(0, sample(255 * 3 + channel) - minDensity)
            }
            // Source fast_interp.py (Numba) does NOT assume uniformly
            // spaced bins: upper_bound side='right' on the ORIGINAL
            // binary64 exposure axis, then multiply by 1/dx before
            // mixing y0 + t*(y1-y0). Preserve repeated-node semantics.
            if let axis=sourceLogExposureF64 {
                var lo=0
                var hi=256
                while lo<hi {
                    let mid=(lo+hi)/2
                    if logE < axis[mid] { hi=mid }
                    else { lo=mid+1 }
                }
                let lower=lo-1
                let dx=axis[lo]-axis[lower]
                let invDx=dx == 0 ? 0.0 : 1.0/dx
                let t=(logE-axis[lower])*invDx
                let y0=sample(lower*3+channel)
                let y1=sample(lo*3+channel)
                return max(0,y0+t*(y1-y0)-minDensity)
            }
            // Unchanged v1.8.24 mobile fast Float32-uniform-LUT pathway.
            let u = (logE - first) / (last - first) * 255
            let index = min(254, max(0, Int(floor(u))))
            let weight = min(1, max(0, u - Double(index)))
            let y0 = sample(index * 3 + channel)
            let y1 = sample((index + 1) * 3 + channel)
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
                (densityAt(index * 3 + channel) -
                 minimumDensity[channel]) * sign
            }
            func value(_ index: Int) -> Double {
                layerAt(index * 9 + sublayer * 3 + channel)
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
                    max(maximum, layerAt(i*9+k))
                }
            }
        }

        func sensitivity(_ wavelengthIndex: Int, _ ch: Int) -> Double {
            // Original printing.py uses np.nan_to_num(10**log_sensitivity),
            // turning unavailable paper-sensitive bands into ZERO response.
            let sample = wavelengthIndex * 3 + ch
            guard sensitivitySampleValid[sample] else { return 0.0 }
            let logS=sourceLogSensitivityF64?[sample] ??
                Double(logSensitivity[sample])
            return pow(10.0, logS)
        }

        func dyeAbsorbance(_ wavelengthIndex: Int, _ ch: Int) -> Double {
            sourceChannelDensityF64?[wavelengthIndex * 3 + ch] ??
                Double(channelDensity[wavelengthIndex * 3 + ch])
        }

        func base(_ wavelengthIndex: Int) -> Double {
            sourceBaseDensityF64?[wavelengthIndex] ??
                Double(baseDensity[wavelengthIndex])
        }
    }

    private let film: Profile
    private let paper: Profile
    private let isPositive: Bool
    private let hanatos: OriginalHanatosResponse
    private let cameraRawMethod: CameraRawMethod
    private let filmMatrix: [[Double]]    // film channel -> source linear RGB
    // Exact upstream colour.RGB_to_RGB(sRGB→sRGB) row-transform,
    // retained even for nominal identity to avoid 5e-5 source mismatch.
    private let mallettSRGBConversion: [Double]
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
    private let sourcePaperHDCurve: OriginalPrintMorph.SourceCurve?
    private var correctedPrintExposureEV = 0.0
    private var correctedReferenceBlack: Double?
    private var correctedReferenceWhite: Double?
    private let defaultCAM16Gamut: Bool
    private let viewingStock: String
    private let viewingNormalization: Double
    // Python scanning.py illuminant XYZ; separate from medium white density.
    private let scannerIlluminantXYZ: [Double]
    private let scannedReferenceYBlack: Double
    private let scannedReferenceYWhite: Double

    /// CI-only numeric probe of the exact same source Float64 H-D Profile.curve
    /// used in the production physical image engine. The reference values are
    /// independently generated by upstream Python fast_interp.
    static func sourceHDInterpolationProbe(
        filmID:String, exposures:[Double], correctedBeforeDIR:Bool
    ) throws -> [Double] {
        guard supportedFilmIDs.contains(filmID),
              !exposures.isEmpty,
              exposures.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("Invalid original H-D source probe input")
        }
        let profile=try Profile(id:filmID,sourceMeasuredFloat64:true)
        var result=[Double]()
        result.reserveCapacity(exposures.count*3)
        for exposure in exposures {
            for channel in 0..<3 {
                result.append(profile.curve(
                    exposure,channel:channel,
                    correctedBeforeDIR:correctedBeforeDIR
                ))
            }
        }
        return result
    }

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
         cameraExposureEV: Double = 0,
         hanatosPrecision: OriginalHanatosResponse.Precision = .originalFloat64,
         sourceMeasuredFloat64: Bool = false,
         cameraRawMethod: CameraRawMethod = .hanatos2025,
         cameraBandpass: OriginalSourceCameraBandpass.Settings = .init()) throws {
        guard Self.supportedFilmIDs.contains(filmID),
              Self.supportedPaperIDs.contains(paperID) else {
            throw PhysicsError.invalid("该胶片／相纸组合尚未接入光谱计算")
        }
        let originalFilm = try Profile(
            id:filmID,sourceMeasuredFloat64:sourceMeasuredFloat64
        )
        let originalPaper = try Profile(
            id:paperID,sourceMeasuredFloat64:sourceMeasuredFloat64
        )
        try cameraBandpass.validate()
        guard !cameraBandpass.active || cameraRawMethod == .mallett2019 else {
            throw PhysicsError.invalid(
                "原版 Hanatos 光谱 TC LUT 尚未按 UV/IR 滤镜重新生成；" +
                "请选择 Mallett 2019 光谱积分，禁止忽略所选滤镜"
            )
        }
        let originalHanatos = try OriginalHanatosResponse(
            filmID: filmID, precision: hanatosPrecision
        )
        let positive = originalFilm.polarity == "positive"
        guard !printOptics.enabled || printOptics.isValid else {
            throw PhysicsError.invalid("原版印相滤色或预闪光参数超出范围")
        }
        useOriginalPrintOptics = !positive && printOptics.enabled
        let viewed = positive ? originalFilm : originalPaper
        film = originalFilm
        paper = originalPaper
        hanatos = originalHanatos
        self.cameraRawMethod = cameraRawMethod
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
        if useOriginalPrintOptics {
            guard let source = OriginalPrintMorph.prepareSource(
                stock:paperID,logExposure:originalPaper.sourceExposureAxis,
                settings:printMorph,
                positive:originalPaper.polarity == "positive"
            ) else {
                throw PhysicsError.invalid("原版相纸 H-D 三层 CDF 曲线缺失或无效")
            }
            sourcePaperHDCurve = source
        } else {
            sourcePaperHDCurve = nil
        }

        let basis = try Self.readOriginalOptics(
            fast:GeneratedOriginalOptics.mallettBasis,
            source:GeneratedOriginalOptics.sourceF64_mallettBasis,
            count:81*3, original:sourceMeasuredFloat64
        )
        mallettSRGBConversion = try Self.readOriginalOptics(
            fast:GeneratedOriginalOptics.mallettSRGBConversion,
            source:GeneratedOriginalOptics.sourceF64_mallettSRGBConversion,
            count:9, original:sourceMeasuredFloat64
        )
        // Python FilmingStage reads EACH film's reference illuminant.
        // Tungsten stock "T" is the measured Incandescent source,
        // not D55. Never silently relight tungsten cinema film as daylight.
        let sourceIlluminantName = originalFilm.referenceIlluminant
        guard sourceIlluminantName == "D55" ||
              sourceIlluminantName == "T" else {
            throw PhysicsError.invalid(
                "Mallett 原版相机参考光源暂不支持：" + sourceIlluminantName
            )
        }
        let mallettIlluminant = try Self.readOriginalOptics(
            fast: sourceIlluminantName == "T" ?
                GeneratedOriginalOptics.t : GeneratedOriginalOptics.d55,
            source: sourceIlluminantName == "T" ?
                GeneratedOriginalOptics.sourceF64_t :
                GeneratedOriginalOptics.sourceF64_d55,
            count:81, original:sourceMeasuredFloat64
        )
        let stock = viewed.viewingIlluminant == "K75P" ? "K75P" : "D50"
        let viewing = try Self.readOriginalOptics(
            fast:stock == "K75P" ?
                GeneratedOriginalOptics.k75p : GeneratedOriginalOptics.d50,
            source:stock == "K75P" ?
                GeneratedOriginalOptics.sourceF64_k75p :
                GeneratedOriginalOptics.sourceF64_d50,
            count:81,original:sourceMeasuredFloat64
        )
        viewingStock = stock
        viewingNormalization = GeneratedScannerReference.xyzYNormalization[stock] ?? 1
        let cie = try Self.readOriginalOptics(
            fast:GeneratedOriginalOptics.cie1931,
            source:GeneratedOriginalOptics.sourceF64_cie1931,
            count:81*3,original:sourceMeasuredFloat64
        )
        // Source ScanningStage computes illuminant XYZ from ALL 81 CMFs
        // (not the dye-mask-limited transmission weights). This XYZ is
        // added to the developed *paper* scan BEFORE XYZ→linear sRGB.
        let scanNorm = GeneratedScannerReference.xyzYNormalization[stock] ?? 1
        guard scanNorm.isFinite, scanNorm > 1e-15 else {
            throw PhysicsError.invalid("原版扫描器光源 Y 归一化无效")
        }
        var scanIlluminant = [Double](repeating:0,count:3)
        for i in 0..<81 {
            for ch in 0..<3 {
                scanIlluminant[ch] += viewing[i] * cie[i*3+ch]
            }
        }
        let sourceScannerLampXYZ = scanIlluminant.map { $0 / scanNorm }
        guard sourceScannerLampXYZ.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版扫描器光源 XYZ 包含 NaN/Inf")
        }
        scannerIlluminantXYZ = sourceScannerLampXYZ
        // Original print balance database selects filter CC values per
        // film + printing-stock pair; do not reuse one neutral spectrum.
        let printKey = filmID + "|" + paperID
        let sourceIlluminant = sourceMeasuredFloat64
            ? (GeneratedOriginalOptics.sourceF64PrintIlluminantByPair[printKey]
               ?? GeneratedOriginalOptics.sourceF64_enlargerNeutral)
            : (GeneratedOriginalOptics.printIlluminantByPair[printKey]
               ?? GeneratedOriginalOptics.enlargerNeutral)
        let opticalLighting: OriginalPrintOptics.Prepared?
        if useOriginalPrintOptics {
            // Upstream standard_illuminant("TH-KG3-L") applies the
            // original measured Canon 24mm lens transmission to the
            // 3400K+Schott KG3 lamp before illuminant normalization.
            // The neutral-print database is keyed by illuminant name;
            // TH-KG3-L does not reuse TH-KG3 stock-specific CC values.
            let useLensLight = printOptics.illuminant == .thKG3L
            let unfiltered = try Self.readOriginalOptics(
                fast:useLensLight ?
                    GeneratedOriginalOptics.enlargerSourceLens :
                    GeneratedOriginalOptics.enlargerSource,
                source:useLensLight ?
                    GeneratedOriginalOptics.sourceF64_enlargerSourceLens :
                    GeneratedOriginalOptics.sourceF64_enlargerSource,
                count:81,original:sourceMeasuredFloat64
            )
            let mediaSensitivities = (0..<81).map { index in
                (0..<3).map { originalPaper.sensitivity(index, $0) }
            }
            opticalLighting = OriginalPrintOptics.prepare(
                source: unfiltered,
                neutralCC: useLensLight ? [0, 65, 55] :
                    (GeneratedOriginalOptics.neutralCMYByPair[printKey]
                     ?? [0, 65, 55]),
                settings: printOptics,
                filmBase: (0..<81).map { originalFilm.base($0) },
                filmBaseValid: originalFilm.baseWavelengthValid,
                paperSensitivity: mediaSensitivities
            )
        } else {
            opticalLighting = nil
        }
        opticalPreflashRaw = opticalLighting?.preflashRaw ?? [0, 0, 0]
        let enlarger = try opticalLighting?.printIlluminant ??
            (sourceMeasuredFloat64
                ? Self.readOriginalFloat64(sourceIlluminant,count:81)
                : Self.readOriginalFloat32(sourceIlluminant,count:81))
        var matrix = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var pWeights = Array(repeating: Array(repeating: 0.0, count: 3), count: 81)
        var xyzWeights = Array(repeating: Array(repeating: 0.0, count: 3), count: 81)
        var white = Array(repeating: 0.0, count: 3)

        // Original model.color_filters.compute_band_pass_filter:
        // each wavelength gets an independent UV/IR erf transmission.
        // Original FilmingStage normalizes S[wl,ch] separately for each
        // emulsion against the stock-specific viewing reference light.
        let bandpass = (0..<81).map { index in
            OriginalSourceCameraBandpass.transmission(
                wavelengthNM: Double(380 + index * 5),
                settings: cameraBandpass
            )
        }
        var bandpassNormalization = [Double](repeating:1.0,count:3)
        if cameraBandpass.active {
            for ch in 0..<3 {
                var originalSum = 0.0
                var filteredSum = 0.0
                for index in 0..<81 {
                    let exposure = originalFilm.sensitivity(index,ch) *
                        mallettIlluminant[index]
                    originalSum += exposure
                    filteredSum += exposure * bandpass[index]
                }
                guard originalSum > 1e-12, filteredSum > 1e-12,
                      originalSum.isFinite, filteredSum.isFinite else {
                    throw PhysicsError.invalid(
                        "原版相机 UV/IR 逐通道曝光归一化失败：" + filmID
                    )
                }
                bandpassNormalization[ch] = filteredSum / originalSum
            }
        }
        // Exact source rgb_to_raw_mallett2019 einsum and green-midgray
        // denominator, with optional source bandpass-normalized sensitivity.
        var midgrayGreen = 0.0
        for i in 0..<81 {
            let light = mallettIlluminant[i]
            for ch in 0..<3 {
                let sensitivity = originalFilm.sensitivity(i,ch) *
                    bandpass[i] / bandpassNormalization[ch]
                if ch == 1 { midgrayGreen += light * 0.184 * sensitivity }
                for rgb in 0..<3 {
                    matrix[ch][rgb] += basis[i*3+rgb] * light * sensitivity
                }
                pWeights[i][ch] = enlarger[i] *
                    originalPaper.sensitivity(i,ch)
            }
            // Original scanning density-to-light and spectral integration
            // uses the 1931 2-degree CMFs and D50 viewing illumination.
            // Original Python density_to_light: any NaN dye/base channel
            // means ZERO light for the entire wavelength, not 0 absorption.
            if viewed.scannerWavelengthValid[i] {
                for ch in 0..<3 {
                    xyzWeights[i][ch] = viewing[i] * cie[i * 3 + ch]
                    white[ch] += xyzWeights[i][ch] *
                        pow(10.0, -viewed.base(i))
                }
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
                opticalPrint: useOriginalPrintOptics,
                sourceHD: sourcePaperHDCurve
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
                opticalPrint: useOriginalPrintOptics,
                sourceHD: sourcePaperHDCurve
            )
            let paperWhite = Self.paperDensities(
                filmWhite, film: originalFilm, paper: originalPaper,
                weights: pWeights, reference: printReference, printEV: 0,
                preflashRaw: opticalPreflashRaw,
                opticalPrint: useOriginalPrintOptics,
                sourceHD: sourcePaperHDCurve
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
                             printOptics: OriginalPrintOptics.Settings = .init(),
        hanatosPrecision: OriginalHanatosResponse.Precision = .originalFloat64
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
            cameraExposureEV: exposureEV,
            hanatosPrecision: hanatosPrecision
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
        let printFloat64Nodes: [Double]  // original Double results before CI packing
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
        printOptics: OriginalPrintOptics.Settings = .init(),
        hanatosPrecision: OriginalHanatosResponse.Precision = .originalFloat64
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
            cameraExposureEV: exposureEV,
            hanatosPrecision: hanatosPrecision
        )
        let ranges = engine.film.densityMaximum.map { max(0.25, $0 + 0.25) }
        let layerMaxima = engine.film.sublayerMaxima
        let step = 1.0 / Double(size-1)
        var input = [Float]()
        var printMap = [Float]()
        var printMapDouble = [Double]()
        var sublayerMaps = [[Float]](
            repeating: [], count: 3
        )
        input.reserveCapacity(size*size*size*4)
        printMap.reserveCapacity(size*size*size*4)
        printMapDouble.reserveCapacity(size*size*size*4)
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
                    printMapDouble.append(contentsOf: finalRGB + [1.0])
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
            inputCube: cubeA, printCube: cubeB,
            printFloat64Nodes: printMapDouble,
            ranges: ranges, size: size,
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
        printOptics: OriginalPrintOptics.Settings = .init(),
        hanatosPrecision: OriginalHanatosResponse.Precision = .originalFloat64
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
            printMorph: printMorph, printOptics: printOptics,
            hanatosPrecision: hanatosPrecision
        )
        let stock = try Profile(id: filmID)
        let response = try OriginalHanatosResponse(
            filmID: filmID, precision: hanatosPrecision
        )
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
        var rawMapDouble = [Double]()
        var initialMapDouble = [Double]()
        rawMap.reserveCapacity(size*size*size*4)
        initialMap.reserveCapacity(size*size*size*4)
        rawMapDouble.reserveCapacity(size*size*size*4)
        initialMapDouble.reserveCapacity(size*size*size*4)

        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rgb = [Double(r)*step, Double(g)*step,
                               Double(b)*step]
                    let linear = rgb.map { decodeSRGB(clamp($0)) }
                    let measuredRaw = response.raw(linearRGB: linear)
                    let sourceLog=filmLogExposure(
                        raw:measuredRaw,exposureEV:exposureEV
                    )
                    for channel in 0..<3 {
                        let logE=sourceLog[channel]
                        let rawValue = clamp((logE-logMin)/span)
                        rawMapDouble.append(rawValue)
                        rawMap.append(Float(rawValue))
                        let initial = stock.curve(logE, channel: channel)
                        let initialValue = clamp(initial/pair.ranges[channel])
                        initialMapDouble.append(initialValue)
                        initialMap.append(Float(initialValue))
                    }
                    rawMap.append(1)
                    initialMap.append(1)
                    rawMapDouble.append(1)
                    initialMapDouble.append(1)
                }
            }
        }

        // After subtracting spatially diffused inhibitors, apply the
        // *original* computed pre-DIR H-D characteristic (not an RGB curve).
        let correctedStep = 1.0 / Double(correctedSize-1)
        var developed = [Float]()
        var developedDouble = [Double]()
        developed.reserveCapacity(correctedSize*correctedSize*correctedSize*4)
        developedDouble.reserveCapacity(correctedSize*correctedSize*correctedSize*4)
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
                        let value = clamp(opticalD/pair.ranges[channel])
                        developedDouble.append(value)
                        developed.append(Float(value))
                    }
                    developed.append(1)
                    developedDouble.append(1)
                }
            }
        }
        func cube(_ values: [Float]) -> Data {
            values.withUnsafeBufferPointer { pointer in
                Data(bytes: pointer.baseAddress!,
                     count: pointer.count * MemoryLayout<Float>.size)
            }
        }
        var stage = SpatialDIRStage(
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
        stage.float64OpticalNodes = .init(
            raw: rawMapDouble, initial: initialMapDouble,
            corrected: developedDouble, printed: pair.printFloat64Nodes
        )
        guard stage.valid else {
            throw PhysicsError.invalid("原版 Float64 光学 LUT 生成失败／出现非有限数")
        }
        return stage
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
    func scanFilmDensity(_ filmDensity: [Double], paperEV: Double,
                         sourceLinearOutput: Bool = false,
                         sourceXYZOutput: Bool = false) -> [Double] {
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
                opticalPrint: useOriginalPrintOptics,
                sourceHD: sourcePaperHDCurve
            )
            substrate = paper
        }
        return scanDevelopedSubstrateDensity(
            resultDensity, substrate:substrate,
            sourceLinearOutput:sourceLinearOutput,
            sourceXYZOutput:sourceXYZOutput
        )
    }

    /// Source-optical print and existing film/print scanning share EXACT
    /// same calculation, avoiding a duplicated CAM16/ACES/XYZ path.
    private func scanDevelopedSubstrateDensity(
        _ resultDensity:[Double],substrate:Profile,
        sourceLinearOutput:Bool=false,
        sourceXYZOutput:Bool=false
    ) -> [Double] {
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
            // In the opt-in controlled scanner glare production path the
            // entire 2D paper XYZ image is assembled first, then the true
            // source field is added before any RGB/gamut conversion.
            if sourceXYZOutput { return xyz }
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
            // Original ScanningStage applies lens blur/unsharp to this
            // LINEAR RGB, and encodes CCTF only after the full-frame filter.
            // All existing call sites preserve their exact old encoding.
            if sourceLinearOutput { return compressed }
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

    // v1.8.22: new source-ordered WHOLE-IMAGE engine. These real optical
    // functions are called at EACH pixel; no 3D colour cube exists between
    // Hanatos, measured H-D and paper/scanner spectra. This fixes the
    // nonlinear interpolation gap left in the v1.8.21 optical LUT nodes.
    // The underlying measured profile remains Float32-packed and its
    // quantization is still explicitly NOT original source Float64.
    struct SourceSpatialFilmParams {
        let matrix: [Double]
        let densityMaximum: [Double]
        let positive: Bool
    }

    /// Upstream grain.py layer inversion uses the SAME measured 256×3×3
    /// Float64 original film curves as the H-D development engine.
    /// Distinct from the old approximate 3D colour-cube grain inputs.
    func sourceSpatialGrainLayers() throws -> OriginalSourcePhysicalGrain.MeasuredLayers {
        let maxima=film.sublayerMaxima
        guard useOriginalScanner,sourceMeasuredFloat64,
              film.sourceDensityCurvesLayersF64 != nil,
              film.sourceDensityCurvesF64 != nil,
              film.sourceLogExposureF64 != nil,
              maxima.count==9,
              maxima.allSatisfy({$0.isFinite && $0>0}) else {
            throw PhysicsError.invalid(
                "原版三亚层颗粒需要完整 Float64 原始实测密度曲线，禁止使用 Float32 LUT"
            )
        }
        let profile=film
        return OriginalSourcePhysicalGrain.MeasuredLayers(
            maxima:maxima,
            sublayers:{ density in
                guard density.count==3,
                      density.allSatisfy({$0.isFinite}) else {
                    throw PhysicsError.invalid("原版三亚层 CMY 输入错误")
                }
                return (0..<3).flatMap { sl in
                    (0..<3).map { ch in
                        profile.layerDensity(total:density[ch],channel:ch,sublayer:sl)
                    }
                }
            }
        )
    }

    func sourceSpatialFilmParameters() throws -> SourceSpatialFilmParams {
        guard useOriginalScanner && !useReferenceBlackWhite &&
              !defaultCAM16Gamut,
              (isPositive || (useOriginalPrintOptics && sourcePaperHDCurve != nil)),
              film.dirCorrectedCurves.count == 768,
              film.dirMatrix.count == 9,
              film.densityMaximum.count == 3 else {
            throw PhysicsError.invalid(
                "逐像素原版光学需要 Hanatos Float64、原版 DIR、" +
                "原版 ACES 扫描及负片的原版印相 H-D；" +
                "黑白参考和 CAM16 仍需独立认证，禁止降级"
            )
        }
        return SourceSpatialFilmParams(
            matrix: film.dirMatrix,
            densityMaximum: film.densityMaximum,
            positive: isPositive
        )
    }

    struct SourceSpatialInput {
        let rawLog: [Double]
        let initialDensity: [Double]
    }

    /// Original FilmingStage._rgb_to_film_raw, after the optional
    /// full-frame RGB autoexposure, BEFORE exposure EV/boost/lens blur.
    /// Unlike the LUT path, source RGB may legitimately exceed one after
    /// auto exposure. No implicit clipping or mobile colour fallback.
    func sourceCameraRaw(
        encodedRGB:[Double],cameraEV:Double
    ) throws -> [Double] {
        guard encodedRGB.count==3,
              encodedRGB.allSatisfy({ $0.isFinite && $0>=0 }),
              cameraEV.isFinite && abs(cameraEV)<=4 else {
            throw PhysicsError.invalid("原版自动测光后的相机 RGB 或曝光无效")
        }
        let linear=encodedRGB.map { Self.decodeSRGB($0) }
        let raw: [Double]
        switch cameraRawMethod {
        case .hanatos2025:
            raw = hanatos.raw(linearRGB:linear)
        case .mallett2019:
            raw = sourceMallettRaw(linearRGB:linear)
        }
        let mult=pow(2.0,cameraEV)
        let irradiance=raw.map { $0*mult }
        guard irradiance.count==3,
              irradiance.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版相机 Hanatos 光子输出非有限")
        }
        return irradiance
    }

    /// Raw-stage input after global Python boost and source lens Gaussian,
    /// converting photons to log10 and applying the source film H-D.
    func sourceSpatialInputFromCameraRaw(
        _ raw:[Double]
    ) throws -> SourceSpatialInput {
        guard raw.count==3 && raw.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版相机镜头后曝光数据无效")
        }
        let logRaw=raw.map { log10(max($0,0)+1e-10) }
        let initial=(0..<3).map {
            film.curve(logRaw[$0],channel:$0)
        }
        guard (logRaw+initial).allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版镜头后 H-D 出现 Inf/NaN")
        }
        return SourceSpatialInput(
            rawLog:logRaw,initialDensity:initial
        )
    }

    func sourceSpatialInput(
        encodedRGB: [Double], cameraEV: Double
    ) throws -> SourceSpatialInput {
        guard encodedRGB.count == 3,
              encodedRGB.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              cameraEV.isFinite && abs(cameraEV) <= 4 else {
            throw PhysicsError.invalid("源逐像素 Hanatos 输入或曝光无效")
        }
        let linear = encodedRGB.map { Self.decodeSRGB($0) }
        let raw: [Double]
        switch cameraRawMethod {
        case .hanatos2025:
            raw = hanatos.raw(linearRGB: linear)
        case .mallett2019:
            raw = sourceMallettRaw(linearRGB: linear)
        }
        guard raw.count == 3 && raw.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版相机光谱重建响应非有限")
        }
        let logE = Self.filmLogExposure(raw: raw, exposureEV: cameraEV)
        let initial = (0..<3).map {
            film.curve(logE[$0],channel:$0)
        }
        guard (logE+initial).allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("源胶片 H-D 输入或输出非有限")
        }
        return SourceSpatialInput(rawLog:logE,initialDensity:initial)
    }

    func sourceSpatialDevelopCorrectedLog(
        _ logRaw: [Double]
    ) throws -> [Double] {
        guard logRaw.count == 3,
              logRaw.allSatisfy({ $0.isFinite }),
              film.dirCorrectedCurves.count == 768 else {
            throw PhysicsError.invalid("原版校正前 H-D 曲线或 DIR 曝光缺失")
        }
        let density = (0..<3).map {
            film.curve(
                logRaw[$0],channel:$0,correctedBeforeDIR:true
            )
        }
        guard density.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版校正前 H-D 产生非有限密度")
        }
        return density
    }

    /// Source PrintingStage._film_cmy_to_print_log_raw, followed by
    /// 10**log exposure BEFORE the full-image enlarger diffusion PSF.
    /// The per-pixel printing path still uses this same printRaw,
    /// reference, exposure and preflash formula.
    func sourceSpatialPrintPhoton(
        filmDensity:[Double],paperEV:Double
    ) throws -> [Double] {
        guard !isPositive,useOriginalPrintOptics,
              filmDensity.count==3,filmDensity.allSatisfy({ $0.isFinite }),
              paperEV.isFinite,abs(paperEV)<=4,
              sourcePaperHDCurve != nil else {
            throw PhysicsError.invalid(
                "原版放大机扩散只能接入负片→原版光学印相→相纸 H-D 链，禁止近似")
        }
        let raw=Self.printRaw(
            filmDensities:filmDensity,film:film,
            weights:paperWeights,clampDensity:false
        )
        let sourceLog=OriginalPrintOptics.paperLogExposure(
            raw:raw,reference:printReference,
            preflash:opticalPreflashRaw,
            printEV:paperEV+correctedPrintExposureEV
        )
        let irradiance=sourceLog.map { pow(10.0,$0) }
        guard irradiance.allSatisfy({ $0.isFinite && $0>=0 }) else {
            throw PhysicsError.invalid("原版相纸曝光之前光谱 RAW 非有限")
        }
        return irradiance
    }

    /// After full-frame source print diffusion:
    ///   paper log10 photons -> fitted source CDF H-D -> ORIGINAL
    ///   scanner XYZ/ACES without a second reprint or LUT interpolation.
    func sourceSpatialScanPrintedPhoton(
        _ photon:[Double],sourceLinearOutput:Bool=false,
        sourceXYZOutput:Bool=false
    ) throws -> [Double] {
        guard !isPositive,useOriginalPrintOptics,
              let sourcePaperHDCurve,
              photon.count==3,
              photon.allSatisfy({$0.isFinite}) else {
            throw PhysicsError.invalid("原版放大机扩散后相纸光子或 H-D 无效")
        }
        let rawLog=photon.map { log10(max(0,$0)+1e-10) }
        let density=(0..<3).map {
            sourcePaperHDCurve.density(rawLog[$0],channel:$0)
        }
        guard density.allSatisfy({$0.isFinite}) else {
            throw PhysicsError.invalid("原版印相扩散后相纸 H-D 非有限")
        }
        let output=scanDevelopedSubstrateDensity(
            density,substrate:paper,
            sourceLinearOutput:sourceLinearOutput,
            sourceXYZOutput:sourceXYZOutput
        )
        guard output.count==3,output.allSatisfy({$0.isFinite}) else {
            throw PhysicsError.invalid("原版印相扩散扫描输出非法")
        }
        return output
    }

    func sourceSpatialScan(
        filmDensity: [Double], paperEV: Double
    ) throws -> [Double] {
        guard filmDensity.count == 3,
              filmDensity.allSatisfy({ $0.isFinite }),
              paperEV.isFinite && abs(paperEV) <= 4 else {
            throw PhysicsError.invalid("原版相纸及扫描输入密度无效")
        }
        let output = scanFilmDensity(filmDensity,paperEV:paperEV)
        guard output.count == 3,
              output.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版相纸 H-D 或光谱扫描输出非有限")
        }
        return output
    }

    /// Paper/film density→original corrected XYZ BEFORE glare and gamut.
    /// Uses the EXACT scanFilmDensity printing path; only the return
    /// boundary changes. In source physical mode B/W reference and CAM16
    /// LUT are explicitly forbidden rather than silently approximated.
    func sourceSpatialScanXYZ(
        filmDensity:[Double],paperEV:Double
    ) throws -> [Double] {
        guard useOriginalScanner, !useReferenceBlackWhite,
              !defaultCAM16Gamut,
              filmDensity.count==3,
              filmDensity.allSatisfy({ $0.isFinite }),
              paperEV.isFinite, abs(paperEV)<=4 else {
            throw PhysicsError.invalid(
                "源扫描眩光只支持有效的原版光谱 XYZ，关闭 CAM16／黑白校准"
            )
        }
        let xyz=scanFilmDensity(
            filmDensity,paperEV:paperEV,sourceXYZOutput:true
        )
        guard xyz.count==3,xyz.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版光谱 XYZ 生成失败")
        }
        return xyz
    }

    /// True Python normalized scanner lamp XYZ, NEVER medium base white.
    func sourceSpatialScannerIlluminantXYZ() throws -> [Double] {
        guard useOriginalScanner,!useReferenceBlackWhite,
              !defaultCAM16Gamut,
              scannerIlluminantXYZ.count==3,
              scannerIlluminantXYZ.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版扫描器光源 XYZ 未就绪")
        }
        return scannerIlluminantXYZ
    }

    /// RGB is intentionally computed AFTER the *whole image* gets the
    /// source glare field in XYZ, before source scanner lens FIR/YVV.
    func sourceSpatialXYZToLinearRGB(_ xyz:[Double]) throws -> [Double] {
        guard useOriginalScanner,!useReferenceBlackWhite,
              !defaultCAM16Gamut,xyz.count==3,
              xyz.allSatisfy({$0.isFinite}) else {
            throw PhysicsError.invalid("源扫描 XYZ→RGB 输入无效或色域模式未实现")
        }
        let rgb=OriginalScannerMath.compressACESRGC(
            OriginalScannerMath.linearSRGB(xyz:xyz,viewing:viewingStock)
        )
        guard rgb.count==3,rgb.allSatisfy({$0.isFinite}) else {
            throw PhysicsError.invalid("源扫描 XYZ→ACES 线性 RGB 输出非有限")
        }
        return rgb
    }

    /// True original linear RGB before scanner lens Gaussian and unsharp.
    /// Requires source optical scan, not the mobile scanner fallback.
    func sourceSpatialScanLinear(
        filmDensity:[Double],paperEV:Double
    ) throws -> [Double] {
        guard useOriginalScanner && !defaultCAM16Gamut else {
            throw PhysicsError.invalid(
                "原版扫描镜头 FIR/YVV 仅支持当前源 ACES 线性 RGB"
            )
        }
        let linear=scanFilmDensity(
            filmDensity,paperEV:paperEV,sourceLinearOutput:true
        )
        guard linear.count==3,linear.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("源扫描模糊前的真实线性 RGB 无效")
        }
        return linear
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

    /// Stage-scoped paper / movie-print scanner diagnostic. Production
    /// scanFilmDensity() uses the same scanPhysicalXYZ, linearSRGB, ACES
    /// and CCTF operations after paper development. This deliberately
    /// accepts already-developed print density: NOT negative->paper
    /// H-D/print exposure/full RAW equivalence.
    struct DirectPrintScannerStages {
        let xyz: [Double]
        let linear: [Double]
        let compressed: [Double]
        let encoded: [Double]
    }

    /// 1.8.12 source-contiguous negative film CMY -> enlarger optical
    /// raw -> log paper exposure -> source 256-node CDF H-D -> paper
    /// XYZ -> linear sRGB -> ACES -> display-encoded sRGB. This uses
    /// the same printRaw, paperDensities and scanner stages as production.
    /// Input is already developed film CMY; camera RAW/film development,
    /// spatial diffusion and default CAM16 are intentionally outside scope.
    struct SourceNegativePrintStages {
        let enlargerRaw: [Double]
        let paperLogExposure: [Double]
        let paperDensity: [Double]
        let xyz: [Double]
        let linear: [Double]
        let compressed: [Double]
        let encoded: [Double]
    }

    /// Full source-order scalar response: linear sRGB → original Hanatos
    /// camera response → original negative H-D/DIR → optical paper/scan RGB.
    /// No spatial/grain/Numba/whole-image certification.
    struct SourceCameraFilmPrintStages {
        let hanatosRaw:[Double]
        let filmLogRaw:[Double]
        let developed:SourceFilmDIRPrintStages
    }

    func sourceCameraFilmPrintStages(
        linearRGB:[Double],cameraEV:Double,paperEV:Double
    ) throws -> SourceCameraFilmPrintStages {
        guard !isPositive,linearRGB.count==3,
              linearRGB.allSatisfy({ $0.isFinite && $0>=0 && $0<=1 }),
              cameraEV.isFinite,abs(cameraEV)<=4 else {
            throw PhysicsError.invalid("Hanatos 相机曝光源诊断需有限线性 RGB/EV")
        }
        let raw=hanatos.raw(linearRGB:linearRGB)
        guard raw.count==3 && raw.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid("原版 Hanatos 曝光包含 NaN/Inf")
        }
        let logRaw=Self.filmLogExposure(raw:raw,exposureEV:cameraEV)
        let developed=try sourceFilmDIRPrintStages(logRaw,paperEV:paperEV)
        let production=Self.filmDensities(
            linearRGB,film:film,hanatos:hanatos,exposureEV:cameraEV
        )
        guard zip(production,developed.filmDIR.developedDensity)
            .allSatisfy({ abs($0.0-$0.1)<1e-12 }) else {
            throw PhysicsError.invalid("Hanatos 分段与生产显影输出不一致")
        }
        return SourceCameraFilmPrintStages(
            hanatosRaw:raw,filmLogRaw:logRaw,developed:developed
        )
    }

    /// Contiguous source stage from already-computed CAMERA FILM log10 RAW
    /// exposure through original measured negative H-D, non-spatial DIR,
    /// source enlarger, fitted paper H-D, print scan and encoded RGB.
    /// Traces the same developLogExposureStages/developLogExposure used by
    /// production image LUT; no second, approximate film-DIR algorithm.
    struct SourceFilmDIRPrintStages {
        let filmDIR: FilmDIRStages
        let printStages: SourceNegativePrintStages
    }

    func sourceFilmDIRPrintStages(
        _ filmLogRaw: [Double], paperEV: Double
    ) throws -> SourceFilmDIRPrintStages {
        guard !isPositive,filmLogRaw.count==3,
              filmLogRaw.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid(
                "负片 H-D/DIR→印相链诊断输入需三个有限 log10 曝光分量")
        }
        let filmStages=Self.developLogExposureStages(
            filmLogRaw,film:film,applyDIR:true
        )
        let measuredByProduction=dirDevelopedDensity(logRaw:filmLogRaw)
        guard zip(filmStages.developedDensity,measuredByProduction)
            .allSatisfy({ abs($0.0-$0.1) < 1e-12 }) else {
            throw PhysicsError.invalid("负片原版 DIR 分段与生产显影路径不一致")
        }
        let printed=try sourceNegativePrintStages(
            filmStages.developedDensity,paperEV:paperEV
        )
        return SourceFilmDIRPrintStages(
            filmDIR:filmStages,printStages:printed
        )
    }

    func sourceNegativePrintStages(
        _ filmDensity: [Double], paperEV: Double
    ) throws -> SourceNegativePrintStages {
        guard !isPositive, useOriginalPrintOptics, useOriginalScanner,
              !useReferenceBlackWhite, !defaultCAM16Gamut,
              sourcePaperHDCurve != nil,
              filmDensity.count == 3,
              filmDensity.allSatisfy({ $0.isFinite }),
              paperEV.isFinite && abs(paperEV) <= 4 else {
            throw PhysicsError.invalid(
                "负片印相整链分段诊断要求原版光学＋ACES 扫描和有效 CMY 密度")
        }
        let raw = Self.printRaw(
            filmDensities: filmDensity, film: film,
            weights: paperWeights, clampDensity:false
        )
        let logE = OriginalPrintOptics.paperLogExposure(
            raw:raw, reference:printReference,
            preflash:opticalPreflashRaw,printEV:paperEV+correctedPrintExposureEV
        )
        let developed = Self.paperDensities(
            filmDensity, film:film, paper:paper, weights:paperWeights,
            reference:printReference,
            printEV:paperEV+correctedPrintExposureEV,
            morph:printMorphCurve,preflashRaw:opticalPreflashRaw,
            opticalPrint:true,sourceHD:sourcePaperHDCurve
        )
        let scan = try directPrintScannerStages(developed)
        let actualEncoded = scanFilmDensity(filmDensity,paperEV:paperEV)
        guard zip(actualEncoded,scan.encoded).allSatisfy({
            abs($0.0-$0.1) < 1e-12
        }) else {
            throw PhysicsError.invalid("原版负片整链诊断与实际生产 RGB 路径不一致")
        }
        return SourceNegativePrintStages(
            enlargerRaw:raw,paperLogExposure:logE,paperDensity:developed,
            xyz:scan.xyz,linear:scan.linear,
            compressed:scan.compressed,encoded:scan.encoded
        )
    }

    func directPrintScannerStages(
        _ paperDensity: [Double]
    ) throws -> DirectPrintScannerStages {
        guard !isPositive, useOriginalScanner, !useReferenceBlackWhite,
              !defaultCAM16Gamut, paperDensity.count == 3,
              paperDensity.allSatisfy({ $0.isFinite }) else {
            throw PhysicsError.invalid(
                "相纸扫描分段诊断仅支持负片配置、关闭黑白校准及 ACES RGC")
        }
        let xyz = Self.scanPhysicalXYZ(
            densities: paperDensity, paper: paper,
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
            throw PhysicsError.invalid("相纸扫描 RGB 分段诊断产生非有限数值")
        }
        return DirectPrintScannerStages(
            xyz: xyz, linear: linear, compressed: compressed, encoded: encoded
        )
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
    /// Spatial diffusion disabled in debug.lut_mode. Keep diagnostics
    /// on EXACTLY the same native routine used by production LUT/preview.
    struct FilmDIRStages {
        let initialDensity: [Double]
        let correctedLogRaw: [Double]
        let developedDensity: [Double]
    }

    private static func developLogExposureStages(
        _ logRaw: [Double], film: Profile, applyDIR: Bool
    ) -> FilmDIRStages {
        let densityInitial=(0..<3).map { ch in
            film.curve(logRaw[ch],channel:ch)
        }
        guard applyDIR, !film.dirCorrectedCurves.isEmpty else {
            return FilmDIRStages(
                initialDensity:densityInitial,correctedLogRaw:logRaw,
                developedDensity:densityInitial
            )
        }
        // Source model/couplers.py: positive silver=dmax-D, otherwise D.
        let silver=(0..<3).map { donor -> Double in
            film.polarity == "positive"
                ? film.densityMaximum[donor]-densityInitial[donor]
                : densityInitial[donor]
        }
        // Original np.einsum('ijk,km->ijm'): donor rows, receiver columns.
        let logCorrected=(0..<3).map { receiver -> Double in
            let inhibitor=(0..<3).reduce(0.0) { total,donor in
                total+silver[donor]*film.dirMatrix[donor*3+receiver]
            }
            return logRaw[receiver]-inhibitor
        }
        let afterDIR=(0..<3).map { channel in
            film.curve(
                logCorrected[channel],channel:channel,
                correctedBeforeDIR:true
            )
        }
        return FilmDIRStages(
            initialDensity:densityInitial,correctedLogRaw:logCorrected,
            developedDensity:afterDIR
        )
    }

    private static func developLogExposure(
        _ logRaw: [Double], film: Profile, applyDIR: Bool
    ) -> [Double] {
        developLogExposureStages(
            logRaw,film:film,applyDIR:applyDIR
        ).developedDensity
    }

    /// Unit-test access to film chemistry independently of RGB/scan math.
    func dirDevelopedDensity(logRaw: [Double]) -> [Double] {
        guard logRaw.count == 3 else { return [] }
        return Self.developLogExposure(logRaw, film: film, applyDIR: true)
    }

    /// Source FilmingStage.expose ordering: raw *= 2**EV, then
    /// log10(fmax(raw,0)+1e-10). Keep production and parity identical.
    private static func filmLogExposure(
        raw: [Double], exposureEV: Double
    ) -> [Double] {
        let multiplier=pow(2.0,exposureEV)
        return raw.map { log10(max(0,$0*multiplier)+1e-10) }
    }

    private static func filmDensities(_ linear: [Double],
                                      film: Profile,
                                      hanatos: OriginalHanatosResponse,
                                      exposureEV: Double,
                                      applyDIR: Bool = true) -> [Double] {
        let raw = hanatos.raw(linearRGB: linear)
        return developLogExposure(
            filmLogExposure(raw:raw,exposureEV:exposureEV),
            film:film,applyDIR:applyDIR
        )
    }

    private static func printRaw(filmDensities: [Double], film: Profile,
                                 weights: [[Double]],
                                 clampDensity: Bool = true) -> [Double] {
        var raw = [0.0, 0.0, 0.0]
        for i in 0..<81 {
            // Source PrintingStage._film_cmy_to_print_log_raw calls
            // compute_density_spectral, then density_to_light. Any absent
            // CMY dye measurement makes that wavelength NaN (even NaN*0);
            // density_to_light sets its *transmitted light* to zero.
            // Previously packing null -> Float32(0) added false exposure.
            if !film.scannerWavelengthValid[i] { continue }
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
                                       opticalPrint: Bool = false,
                                       sourceHD: OriginalPrintMorph.SourceCurve? = nil
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
            // Original printing.py: absolute source fitted 3-layer CDF,
            // sampled at 256 exposure nodes and linearly interpolated.
            // Never substitute measured curve or apply a delta in source mode.
            if opticalPrint {
                guard let sourceHD else {
                    preconditionFailure("原版相纸 CDF H-D 数据缺失")
                }
                return sourceHD.density(logE, channel:c)
            }
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
            if !paper.scannerWavelengthValid[wl] { continue }
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
            if !paper.scannerWavelengthValid[i] { continue }
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
    /// Fast optics still decode the original packed Float32 constants.
    /// The exact optical mode switches every wavelength to source binary64.
    private static func readOriginalOptics(
        fast:String,source:String,count:Int,original:Bool
    ) throws -> [Double] {
        if original {
            return try readOriginalFloat64(source,count:count)
        }
        return try readOriginalFloat32(fast,count:count)
    }

    private static func readOriginalFloat64(
        _ encoded:String,count:Int
    ) throws -> [Double] {
        guard let data=Data(base64Encoded:encoded),
              data.count == count*MemoryLayout<Double>.size else {
            throw PhysicsError.invalid(
                "原版光谱 Float64 常量缺失，禁止回退 Float32"
            )
        }
        return data.withUnsafeBytes { raw in
            (0..<count).map { i in
                let word=raw.loadUnaligned(
                    fromByteOffset:i*8,as:UInt64.self
                )
                return Double(bitPattern:UInt64(littleEndian:word))
            }
        }
    }

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

    /// Production original Mallett 2019 raw response. The source einsum
    /// does NOT clamp negative channels here; the following film log10
    /// exposure uses max(raw,0)+1e-10. Keep that operation order intact.
    private func sourceMallettRaw(linearRGB: [Double]) -> [Double] {
        guard linearRGB.count == 3 else { return [] }
        // Original rgb_to_raw_mallett2019 explicitly calls
        // colour.RGB_to_RGB(... 'sRGB' → 'sRGB') before its spectral
        // einsum. Use its source Float64 conversion matrix from colour;
        // even same-space round trips differ from identity at ~1e-4.
        // Row-vector output order matches colour's 3×3 evaluation.
        let sourceRGB=(0..<3).map { output in
            (0..<3).reduce(0.0) { result, input in
                result + linearRGB[input] *
                    mallettSRGBConversion[input*3+output]
            }
        }
        return (0..<3).map { channel in
            (0..<3).reduce(0.0) {
                $0 + filmMatrix[channel][$1] * sourceRGB[$1]
            }
        }
    }

    /// Legacy clipped diagnostic only. Actual source production uses the
    /// original *unclipped* response method directly above.
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
