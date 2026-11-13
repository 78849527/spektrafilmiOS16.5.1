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
        let b2=-(1.4281*q2+1.26661*q3)
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
        guard let result=CIImage(
            bitmapData:bytes,bytesPerRow:w*4*MemoryLayout<Float>.size,
            size:CGSize(width:w,height:h),
            format:.RGBAf,colorSpace:nil
        ) as CIImage? else {
            throw Failure.invalid("原版 DIR 扩散 Float32 Core Image 写入失败")
        }
        return result.transformed(
            by:CGAffineTransform(translationX:rect.minX,y:rect.minY)
        )
    }
}
