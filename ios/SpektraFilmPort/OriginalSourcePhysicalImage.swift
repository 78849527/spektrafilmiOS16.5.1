import Foundation

/// v1.8.22: opt-in full-source *nonlinear* optical spatial image pipeline.
/// It calls the ACTUAL Swift production Hanatos, H-D, optical enlarger,
/// s023 paper development and measured-spectrum scanner for EACH pixel.
/// Unlike the older exact-DIR path, it never creates or interpolates a
/// colour 3D LUT. Only original 2D FIR/YVV is used for spatial DIR.
/// Unsupported stochastic grain, RAW, halation and post-scanner effects
/// remain deliberately unavailable, without a silent approximate fallback.
///
/// Remaining limits: some original measured data are Float32-packed; this
/// is not all-modules Float64 parity or source Numba stochastic emulation.
enum OriginalSourcePhysicalImage {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    /// Full-resolution physical paths can be CPU- and memory-intensive.
    /// Refuse oversized images before allocating multi-stage Double arrays.
    /// The older 8-bit exact-DIR path remains independently available.
    static let maximumPixels = 2_000_000

    struct Parameters {
        let filmID: String
        let paperID: String
        let cameraEV: Double
        let paperEV: Double
        let dir: SpatialDIRSettings
        let print: OriginalPrintOptics.Settings
        let morph: OriginalPrintMorph.Settings

        func validate() throws {
            guard SpectralPhysics.supportedFilmIDs.contains(filmID),
                  SpectralPhysics.supportedPaperIDs.contains(paperID),
                  cameraEV.isFinite && abs(cameraEV) <= 4,
                  paperEV.isFinite && abs(paperEV) <= 4,
                  dir.enabled && dir.valid && dir.sourceConvolutionEnabled,
                  print.isValid else {
                throw Failure.invalid(
                    "原版逐像素物理模式需要有效胶片/相纸、源 DIR 和原版光学参数"
                )
            }
            if !SpectralPhysics.isPositiveFilm(filmID) && !print.enabled {
                throw Failure.invalid(
                    "负片逐像素物理模式需要启用原版放大机光学印相和相纸 H-D"
                )
            }
        }

        func createEngine() throws -> SpectralPhysics {
            try validate()
            return try SpectralPhysics(
                filmID: filmID, paperID: paperID,
                sourceScanner: true,
                scannerBlackWhite: false,
                cam16Gamut: false,
                printReferenceCorrection: false,
                printMorph: morph,
                printOptics: print,
                cameraExposureEV: cameraEV,
                hanatosPrecision: .originalFloat64
            )
        }
    }

    /// Stage callback is opt-in (CI tests). Production does not retain each
    /// historical image stage or install a CoreImage pixel interop buffer.
    static func develop(
        _ input: OriginalSourcePixelIO.Frame,
        parameters: Parameters,
        stageDoubleObserver: ((String, [Double]) -> Void)? = nil
    ) throws -> OriginalSourcePixelIO.Frame {
        try parameters.validate()
        let w = input.width, h = input.height
        guard w > 0, h > 0, w <= 8192, h <= 8192,
              w <= maximumPixels / h,
              input.rgb.count == w*h*3,
              input.rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else {
            throw Failure.invalid(
                "逐像素完整光学模式当前最多 200 万像素，不允许缩图或" +
                "自动改走 Float32 LUT。可关闭此实验开关使用既有原版 DIR 模式。"
            )
        }

        let engine = try parameters.createEngine()
        let source = try engine.sourceSpatialFilmParameters()
        let size = w*h*3
        var logRaw = [Double](repeating: 0, count: size)
        var inhibitors = [Double](repeating: 0, count: size)
        var initialObserved: [Double]? = stageDoubleObserver == nil
            ? nil : [Double](repeating: 0, count: size)

        // First stage: real source Hanatos at EVERY input RGB (not a cube
        // approximation), exposure EV, original measured film H-D and
        // source donor->receiver DIR inhibition with reversal silver rule.
        for p in 0..<(w*h) {
            let k = p*3
            let sample = [input.rgb[k], input.rgb[k+1], input.rgb[k+2]]
            let initial = try engine.sourceSpatialInput(
                encodedRGB: sample, cameraEV: parameters.cameraEV
            )
            for c in 0..<3 {
                logRaw[k+c] = initial.rawLog[c]
                initialObserved?[k+c] = initial.initialDensity[c]
            }
            for receiver in 0..<3 {
                var total = 0.0
                for donor in 0..<3 {
                    let density = initial.initialDensity[donor]
                    let silver = source.positive
                        ? source.densityMaximum[donor] - density : density
                    total += silver * source.matrix[donor*3 + receiver]
                }
                inhibitors[k+receiver] = total
            }
        }
        stageDoubleObserver?("logRaw",logRaw)
        if let initialObserved {
            stageDoubleObserver?("initial",initialObserved)
        }
        stageDoubleObserver?("inhibitors",inhibitors)

        // Second stage: exact source 2D spatial reflect FIR or Young-van
        // Vliet IIR, including original three-Gaussian exponential tail.
        // Runs in Float64, with image extent and pixel geometry preserved.
        let pixelUM = parameters.dir.referencePixelSizeUM ??
            (36_000.0 / Double(max(w,h)))
        let radius = parameters.dir.diffusionRadiusScale
        let diffused = try SourceSpatialDIRConvolution.diffuse(
            inhibitors, width:w, height:h,
            coreSigma:20.0*radius/pixelUM,
            tailSigma:200.0*radius/pixelUM,
            tailWeight:parameters.dir.tailWeight
        )
        stageDoubleObserver?("diffused",diffused)

        // Third and fourth stages: source corrected log exposure -> original
        // pre-DIR film H-D -> 81-wavelength negative optical printing, real
        // s023 paper H-D and XYZ/ACES/sRGB scanner. No coarse 3D LUT at all.
        var printed = [Double](repeating:0,count:size)
        var correctedObserved: [Double]? = stageDoubleObserver == nil
            ? nil : [Double](repeating:0,count:size)
        var densityObserved: [Double]? = stageDoubleObserver == nil
            ? nil : [Double](repeating:0,count:size)
        for p in 0..<(w*h) {
            let k=p*3
            let logCorrected = (0..<3).map { c in
                logRaw[k+c] - diffused[k+c]
            }
            let density = try engine.sourceSpatialDevelopCorrectedLog(
                logCorrected
            )
            let rgb = try engine.sourceSpatialScan(
                filmDensity:density, paperEV:parameters.paperEV
            )
            for c in 0..<3 {
                correctedObserved?[k+c] = logCorrected[c]
                densityObserved?[k+c] = density[c]
                printed[k+c] = rgb[c]
            }
        }
        if let correctedObserved {
            stageDoubleObserver?("correctedLog",correctedObserved)
        }
        if let densityObserved {
            stageDoubleObserver?("density",densityObserved)
        }
        stageDoubleObserver?("printed",printed)
        guard printed.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("逐像素真实光学计算产生非有限 RGB")
        }
        return OriginalSourcePixelIO.Frame(
            width:w,height:h,rgb:printed
        )
    }
}

#if canImport(UIKit)
import UIKit
#endif

extension OriginalSourcePixelIO {
    // Keep source-physical utilities separate so existing original DIR-only
    // ImageIO and source kernel tests compile without SpectralPhysics.
    #if canImport(UIKit)
    static func previewPhysical(
        _ data:Data,parameters:OriginalSourcePhysicalImage.Parameters
    ) throws -> UIImage {
        let frame=try decode(
            data,previewMaxSide:640,
            maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
        )
        let developed=try OriginalSourcePhysicalImage.develop(
            frame,parameters:parameters
        )
        return UIImage(cgImage:try displayImage(developed))
    }
    #endif

    static func exportPhysicalJPEG(
        _ data:Data,parameters:OriginalSourcePhysicalImage.Parameters
    ) throws -> URL {
        let frame=try decode(
            data,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
        )
        let developed=try OriginalSourcePhysicalImage.develop(
            frame,parameters:parameters
        )
        return try createJPEG(developed)
    }
}
