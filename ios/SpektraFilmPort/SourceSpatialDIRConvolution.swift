import Foundation
import CoreImage
import CoreGraphics

/// Actual source fast_gaussian_filter.py FIR/YVV dispatcher and source
/// 3-Gaussian fast_exponential_filter for spatial DIR inhibitors.
///
/// Source uses reflect FIR under sigma < 3.0 and Young–van Vliet
/// forward/backward 3rd-order IIR for sigma >= 3.0. It intentionally does
/// NOT use Core Image's Gaussian and its different boundary conditions.
/// Source arithmetic is Double. The interop pixels are RGBAf Float32 so
/// this is a stage-limited numerical port, not whole-image Float64 parity.
/// The original mobile approximation remains an explicit alternative.
enum SourceSpatialDIRConvolution {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let s) = self { return s }
            return nil
        }
    }

    static let mixture: [(Double, Double)] = [
        (0.1633, 0.5360), (0.6496, 1.5236), (0.1870, 2.7684)
    ]

    private static func requireValid(
        _ source: [Double], width: Int, height: Int, sigma: Double
    ) throws {
        guard width > 0, height > 0, width <= 8_192, height <= 8_192,
              width <= 32_000_000 / height,
              source.count == width * height * 3,
              sigma.isFinite, sigma >= 0,
              source.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("原版 FIR/YVV DIR 输入维度、sigma 或像素值无效")
        }
    }

    /// Same Numba _reflect as original: mode='reflect' replicates edge
    /// samples, unlike the other Hanatos LUT's whole-sample reflection.
    private static func reflect(_ index: Int, _ length: Int) -> Int {
        if index >= 0 && index < length { return index }
        let period = 2 * length
        let i = (index % period + period) % period
        return i >= length ? period - 1 - i : i
    }

    private static func weights(_ sigma: Double) -> [Double] {
        let radius=Int(3.0*sigma+0.5)
        let count=2*radius+1
        var weights=[Double](repeating:0,count:count)
        var total=0.0
        for i in 0..<count {
            let x=Double(i-radius)/sigma
            let value=exp(-0.5*x*x)
            weights[i]=value
            total+=value
        }
        for i in 0..<count { weights[i] /= total }
        return weights
    }

    /// Source: vertical FIR THEN horizontal FIR. 3 channels independently,
    /// with source mode='reflect' and truncate=3.0.
    private static func fir(
        _ input:[Double],width:Int,height:Int,sigma:Double
    ) -> [Double] {
        if sigma <= 0 { return input }
        let kernel=weights(sigma)
        let radius=(kernel.count-1)/2
        var vertical=[Double](repeating:0,count:input.count)
        var output=[Double](repeating:0,count:input.count)
        for y in 0..<height {
            for x in 0..<width {
                let p=(y*width+x)*3
                for k in -radius...radius {
                    let yy=reflect(y+k,height)
                    let q=(yy*width+x)*3
                    let w=kernel[k+radius]
                    for c in 0..<3 { vertical[p+c]+=input[q+c]*w }
                }
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let p=(y*width+x)*3
                for k in -radius...radius {
                    let xx=reflect(x+k,width)
                    let q=(y*width+xx)*3
                    let w=kernel[k+radius]
                    for c in 0..<3 { output[p+c]+=vertical[q+c]*w }
                }
            }
        }
        return output
    }

    /// Exactly the coefficient equations of the upstream source
    /// utils/fast_gaussian_filter.py::_yvv_coeffs (Young–van Vliet 2002).
    private static func yvvCoefficients(
        sigma:Double
    ) -> (Double,Double,Double,Double) {
        let q:Double
        if sigma >= 2.5 {
            q=0.98711*sigma-0.96330
        } else {
            q=3.97156-4.14554*sqrt(1.0-0.26891*sigma)
        }
        let q2=q*q, q3=q2*q
        let b0=1.57825+2.44413*q+1.4281*q2+0.422205*q3
        let b1=2.44413*q+2.85619*q2+1.26661*q3
        let b2 = -(1.4281*q2+1.26661*q3)
        let b3=0.422205*q3
        let B=1.0-(b1+b2+b3)/b0
        return (B,b1/b0,b2/b0,b3/b0)
    }

    /// Source horizontal pass and vertical pass, with sample-replication
    /// initial IIR state and in-place backward recurrence.
    private static func yvv(
        _ input:[Double],width:Int,height:Int,sigma:Double
    ) -> [Double] {
        if sigma <= 0 { return input }
        if sigma < 0.5 { return fir(input,width:width,height:height,sigma:sigma) }
        let (B,B1,B2,B3)=yvvCoefficients(sigma:sigma)
        var h=[Double](repeating:0,count:input.count)
        for y in 0..<height {
            for c in 0..<3 {
                var s1=input[(y*width)*3+c]
                var s2=s1, s3=s1
                for x in 0..<width {
                    let p=(y*width+x)*3+c
                    let w=B*input[p]+B1*s1+B2*s2+B3*s3
                    h[p]=w
                    s3=s2;s2=s1;s1=w
                }
                let p=(y*width+width-1)*3+c
                s1=h[p];s2=s1;s3=s1
                for x in stride(from:width-1,through:0,by:-1) {
                    let q=(y*width+x)*3+c
                    let w=B*h[q]+B1*s1+B2*s2+B3*s3
                    h[q]=w
                    s3=s2;s2=s1;s1=w
                }
            }
        }
        var output=[Double](repeating:0,count:input.count)
        for x in 0..<width {
            for c in 0..<3 {
                var s1=h[x*3+c]
                var s2=s1, s3=s1
                for y in 0..<height {
                    let p=(y*width+x)*3+c
                    let w=B*h[p]+B1*s1+B2*s2+B3*s3
                    output[p]=w
                    s3=s2;s2=s1;s1=w
                }
                let p=((height-1)*width+x)*3+c
                s1=output[p];s2=s1;s3=s1
                for y in stride(from:height-1,through:0,by:-1) {
                    let q=(y*width+x)*3+c
                    let w=B*output[q]+B1*s1+B2*s2+B3*s3
                    output[q]=w
                    s3=s2;s2=s1;s1=w
                }
            }
        }
        return output
    }

    static func gaussian(
        _ input:[Double],width:Int,height:Int,sigma:Double
    ) throws -> [Double] {
        try requireValid(input,width:width,height:height,sigma:sigma)
        // No arbitrary CI sigma clipping or source-kernel swap.
        return sigma < 3.0
            ? fir(input,width:width,height:height,sigma:sigma)
            : yvv(input,width:width,height:height,sigma:sigma)
    }

    /// Identical original source spatial DIR mixture:
    /// (1-w) * gaussian(inhibitors, coreSigma) +
    /// w * sum_k amplitude_k * gaussian(inhibitors, ratio_k*tailSigma)
    /// Result is in native log10-inhibitor units (not normalized CI cube).
    static func diffuse(
        _ input:[Double],width:Int,height:Int,
        coreSigma:Double,tailSigma:Double,tailWeight:Double
    ) throws -> [Double] {
        try requireValid(input,width:width,height:height,sigma:coreSigma)
        guard tailSigma.isFinite,tailSigma>=0,
              tailWeight.isFinite,(0...1).contains(tailWeight) else {
            throw Failure.invalid("原版 DIR 空间尾部扩散参数无效")
        }
        let core=try gaussian(input,width:width,height:height,sigma:coreSigma)
        if tailWeight==0 { return core }
        var out=core.map { $0*(1-tailWeight) }
        for (w,ratio) in mixture {
            let part=try gaussian(
                input,width:width,height:height,sigma:tailSigma*ratio
            )
            for i in out.indices { out[i]+=tailWeight*w*part[i] }
        }
        guard out.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("原版 DIR FIR/YVV 扩散结果包含 NaN/Inf")
        }
        return out
    }

    /// Convert the Core Image inhibitor buffer to Float32 RGBA only at
    /// the CI boundary. Perform all original FIR/YVV operations in Double
    /// before converting to Float32 CIImage; NO silent CoreImage fallback.
    static func diffuseCI(
        _ source:CIImage,coreSigma:Double,tailSigma:Double,
        tailWeight:Double
    ) throws -> CIImage {
        let rect=source.extent.integral
        let w=Int(rect.width),h=Int(rect.height)
        guard w>0,h>0,w<=8192,h<=8192,w<=32_000_000/h,
              rect==source.extent else {
            throw Failure.invalid("原版 DIR 仅支持像素对齐的有限尺寸图像")
        }
        let ctx=CIContext(options:[
            .workingColorSpace:NSNull(),
            .outputColorSpace:NSNull()
        ])
        var rgba=[Float](repeating:0,count:w*h*4)
        rgba.withUnsafeMutableBytes { raw in
            ctx.render(
                source,toBitmap:raw.baseAddress!,
                rowBytes:w*4*MemoryLayout<Float>.size,
                bounds:rect,format:.RGBAf,colorSpace:nil
            )
        }
        var rgb=[Double](repeating:0,count:w*h*3)
        for pixel in 0..<(w*h) {
            for c in 0..<3 { rgb[pixel*3+c]=Double(rgba[pixel*4+c]) }
        }
        let filtered=try diffuse(
            rgb,width:w,height:h,coreSigma:coreSigma,
            tailSigma:tailSigma,tailWeight:tailWeight
        )
        for pixel in 0..<(w*h) {
            for c in 0..<3 { rgba[pixel*4+c]=Float(filtered[pixel*3+c]) }
            rgba[pixel*4+3]=1
        }
        let bytes=rgba.withUnsafeBytes { Data($0) }
        let result=CIImage(
            bitmapData:bytes,bytesPerRow:w*4*MemoryLayout<Float>.size,
            size:CGSize(width:w,height:h),
            format:.RGBAf,colorSpace:nil
        )
        return result.transformed(
            by:CGAffineTransform(translationX:rect.minX,y:rect.minY)
        )
    }
}


// Native source-exact DIR route: avoid four cascading Core Image CIColorCube
// lookups, which were proven to introduce systematic source deviations at
// the *first* cube: 0.002156 in identity raw, growing to 0.004463 after
// four cubes. Original source FIR/YVV itself matched Float64 at 5.55e-16.
// Interpret the very same physical 3D LUT nodes in Double trilinear,
// retaining the film's real source LUT, not a test-only identity shortcut.
// This is a source-precision CPU path with Float32 CIImage boundary; it is
// distinct from the explicitly selected mobile CoreImage approximation.
extension SourceSpatialDIRConvolution {
    private struct SourceCube {
        let dimension:Int
        let samples:[Float]

        init(_ data:Data,dimension:Int) throws {
            guard dimension>=2,dimension<=256,
                  data.count==dimension*dimension*dimension*16 else {
                throw Failure.invalid("源 DIR 色彩 LUT 维度或 Float32 RGBA 长度无效")
            }
            self.dimension=dimension
            let bytes=[UInt8](data)
            var result=[Float](repeating:0,count:bytes.count/4)
            for i in result.indices {
                let o=i*4
                let bits=UInt32(bytes[o]) |
                    UInt32(bytes[o+1])<<8 |
                    UInt32(bytes[o+2])<<16 |
                    UInt32(bytes[o+3])<<24
                result[i]=Float(bitPattern:bits)
            }
            guard result.allSatisfy({ $0.isFinite }) else {
                throw Failure.invalid("源 DIR 光学 LUT 含 NaN/Inf")
            }
            samples=result
        }

        @inline(__always)
        private func at(_ r:Int,_ g:Int,_ b:Int,_ ch:Int)->Double {
            Double(samples[((b*dimension+g)*dimension+r)*4+ch])
        }

        /// Source cube arrangement: r-fastest, g-middle, b-slowest.
        /// Trilinear interpolates exact stored Float32 source nodes with
        /// Double weights, with no LUT 8-bit hardware texture quantization.
        @inline(__always)
        func rgb(_ r:Double,_ g:Double,_ b:Double)->(Double,Double,Double) {
            let maximum=Double(dimension-1)
            let xr=max(0,min(1,r))*maximum
            let xg=max(0,min(1,g))*maximum
            let xb=max(0,min(1,b))*maximum
            let lr=Int(xr),lg=Int(xg),lb=Int(xb)
            let hr=min(lr+1,dimension-1)
            let hg=min(lg+1,dimension-1)
            let hb=min(lb+1,dimension-1)
            let wr=xr-Double(lr),wg=xg-Double(lg),wb=xb-Double(lb)
            var output=(0.0,0.0,0.0)
            for ib in 0...1 {
                let bi=ib==0 ? lb : hb
                let bw=ib==0 ? 1-wb : wb
                for ig in 0...1 {
                    let gi=ig==0 ? lg : hg
                    let gw=ig==0 ? 1-wg : wg
                    for ir in 0...1 {
                        let ri=ir==0 ? lr : hr
                        let rw=ir==0 ? 1-wr : wr
                        let weight=rw*gw*bw
                        output.0+=weight*at(ri,gi,bi,0)
                        output.1+=weight*at(ri,gi,bi,1)
                        output.2+=weight*at(ri,gi,bi,2)
                    }
                }
            }
            return output
        }
    }

    private static func readRGB(
        _ input:CIImage,rect:CGRect,w:Int,h:Int
    ) throws -> [Double] {
        let context=CIContext(options:[
            .workingColorSpace:NSNull(),
            .outputColorSpace:NSNull()
        ])
        var rgba=[Float](repeating:0,count:w*h*4)
        rgba.withUnsafeMutableBytes { raw in
            context.render(input,toBitmap:raw.baseAddress!,
                           rowBytes:w*4*MemoryLayout<Float>.size,
                           bounds:rect,format:.RGBAf,colorSpace:nil)
        }
        var rgb=[Double](repeating:0,count:w*h*3)
        for p in 0..<(w*h) {
            // Optical-density processing is defined on opaque photographs,
            // not alpha-composited transparent layers.
            guard rgba[p*4+3].isFinite,
                  abs(rgba[p*4+3]-1)<0.00001 else {
                throw Failure.invalid("原版 DIR 需要不透明图像，检测到非 1 的 alpha")
            }
            for c in 0..<3 {
                let v=Double(rgba[p*4+c])
                guard v.isFinite else {
                    throw Failure.invalid("原版 DIR 输入 Float32 图像包含 NaN/Inf")
                }
                rgb[p*3+c]=v
            }
        }
        return rgb
    }

    private static func writeRGB(
        _ rgb:[Double],rect:CGRect,w:Int,h:Int
    ) throws -> CIImage {
        guard rgb.count==w*h*3,
              rgb.allSatisfy({ $0.isFinite && abs($0)<1.0e12 }) else {
            throw Failure.invalid("原版 DIR 输出三通道尺寸/非有限数值无效")
        }
        var rgba=[Float](repeating:1,count:w*h*4)
        for p in 0..<(w*h) {
            for c in 0..<3 { rgba[p*4+c]=Float(rgb[p*3+c]) }
        }
        let data=rgba.withUnsafeBytes { Data($0) }
        return CIImage(
            bitmapData:data,
            bytesPerRow:w*4*MemoryLayout<Float>.size,
            size:CGSize(width:w,height:h),
            format:.RGBAf,colorSpace:nil
        ).transformed(
            by:CGAffineTransform(translationX:rect.minX,y:rect.minY)
        )
    }

    /// Entire *production* source spatial DIR stage as a real 2D operation.
    /// No CIColorCube is used in this original-accuracy mode. Film RAW,
    /// initial H-D, spatial silver inhibition, corrected film density and
    /// print LUT follow exactly the same physical data as the fast renderer.
    /// Grain remains the separately chosen stochastic density stage.
    static func applyExactImagePath(
        to source:CIImage,stage:SpatialDIRStage,
        settings:SpatialDIRSettings,grain:DensityGrainSettings?,
        stageObserver:((String,CIImage)->Void)?,
        // Source pixel override is for Python diagnostic fixtures only.
        // The application still obtains CIImage pixels via readRGB().
        sourceRGBOverride:[Double]?=nil,
        stageDoubleObserver:((String,[Double])->Void)?=nil,
        // Direct ImageIO/JPEG experiment: prevent even a lazy final
        // CIImage RGB allocation when the upstream pixels are supplied
        // directly and the Double printed buffer has been observed.
        suppressFinalCIImage:Bool=false
    ) throws -> CIImage {
        let rect=source.extent.integral
        let w=Int(rect.width),h=Int(rect.height)
        guard rect==source.extent,
              w>0,h>0,w<=8192,h<=8192,
              w<=32_000_000/h,stage.valid,settings.valid else {
            throw Failure.invalid("原版 DIR 不支持非像素对齐/超尺寸图像")
        }
        let rawCube=try SourceCube(stage.rawLogCube,dimension:stage.sourceCubeSize)
        let initialCube=try SourceCube(
            stage.initialDensityCube,dimension:stage.sourceCubeSize
        )
        let correctedCube=try SourceCube(
            stage.correctedDensityCube,dimension:stage.correctedCubeSize
        )
        let printCube=try SourceCube(
            stage.printCube,dimension:stage.sourceCubeSize
        )
        let sourceRGB:[Double]
        if let direct=sourceRGBOverride {
            guard direct.count==w*h*3,
                  direct.allSatisfy({ $0.isFinite }) else {
                throw Failure.invalid("原版 DIR Float64 直连输入无效")
            }
            sourceRGB=direct
        } else {
            sourceRGB=try readRGB(source,rect:rect,w:w,h:h)
        }
        func observe(_ stageName:String,_ pixels:[Double]) throws {
            stageDoubleObserver?(stageName,pixels)
            if let stageObserver {
                stageObserver(stageName,try writeRGB(pixels,rect:rect,w:w,h:h))
            }
        }
        let count=w*h*3
        var raw=[Double](repeating:0,count:count)
        var inhibitors=[Double](repeating:0,count:count)
        var initialObserved=(stageObserver == nil && stageDoubleObserver == nil)
            ? [] : [Double](repeating:0,count:count)
        for p in 0..<(w*h) {
            let k=p*3
            let r=sourceRGB[k],g=sourceRGB[k+1],b=sourceRGB[k+2]
            let exposure=rawCube.rgb(r,g,b)
            raw[k]=exposure.0;raw[k+1]=exposure.1;raw[k+2]=exposure.2
            let initial=initialCube.rgb(r,g,b)
            if stageObserver != nil || stageDoubleObserver != nil {
                initialObserved[k]=initial.0
                initialObserved[k+1]=initial.1
                initialObserved[k+2]=initial.2
            }
            let d=[initial.0,initial.1,initial.2]
            for receiver in 0..<3 {
                var inhibition=0.0
                for donor in 0..<3 {
                    let actualDensity=d[donor]*stage.densityRanges[donor]
                    let silver=stage.positive
                        ? stage.densityMaximum[donor]-actualDensity
                        : actualDensity
                    inhibition+=silver*stage.donorReceiverMatrix[donor*3+receiver]
                }
                inhibitors[k+receiver]=inhibition
            }
        }
        try observe("raw",raw)
        try observe("initial",initialObserved)
        try observe("inhibitors",inhibitors)
        // Cast CoreGraphics CGFloat explicitly: Swift must not infer
        // optional CGFloat/Double cross-arithmetic for source microns.
        let longSide:Double=max(
            1.0,Double(source.extent.width),Double(source.extent.height)
        )
        let defaultPixelUM:Double=36_000.0/longSide
        let pixelUM:Double=settings.referencePixelSizeUM ?? defaultPixelUM
        let coreSigma=SpatialDIR.gaussianSigmaUM *
            settings.diffusionRadiusScale/pixelUM
        let tailSigma=SpatialDIR.exponentialTailUM *
            settings.diffusionRadiusScale/pixelUM
        let diffused=try diffuse(
            inhibitors,width:w,height:h,
            coreSigma:coreSigma,tailSigma:tailSigma,
            tailWeight:settings.tailWeight
        )
        try observe("diffused",diffused)
        var correctedLog=[Double](repeating:0,count:count)
        for k in 0..<count {
            let span=stage.logExposureSpans[k%3]
            correctedLog[k]=max(0,min(1,raw[k]-diffused[k]/span))
        }
        try observe("log",correctedLog)
        var density=[Double](repeating:0,count:count)
        for p in 0..<(w*h) {
            let k=p*3
            let d=correctedCube.rgb(
                correctedLog[k],correctedLog[k+1],correctedLog[k+2]
            )
            density[k]=d.0;density[k+1]=d.1;density[k+2]=d.2
        }
        try observe("densityPreGrain",density)
        if let grain,grain.amount>0 {
            let densityImage=try writeRGB(density,rect:rect,w:w,h:h)
            guard let result=try DensityGrain.perturbDensityImage(
                densityImage,settings:grain,pixelUM:pixelUM
            ) else {
                throw Failure.invalid("原版 DIR 的颗粒密度阶段失败，禁止跳过")
            }
            density=try readRGB(result,rect:rect,w:w,h:h)
        }
        var printed=[Double](repeating:0,count:count)
        for p in 0..<(w*h) {
            let k=p*3
            let color=printCube.rgb(density[k],density[k+1],density[k+2])
            printed[k]=color.0;printed[k+1]=color.1;printed[k+2]=color.2
        }
        try observe("printed",printed)
        if suppressFinalCIImage {
            guard sourceRGBOverride != nil,stageDoubleObserver != nil,
                  stageObserver == nil,grain == nil else {
                throw Failure.invalid(
                    "禁止在未取得 Double 印相数组时省略 CIImage 输出"
                )
            }
            // Caller consumes the Double printed pixels from the observer.
            // Return ONLY the original geometry. It is never rendered.
            return source
        }
        return try writeRGB(printed,rect:rect,w:w,h:h)
    }
}
