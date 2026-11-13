import Foundation

/// Original Python source pre-film stack, evaluated on uncompressed Double
/// source values: FilmingStage.auto_exposure (before spectral conversion),
/// numba_boost_hightlights.boost_highlights (in RAW photon space), and
/// apply_gaussian_blur_um (also in RAW space before H-D).
///
/// Not a substitute for nonported UV/IR spectral recalculation, source
/// diffusion filters, scatter, halation or RAW mosaic decoding.
enum OriginalSourceCameraOptics {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }

    enum Metering: String, CaseIterable {
        case disabled = "off"
        case average = "average"
        case median = "median"
        case centerWeighted = "center_weighted"
        case partial = "partial"
        case matrix = "matrix"
        case multiZone = "multi_zone"
        case highlightWeighted = "highlight_weighted"

        var displayName: String {
            switch self {
            case .disabled: return "关闭（旧版原样）"
            case .average: return "平均测光"
            case .median: return "中位数"
            case .centerWeighted: return "中央重点"
            case .partial: return "局部 15%"
            case .matrix: return "5×5 矩阵"
            case .multiZone: return "三区域"
            case .highlightWeighted: return "高光优先"
            }
        }
    }

    struct Settings {
        var metering: Metering = .disabled
        var boostEV: Double = 0
        var boostRange: Double = 0.3
        var protectEV: Double = 4
        var lensBlurUM: Double = 0
        var filmFormatMM: Double = 35

        var active: Bool { metering != .disabled || boostEV > 0 || lensBlurUM > 0 }
        var needsWholeImageBlur: Bool { lensBlurUM > 0 }

        func validate() throws {
            guard boostEV.isFinite, (0...20).contains(boostEV),
                  boostRange.isFinite, (0...1).contains(boostRange),
                  protectEV.isFinite, (0...20).contains(protectEV),
                  lensBlurUM.isFinite, (0...200).contains(lensBlurUM),
                  filmFormatMM.isFinite, (1...100).contains(filmFormatMM) else {
                throw Failure.invalid(
                    "原版摄影前处理参数越界：高光 EV 0–20，范围 0–1，" +
                    "保护 EV 0–20，镜头模糊 0–200μm，胶片画幅 1–100mm"
                )
            }
        }
    }

    private static func decodeSRGB(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    /// Python ResizingService.small_preview: nearest-neighbour, 256px long
    /// edge before metering. No interpolation/cropped camera RGB proxy.
    private static func smallPreview(
        _ rgb: [Double], width: Int, height: Int
    ) -> (rgb: [Double], width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > 256 else { return (rgb, width, height) }
        let scale = 256.0 / Double(longest)
        let newW = max(1, Int((Double(width) * scale).rounded(.toNearestOrEven)))
        let newH = max(1, Int((Double(height) * scale).rounded(.toNearestOrEven)))
        var reduced = [Double](repeating: 0, count: newW * newH * 3)
        for y in 0..<newH {
            let yy = min(height-1, max(0,
                Int(floor((Double(y)+0.5)*Double(height)/Double(newH)))))
            for x in 0..<newW {
                let xx = min(width-1, max(0,
                    Int(floor((Double(x)+0.5)*Double(width)/Double(newW)))))
                let start = (y*newW+x)*3
                let src = (yy*width+xx)*3
                for c in 0..<3 { reduced[start+c] = rgb[src+c] }
            }
        }
        return (reduced,newW,newH)
    }

    /// Exact original normalised frame coordinates: long edge [-.5,.5).
    /// The 5x5 algorithm deliberately discards right/bottom remainders,
    /// matching the source floor-divided zone boundaries.
    static func measureAutoExposureEV(
        encodedRGB: [Double], width: Int, height: Int, method: Metering
    ) throws -> Double {
        guard width > 0, height > 0,
              width <= Int.max / height / 3,
              encodedRGB.count == width * height * 3,
              encodedRGB.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw Failure.invalid("原版自动测光仅接受有限的 8-bit sRGB Double 像素")
        }
        if method == .disabled { return 0 }
        let preview = smallPreview(encodedRGB,width:width,height:height)
        let w = preview.width, h = preview.height
        // colour.RGB_COLOURSPACES['sRGB'].matrix_RGB_to_XYZ[1,:],
        // in source colour.RGB_to_XYZ(...apply_cctf_decoding=True).
        var yValues = [Double](repeating:0,count:w*h)
        for p in 0..<(w*h) {
            let i=p*3
            yValues[p] =
                0.21263900587151027 * decodeSRGB(preview.rgb[i]) +
                0.7151686787677559 * decodeSRGB(preview.rgb[i+1]) +
                0.07219231536073371 * decodeSRGB(preview.rgb[i+2])
        }
        let ySum=yValues.reduce(0,+)
        let count=Double(yValues.count)
        let average=ySum/count
        let long=Double(max(w,h))
        func coords(_ p: Int) -> (Double,Double) {
            let row=p/w,col=p%w
            return (
                (Double(col)/Double(w)-0.5)*Double(w)/long,
                (Double(row)/Double(h)-0.5)*Double(h)/long
            )
        }
        var measured=average
        switch method {
        case .disabled:
            return 0
        case .average: measured=average
        case .median:
            let sorted=yValues.sorted()
            measured = sorted.count.isMultiple(of:2)
                ? (sorted[sorted.count/2-1]+sorted[sorted.count/2])*0.5
                : sorted[sorted.count/2]
        case .centerWeighted:
            var numerator=0.0,weightSum=0.0
            for p in yValues.indices {
                let (x,y)=coords(p)
                let weight=exp(-(x*x+y*y)/(2*0.2*0.2))
                numerator+=yValues[p]*weight
                weightSum+=weight
            }
            measured=numerator/weightSum
        case .partial:
            var total=0.0,n=0
            for p in yValues.indices {
                let (x,y)=coords(p)
                if sqrt(x*x+y*y)<0.15 {
                    total+=yValues[p]
                    n+=1
                }
            }
            measured=n==0 ? average : total/Double(n)
        case .matrix:
            let rows=5,cols=5,cellH=h/rows,cellW=w/cols
            var weighted=0.0,weights=0.0
            for row in 0..<rows {
                for col in 0..<cols {
                    guard cellW>0,cellH>0 else { continue }
                    var zone=0.0
                    for y in row*cellH..<(row+1)*cellH {
                        for x in col*cellW..<(col+1)*cellW {
                            zone+=yValues[y*w+x]
                        }
                    }
                    let dy=Double(row-2)/2.0,dx=Double(col-2)/2.0
                    let dist=sqrt(dx*dx+dy*dy)/sqrt(2.0)
                    let weight=0.5*(1.0+cos(Double.pi*dist))
                    weighted+=weight*zone/Double(cellW*cellH)
                    weights+=weight
                }
            }
            guard weights>0 else {
                throw Failure.invalid("5×5 原版矩阵测光预览太小")
            }
            measured=weighted/weights
        case .multiZone:
            let ring:[(Double,Double,Double)] = [
                (0,0.05,0.50),(0.05,0.25,0.30),(0.25,0.50,0.20)
            ]
            var sum=0.0,weight=0.0
            for (lower,upper,wgt) in ring {
                var total=0.0,n=0
                for p in yValues.indices {
                    let (x,y)=coords(p)
                    let radius=sqrt(x*x+y*y)
                    if radius>=lower && radius<upper {
                        total+=yValues[p];n+=1
                    }
                }
                if n>0 {
                    sum+=wgt*(total/Double(n))
                    weight+=wgt
                }
            }
            measured=weight>0 ? sum/weight : average
        case .highlightWeighted:
            var numerator=0.0,denom=0.0
            for y in yValues {
                let weight=y*y
                numerator+=y*weight
                denom+=weight
            }
            measured=denom<1e-12 ? average : numerator/denom
        }
        // Source returns -log2(measured/0.184); +/-Inf is reset to zero,
        // while NaN is NOT silently massaged into a different meter.
        let exposure = measured/0.184
        let ev = -log2(exposure)
        if ev.isInfinite { return 0 }
        guard ev.isFinite else {
            throw Failure.invalid("原版测光计算产生 NaN")
        }
        return ev
    }

    /// Python numba_boost_hightlights.boost_highlights, array maximum and
    /// unnormalised raw domain, *after* camera EV and *before* lens blur.
    static func boostHighlightsInPlace(
        _ raw: inout [Double],
        boostEV: Double, boostRange: Double, protectEV: Double,
        midgray: Double = 0.184
    ) throws {
        guard boostEV.isFinite,boostEV>=0,
              boostRange.isFinite,(0...1).contains(boostRange),
              protectEV.isFinite,protectEV>=0,
              midgray.isFinite,midgray>=0,
              !raw.isEmpty,
              raw.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("源高光 Boost 输入或参数非法")
        }
        if boostEV == 0 { return }
        guard let maxRaw=raw.max() else { return }
        if maxRaw==0 { raw=[Double](repeating:0,count:raw.count);return }
        let x0=min(max(midgray*pow(2,protectEV),0),maxRaw)
        if x0==maxRaw { return }
        let a=pow(28,1-boostRange)
        let t=1-x0/maxRaw
        let denominator=exp(a*t)-a*t-1
        guard denominator.isFinite,denominator>0 else {
            throw Failure.invalid("源高光 Boost 分母小于零/溢出；禁止近似降级")
        }
        let k=(pow(2,boostEV)-1)/denominator
        let inv=1/maxRaw
        let scale=k*maxRaw
        for i in raw.indices {
            let x=raw[i]
            if x>x0 {
                let dx=(x-x0)*inv
                raw[i]=x+scale*(exp(a*dx)-a*dx-1)
            }
        }
        guard raw.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("原版高光重建结果出现 Inf/NaN")
        }
    }

    /// Original FilmingStage.expose lens blur: raw photons, not encoded RGB,
    /// σ = lens_blur_um / (film_format_mm*1000/max(image dimensions)).
    /// FIR/YVV implementation is shared with source 2D spatial DIR.
    static func applyLensBlur(
        _ raw: [Double],width:Int,height:Int,
        settings:Settings
    ) throws -> [Double] {
        try settings.validate()
        // Validate multiplication BEFORE computing count. Oversized or
        // malformed dimensions must raise an error, not trap the app.
        guard width > 0, height > 0,
              width <= Int.max / height / 3,
              raw.count == width * height * 3,
              raw.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("原版镜头模糊需要完整 Double RGB 光子帧")
        }
        if settings.lensBlurUM==0 {return raw}
        let pixelUM=settings.filmFormatMM*1000/Double(max(width,height))
        return try SourceSpatialDIRConvolution.diffuseMemoryBounded(
            raw,width:width,height:height,
            coreSigma:settings.lensBlurUM/pixelUM,
            tailSigma:0,tailWeight:0
        )
    }
}
