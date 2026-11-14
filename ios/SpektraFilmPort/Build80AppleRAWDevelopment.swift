import Foundation
import CoreImage
import CoreGraphics

/// Build80/10-12: controllable, real Apple sensor-RAW development probe.
///
/// This is NOT rawpy/LibRaw equivalence. Apple's neutralTint is an offset
/// (-150...150); SpektraFilm's Python tint is a Float32 GREEN MULTIPLIER.
/// Apple's lens correction is not Python Lensfun, and its demosaic/colour
/// processing is not the source 16-bit linear ACES2065-1 contract.
/// No JPEG thumbnail, full-frame export, or production film processing here.
enum Build80AppleRAWDevelopment {
    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            if case .unsupported(let message) = self { return message }
            return nil
        }
    }

    enum WhiteBalance {
        case asShot
        case appleTemperature(kelvin: Float, tintOffset: Float)
    }

    struct Options {
        let whiteBalance: WhiteBalance
        let exposureEV: Float
        let appleLensCorrection: Bool

        static let asShot = Options(
            whiteBalance: .asShot,
            exposureEV: 0,
            appleLensCorrection: false
        )
        static let daylightDiagnostic = Options(
            whiteBalance: .appleTemperature(kelvin: 6504, tintOffset: 0),
            exposureEV: 0,
            appleLensCorrection: false
        )
        static let tungstenDiagnostic = Options(
            whiteBalance: .appleTemperature(kelvin: 2850, tintOffset: 0),
            exposureEV: 0,
            appleLensCorrection: false
        )
    }

    struct Assessment {
        let format: Build79RAWSignature.Kind
        let dimensions: (width: Int, height: Int)
        let measuredRGBA: [Float]
        let sampleOrigin: (x: Int, y: Int)
        let actualTemperature: Float
        let actualTintOffset: Float
        let actualExposureEV: Float
        let appleLensCorrectionEnabled: Bool
        let decoderVersion: String
        let outputColorSpace: String
        let originalPythonRAWParity: Bool
    }

    static func validate(_ options: Options) throws {
        guard options.exposureEV.isFinite,
              options.exposureEV >= -10,
              options.exposureEV <= 10 else {
            throw Failure.unsupported(
                "Build80 Apple RAW 诊断 EV 必须为有限数，范围 -10...10"
            )
        }
        switch options.whiteBalance {
        case .asShot:
            break
        case let .appleTemperature(kelvin, tintOffset):
            guard kelvin.isFinite, kelvin >= 2000, kelvin <= 50000,
                  tintOffset.isFinite,
                  tintOffset >= -150, tintOffset <= 150 else {
                throw Failure.unsupported(
                    "Build80 Apple RAW 色温需 2000...50000 K，Tint 偏移 -150...150"
                )
            }
        }
    }

    static func probe(_ url: URL, options: Options) throws -> Assessment {
        try validate(options)
        guard let kind = try Build79RAWSignature.probeFile(url) else {
            throw Failure.unsupported("当前文件不是受支持的真实 RAW 容器")
        }
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw Failure.unsupported(
                "Apple CIRAWFilter 不支持此机型或 RAW 压缩方式，禁止用 JPEG 预览顶替"
            )
        }

        // Separate Apple-only diagnostic controls, not an inferred mapping
        // from Python rawpy white_balance/tint/lensfun.
        raw.isDraftModeEnabled = false
        raw.isGamutMappingEnabled = false
        raw.appleRawExposureForDiagnostic = options.exposureEV
        raw.isLensCorrectionEnabled = options.appleLensCorrection
        raw.boostAmount = 0
        raw.localToneMapAmount = 0
        switch options.whiteBalance {
        case .asShot:
            // Preserve this decoder's actual as-shot neutral values.
            break
        case let .appleTemperature(kelvin, tintOffset):
            raw.neutralTemperature = kelvin
            raw.neutralTint = tintOffset
        }

        guard let output = raw.outputImage else {
            throw Failure.unsupported("Apple RAW 无像素输出，拒绝只用文件头声明解码成功")
        }
        let extent = output.extent
        guard !extent.isEmpty,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 4, extent.height >= 4,
              extent.width <= 100_000, extent.height <= 100_000 else {
            throw Failure.unsupported("Apple RAW 输出尺寸无效，不可按原片解码")
        }

        // CI renders *decoded sensor RAW* into an explicitly named LINEAR
        // sRGB diagnostic buffer. This is NOT the source ACES2065-1 image.
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        else {
            throw Failure.unsupported("系统缺少 extended-linear-sRGB 色彩空间")
        }
        let sampleX = Int(floor(extent.midX)) - 2
        let sampleY = Int(floor(extent.midY)) - 2
        let region = CGRect(x: sampleX, y: sampleY, width: 4, height: 4)
        var pixels = [Float](repeating: .nan, count: 4 * 4 * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        pixels.withUnsafeMutableBytes { memory in
            context.render(
                output,
                toBitmap: memory.baseAddress!,
                rowBytes: 4 * 4 * MemoryLayout<Float>.size,
                bounds: region,
                format: .RGBAf,
                colorSpace: linear
            )
        }
        guard pixels.allSatisfy({ $0.isFinite }) else {
            throw Failure.unsupported(
                "Apple RAW 实际 Float32 像素渲染失败或出现 NaN/Inf"
            )
        }

        return Assessment(
            format: kind,
            dimensions: (Int(extent.width), Int(extent.height)),
            measuredRGBA: pixels,
            sampleOrigin: (sampleX, sampleY),
            actualTemperature: raw.neutralTemperature,
            actualTintOffset: raw.neutralTint,
            actualExposureEV: raw.exposure,
            appleLensCorrectionEnabled: raw.isLensCorrectionEnabled,
            decoderVersion: String(describing: raw.decoderVersion),
            outputColorSpace: "extendedLinearSRGB (Apple RGB, NOT ACES2065-1)",
            originalPythonRAWParity: false
        )
    }
}

// Keep the Apple exposure option name visible here, instead of confusing
// its float exposure with source camera exposure compensation stages.
private extension CIRAWFilter {
    var appleRawExposureForDiagnostic: Float {
        get { exposure }
        set { exposure = newValue }
    }
}
