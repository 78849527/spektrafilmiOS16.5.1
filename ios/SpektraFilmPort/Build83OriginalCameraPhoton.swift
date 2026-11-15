import Foundation

/// Build83/19 — original FilmingStage.expose CPU Float64 photon domain.
/// Python pins: filming.py@b58759160dfa9dd45b5528b09b24ffafb5493b66
/// and numba_boost_hightlights.py (separately pinned in Python oracle).
///
/// The source equation is log10(fmax(raw * filmingReferenceScale, 0) + 1e-10),
/// after camera EV/boost/2D diffusion/lens blur/film scatter & halation.
/// This stage intentionally does not clip negative sensor photons before
/// spatial operations; only fmax at the terminal logarithm does that.
/// A missing source-derived reference correction is NOT invented: production
/// continues with explicit 1.0 until reference calculation is ported.
enum Build83OriginalCameraPhoton {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let why) = self { return why }
            return nil
        }
    }

    /// Source: raw *= 2**camera.exposure_compensation_ev.
    static func exposureCompensated(_ raw: [Double], ev: Double) throws -> [Double] {
        guard ev.isFinite, raw.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Build83 原版相机曝光输入必须为有限 Float64")
        }
        let scale=pow(2.0,ev)
        guard scale.isFinite,scale>0 else {
            throw Failure.invalid("Build83 原版曝光补偿倍率溢出")
        }
        let result=raw.map {$0*scale}
        guard result.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Build83 原版 RAW 光子倍率结果非有限")
        }
        return result
    }

    /// Original Python: raw *= black_white_filming_exposure_correction();
    /// log_raw = np.log10(np.fmax(raw, 0.0) + 1e-10).
    /// The correction is a genuine source pipeline argument, not an RGB
    /// luminance substitute. No 1e-14 floor, log(max(raw,1e-10)),
    /// abs(raw), saturation/clamping or Float32 conversion.
    static func logExposure(
        photons: [Double],
        filmingReferenceScale: Double = 1.0
    ) throws -> [Double] {
        guard filmingReferenceScale.isFinite,filmingReferenceScale>=0,
              photons.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Build83 原版 RAW film reference 参数无效")
        }
        var result=[Double]()
        result.reserveCapacity(photons.count)
        for photon in photons {
            let adjusted=photon*filmingReferenceScale
            guard adjusted.isFinite else {
                throw Failure.invalid("Build83 source RAW reference photons overflow")
            }
            let source=log10(max(adjusted,0.0)+1e-10)
            guard source.isFinite else {
                throw Failure.invalid("Build83 source log10 photons nonfinite")
            }
            result.append(source)
        }
        return result
    }
}
