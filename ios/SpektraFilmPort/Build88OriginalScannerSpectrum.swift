import Foundation

/// Build88 source ScanningStage._return_callable_cmy_to_log_xyz.
///
/// Original ordering:
/// 1. compute_density_spectral(channel_density, density_cmy, base_density)
/// 2. density_to_light => 10**(-spectral_D) * viewing_illuminant
///    with all-NaN wavelengths transmitted as zero (not black density)
/// 3. CIE 1931 2-degree XYZ spectral integration / illuminant Y sum
/// 4. np.log10(np.fmax(xyz,0)+1e-10); then 10**log_xyz on scanner read.
///
/// All steps use Float64; no mobile colour cube or Float32 wavelengths.
enum Build88OriginalScannerSpectrum {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self{return s}
            return nil
        }
    }

    /// This *same* finishing stage is used by SpectralPhysics when running
    /// the optional original measured Float64 scanner path. Keep the true
    /// source's log10 then 10^10 inverse, not a straight +1e-10 shortcut.
    static func finishXYZ(
        _ accumulated:[Double],normalization:Double,
        sourceLogEpsilon:Bool
    ) -> [Double] {
        precondition(accumulated.count==3)
        let safe=max(normalization,1e-12)
        return accumulated.map { value in
            let normalized=max(0.0,value/safe)
            if sourceLogEpsilon {
                return pow(10.0,log10(normalized+1e-10))
            }
            // Baseline previous native scanner path; retained for
            // fast/legacy call-sites and original v1.8.58 comparison.
            return normalized
        }
    }

    static func sourceXYZ(
        density:[Double],
        base:[Double],
        dye:[Double],
        weightedXYZ:[Double],
        valid:[Bool],
        normalization:Double
    ) throws -> [Double] {
        guard density.count==3,base.count==81,dye.count==243,
              weightedXYZ.count==243,valid.count==81,
              normalization.isFinite,normalization>0,
              density.allSatisfy({$0.isFinite}),
              weightedXYZ.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "原版扫描光谱需要 81 波长 Float64 CIE/材料/光源和 3 通道密度"
            )
        }
        var xyz=[Double](repeating:0.0,count:3)
        for wl in 0..<81 where valid[wl] {
            var materialDensity=base[wl]
            for ch in 0..<3 {
                materialDensity+=dye[wl*3+ch]*density[ch]
            }
            // Upstream density_to_light has a NaN->zero transmission
            // branch, not a conversion to an assumed zero density.
            if materialDensity.isNaN {continue}
            let trans=pow(10.0,-materialDensity)
            for ch in 0..<3 {
                xyz[ch]+=trans*weightedXYZ[wl*3+ch]
            }
        }
        guard xyz.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版扫描光谱积分产生非有限 XYZ")
        }
        let finished=finishXYZ(
            xyz,normalization:normalization,sourceLogEpsilon:true
        )
        guard finished.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版扫描 log10 XYZ 转换产生非有限光子")
        }
        return finished
    }
}
