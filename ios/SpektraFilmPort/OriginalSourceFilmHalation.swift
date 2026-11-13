import Foundation

/// Python model.diffusion.apply_halation_um, after camera lens and before
/// film H-D. Original linear photon-domain scatter and back-reflection.
/// No Core Image glow or mobile Gaussian approximation.
enum OriginalSourceFilmHalation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let msg) = self { return msg }
            return nil
        }
    }

    struct Settings {
        var active:Bool=false
        var scatterAmount:Double=1.0
        var scatterSpatialScale:Double=1.0
        var halationAmount:Double=1.0
        var halationSpatialScale:Double=1.0
        var filmFormatMM:Double=35.0
        // Original runtime.params_schema.HalationParams defaults.
        var scatterCoreUM:[Double]=[2.2,2.0,1.6]
        var scatterTailUM:[Double]=[9.3,9.7,9.1]
        var scatterTailWeight:[Double]=[0.78,0.65,0.67]
        var halationStrength:[Double]=[0.05,0.015,0.0]
        var halationFirstSigmaUM:[Double]=[65,65,65]
        var bounceCount:Int=3
        var bounceDecay:Double=0.5
        var renormalize:Bool=true

        func validate() throws {
            guard scatterAmount.isFinite,(0...1).contains(scatterAmount),
                  scatterSpatialScale.isFinite,(0...8).contains(scatterSpatialScale),
                  halationAmount.isFinite,(0...4).contains(halationAmount),
                  halationSpatialScale.isFinite,(0...8).contains(halationSpatialScale),
                  filmFormatMM.isFinite,filmFormatMM>0,filmFormatMM<=100,
                  (1...12).contains(bounceCount),
                  bounceDecay.isFinite,(0...1).contains(bounceDecay),
                  scatterCoreUM.count==3,scatterTailUM.count==3,
                  scatterTailWeight.count==3,halationStrength.count==3,
                  halationFirstSigmaUM.count==3,
                  (scatterCoreUM+scatterTailUM+halationStrength+halationFirstSigmaUM)
                    .allSatisfy({$0.isFinite && $0>=0}),
                  scatterTailWeight.allSatisfy({$0.isFinite && (0...1).contains($0)})
            else { throw Failure.invalid("原版散射/背反射参数或 RGB 光学阵列无效") }
        }
    }

    static func applyInPlace(
        _ photons:inout [Double],width:Int,height:Int,settings:Settings
    ) throws {
        try settings.validate()
        if !settings.active { return }
        guard width>0,height>0,width<=8192,height<=8192,
              width<=12_000_000/height,
              photons.count==width*height*3,
              photons.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版散射/背反射需要完整有限的 Double 光子帧")
        }
        let pixelUM=settings.filmFormatMM*1000.0/Double(max(width,height))
        guard pixelUM.isFinite,pixelUM>0 else {
            throw Failure.invalid("原版散射/背反射像素尺寸无效")
        }

        let scatter=settings.scatterAmount
        let coreSigma=settings.scatterCoreUM.map {
            max($0*settings.scatterSpatialScale/pixelUM,1e-6)
        }
        let tailDecay=settings.scatterTailUM.map {
            max($0*settings.scatterSpatialScale/pixelUM,1e-6)
        }
        // E1=(1-s)*E0+s*((1-w)*Gaussian(E0)+w*Exponential(E0)).
        if scatter>0 &&
           (coreSigma.contains(where:{$0>1e-6}) ||
            tailDecay.contains(where:{$0>1e-6})) {
            let core=try SourceSpatialDIRConvolution.gaussianPerChannelMemoryBounded(
                photons,width:width,height:height,sigmas:coreSigma
            )
            let tail=try SourceSpatialDIRConvolution.exponentialPerChannelMemoryBounded(
                photons,width:width,height:height,decay:tailDecay
            )
            for i in photons.indices {
                let c=i%3
                let scattered=(1.0-settings.scatterTailWeight[c])*core[i] +
                    settings.scatterTailWeight[c]*tail[i]
                photons[i]=(1.0-scatter)*photons[i]+scatter*scattered
            }
        }

        let amplitude=settings.halationStrength.map {$0*settings.halationAmount}
        let firstSigma=settings.halationFirstSigmaUM.map {
            $0*settings.halationSpatialScale/pixelUM
        }
        // E2=E1+a_total*sum_k(normalized(rho^(k-1))*G(sigma*sqrt(k))*E1).
        if amplitude.contains(where:{$0>0}) &&
           firstSigma.contains(where:{$0>0}) {
            var bounceWeights=(1...settings.bounceCount).map {
                pow(settings.bounceDecay,Double($0-1))
            }
            let total=bounceWeights.reduce(0,+)
            guard total.isFinite,total>0 else {
                throw Failure.invalid("原版多次反射衰减系数无法归一化")
            }
            for i in bounceWeights.indices {bounceWeights[i]/=total}
            var bounced=[Double](repeating:0,count:photons.count)
            for bounce in 1...settings.bounceCount {
                let factor=Double(bounce).squareRoot()
                let sigma=firstSigma.map {max($0*factor,1e-6)}
                let part=try SourceSpatialDIRConvolution.gaussianPerChannelMemoryBounded(
                    photons,width:width,height:height,sigmas:sigma
                )
                let weight=bounceWeights[bounce-1]
                for i in bounced.indices {bounced[i]+=weight*part[i]}
            }
            for i in photons.indices {
                let a=amplitude[i%3]
                photons[i]=photons[i]+a*bounced[i]
                if settings.renormalize {photons[i]/=(1.0+a)}
            }
        }
        guard photons.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版散射/背反射出现 NaN/Inf；禁止静默降级")
        }
    }
}
