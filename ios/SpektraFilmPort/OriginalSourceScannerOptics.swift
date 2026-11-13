import Foundation

/// Original Python ScanningStage._apply_blur_and_unsharp in RGB LINEAR
/// space, AFTER paper CDF→XYZ→ACES and BEFORE output sRGB CCTF.
///
/// This is a deterministic opt-in subset of the scanner pipeline, NOT the
/// original stochastic glare (which requires source Numba/SciPy RNG).
/// Each blur uses the actual source reflect FIR (<3) or full-frame YVV
/// (>=3). All buffers and operations remain Double; no CoreImage Gaussian,
/// Float32 optical cube, preview-only effect or independent image tiles.
enum OriginalSourceScannerOptics {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    struct Settings {
        var lensBlurSigma:Double = 0
        var unsharpSigma:Double = 0
        var unsharpAmount:Double = 0

        var active:Bool {
            lensBlurSigma > 0 || (unsharpSigma > 0 && unsharpAmount > 0)
        }
        func validate() throws {
            guard lensBlurSigma.isFinite,
                  unsharpSigma.isFinite, unsharpAmount.isFinite,
                  (0...50).contains(lensBlurSigma),
                  (0...50).contains(unsharpSigma),
                  (0...2).contains(unsharpAmount) else {
                throw Failure.invalid(
                    "源扫描 Gaussian/Unsharp 参数无效或超过此实验版" +
                    " sigma 50 像素与 amount 2 的保护范围"
                )
            }
        }
    }

    static func applyInPlace(
        _ linearRGB:inout [Double],width:Int,height:Int,
        settings:Settings,
        stageDoubleObserver: ((String,[Double])->Void)?=nil
    ) throws {
        try settings.validate()
        guard width>0,height>0,width<=8192,height<=8192,
              width<=12_000_000/height,
              linearRGB.count==width*height*3,
              linearRGB.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("源扫描原尺寸线性 RGB 数据或像素布局无效")
        }
        guard settings.active else {return}
        if settings.lensBlurSigma>0 {
            // Source apply_gaussian_blur: blur the actual linear RGB.
            // One Gaussian, no source exponential-tail DIR mixture.
            let blurred=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                linearRGB,width:width,height:height,
                coreSigma:settings.lensBlurSigma,
                tailSigma:0,tailWeight:0
            )
            stageDoubleObserver?("scannerLensBlur",blurred)
            linearRGB=blurred
        }
        if settings.unsharpSigma>0 && settings.unsharpAmount>0 {
            // Source apply_unsharp_mask: source + amount*(source -
            // fast_gaussian_filter(source, sigma)), in this order.
            let blurred=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                linearRGB,width:width,height:height,
                coreSigma:settings.unsharpSigma,
                tailSigma:0,tailWeight:0
            )
            stageDoubleObserver?("scannerUnsharpBlur",blurred)
            for i in linearRGB.indices {
                let x=linearRGB[i]
                linearRGB[i]=x+settings.unsharpAmount*(x-blurred[i])
            }
        }
        stageDoubleObserver?("scannerLinear",linearRGB)
        guard linearRGB.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("原版扫描线性 RGB 的镜头模糊或锐化出现 NaN/Inf")
        }
    }
}
