import Foundation

/// Literal Float64 source ColorReferenceService core, including the
/// independent black-only, white-only and both-switch branches.
/// Original upstream module: runtime/services/color_reference.py.
/// A measured, finite 256x3 paper curve is required for exposure inversion.
/// This routine never substitutes mobile scanner endpoint estimates.
enum Build87OriginalColorReference {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self {return s}
            return nil
        }
    }

    struct Settings {
        var blackCorrection=false
        var whiteCorrection=false
        var blackLevel=0.01
        var whiteLevel=0.98

        func validate() throws {
            guard blackLevel.isFinite,whiteLevel.isFinite,
                  (0...1).contains(blackLevel),
                  (0...1).contains(whiteLevel) else {
                throw Failure.invalid("源扫描黑白参考档位必须是有限 sRGB [0,1]")
            }
        }
        var enabled:Bool { blackCorrection || whiteCorrection }
    }

    struct Prepared {
        let settings:Settings
        let yBlack:Double
        let yWhite:Double
        let m:Double
        let q:Double
        let midgrayBeforeCorrection:Double

        /// Original ColorReferenceService.black_white_xyz_correction:
        /// Ycorr=clip(m*Y+q,0,1), XYZ*=Ycorr/(Y+1e-10).
        func correctXYZ(_ xyz:[Double]) throws -> [Double] {
            guard xyz.count==3,
                  xyz.allSatisfy({$0.isFinite}) else {
                throw Failure.invalid("源扫描 XYZ 输入非有限")
            }
            if !settings.enabled {return xyz}
            let corrected=max(0,min(1,m*xyz[1]+q))
            let factor=corrected/(xyz[1]+1e-10)
            let out=xyz.map{$0*factor}
            guard out.allSatisfy({$0.isFinite}) else {
                throw Failure.invalid("源扫描黑白 XYZ 校正溢出")
            }
            return out
        }

        /// Original PrintingStage invokes this BEFORE optical print
        /// diffusion, after print_exposure. Source negative-print branch
        /// returns 10^(E(corrected midgray)-E(original midgray)).
        func printExposureFactor(
            logExposure:[Double],densityCurves:[Double],
            spectralBase:[Double]
        ) throws -> Double {
            if !settings.enabled {return 1.0}
            let curve=try Self.meanChannelCurve(
                logExposure:logExposure,densityCurves:densityCurves
            )
            let base=try Self.nanMean(spectralBase)
            let currentDensity = -log10(0.184)
            guard midgrayBeforeCorrection > 0 else {
                throw Failure.invalid("源印相参考反演无正亮度中灰")
            }
            let targetDensity = -log10(midgrayBeforeCorrection)
            let corrected=Self.npInterp(targetDensity-base,
                                        axis:curve,values:logExposure)
            let original=Self.npInterp(currentDensity-base,
                                       axis:curve,values:logExposure)
            let result=pow(10.0,corrected-original)
            guard result.isFinite && result>0 else {
                throw Failure.invalid("源印相黑白参考光子倍率无效")
            }
            return result
        }

        /// Original positive-film direct scan branch has a reversed
        /// density axis (negative optical characteristic) and returns
        /// 1/(10^(E_corrected-E_original)).
        func filmingExposureFactor(
            logExposure:[Double],densityCurves:[Double],
            spectralBase:[Double]
        ) throws -> Double {
            if !settings.enabled {return 1.0}
            let curve=try Self.meanChannelCurve(
                logExposure:logExposure,densityCurves:densityCurves
            )
            let base=try Self.nanMean(spectralBase)
            guard midgrayBeforeCorrection>0 else {
                throw Failure.invalid("原版正片中灰参考值非法")
            }
            let density = -log10(0.184)
            let adjusted = -log10(midgrayBeforeCorrection)
            let inverted=curve.map { -$0 }
            let corrected = -Self.npInterp(
                -(adjusted-base),axis:inverted,values:logExposure
            )
            let original = -Self.npInterp(
                -(density-base),axis:inverted,values:logExposure
            )
            let factor=pow(10.0,original-corrected)
            guard factor.isFinite && factor>0 else {
                throw Failure.invalid("源正片曝光参考倍率无效")
            }
            return factor
        }

        private static func nanMean(_ values:[Double]) throws -> Double {
            let samples=values.filter{$0.isFinite}
            guard !samples.isEmpty else {
                throw Failure.invalid("源黑白参考片基光谱没有有效数值")
            }
            return samples.reduce(0,+)/Double(samples.count)
        }

        private static func meanChannelCurve(
            logExposure:[Double],densityCurves:[Double]
        ) throws -> [Double] {
            let n=logExposure.count
            guard n==256,densityCurves.count==n*3,
                  logExposure.allSatisfy({$0.isFinite}),
                  zip(logExposure.dropFirst(),logExposure)
                    .allSatisfy({$0.0 >= $0.1}) else {
                throw Failure.invalid("原版中灰参考需要 256×3 实测曲线")
            }
            var result=[Double](repeating:0,count:n)
            for i in 0..<n {
                var sum=0.0,valid=0
                for c in 0..<3 {
                    let v=densityCurves[i*3+c]
                    if v.isFinite {sum+=v;valid+=1}
                }
                guard valid>0 else {
                    throw Failure.invalid("源纸张曲线有无效的全部三通道节点")
                }
                result[i]=sum/Double(valid)
            }
            return result
        }

        /// NumPy np.interp: clipped endpoints, upper-bound binary search.
        /// The original code does not sort a nonmonotonic response.
        static func npInterp(
            _ x:Double,axis:[Double],values:[Double]
        ) -> Double {
            precondition(axis.count==values.count && !axis.isEmpty)
            if x<=axis[0] {return values[0]}
            let last=axis.count-1
            if x>=axis[last] {return values[last]}
            var lo=0,hi=axis.count
            while lo<hi {
                let mid=(lo+hi)/2
                if x<axis[mid] {hi=mid} else {lo=mid+1}
            }
            let lower=lo-1
            let d=axis[lo]-axis[lower]
            if d==0 {return values[lo]}
            let ratio=(x-axis[lower])/d
            return values[lower]+ratio*(values[lo]-values[lower])
        }
    }

    /// Original _correction_fucntion (sic) source:
    /// when only black is active, preserve measured white; vice versa.
    /// Never infer that 'blackCorrection=true' also enables white.
    static func prepare(
        settings:Settings,yBlack:Double,yWhite:Double
    ) throws -> Prepared {
        try settings.validate()
        guard yBlack.isFinite,yWhite.isFinite else {
            throw Failure.invalid("原版黑白扫描 Y 参考无效")
        }
        if !settings.enabled {
            return Prepared(settings:settings,
                yBlack:yBlack,yWhite:yWhite,m:1,q:0,
                midgrayBeforeCorrection:0.184)
        }
        guard abs(yWhite-yBlack)>1e-10 else {
            throw Failure.invalid("源黑白扫描参考退化，拒绝静默旁路")
        }
        let black=settings.blackCorrection
            ? OriginalScannerMath.decodeSRGB(settings.blackLevel)
            : yBlack
        let white=settings.whiteCorrection
            ? OriginalScannerMath.decodeSRGB(settings.whiteLevel)
            : yWhite
        let m=(white-black)/(yWhite-yBlack+1e-10)
        let q=black-m*yBlack
        guard m.isFinite,abs(m)>1e-14,q.isFinite else {
            throw Failure.invalid("原版黑白参考斜率／截距无效")
        }
        let gray=(0.184-q)/m
        guard gray.isFinite else {
            throw Failure.invalid("原版黑白参考中灰反演无效")
        }
        return Prepared(settings:settings,yBlack:yBlack,
            yWhite:yWhite,m:m,q:q,
            midgrayBeforeCorrection:gray)
    }

    /// develop_simple for reference ONLY. No creative morph, pre-DIR
    /// correction or normalized stock H-D. Source print uses the
    /// original paper.data.density_curves sampled on its original axis.
    static func referencePaperDensity(
        rawLog:[Double],logExposure:[Double],densityCurves:[Double]
    ) throws -> [Double] {
        guard rawLog.count==3,rawLog.allSatisfy({$0.isFinite}),
              logExposure.count==256,densityCurves.count==768 else {
            throw Failure.invalid("原版印相黑白曝光参考 H-D 数据缺失")
        }
        return (0..<3).map { channel in
            let values=(0..<256).map { densityCurves[$0*3+channel] }
            return Prepared.npInterp(rawLog[channel],
                                     axis:logExposure,values:values)
        }
    }
}
