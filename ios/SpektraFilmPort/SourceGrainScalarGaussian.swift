import Foundation

/// Build116: source-exact full-frame ONE-channel Gaussian for dye clouds.
/// No crop, tiling, Float32 path or changed reflect boundary conditions.
/// Same original FIR (vertical then horizontal) and Young-van Vliet IIR
/// (horizontal then vertical) as SourceSpatialDIRConvolution.
enum SourceGrainScalarGaussian {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let reason)=self {return reason}
            return nil
        }
    }

    private static func reflect(_ index:Int,_ length:Int)->Int {
        if index >= 0 && index < length {return index}
        let period=2*length
        let i=(index % period + period) % period
        return i >= length ? period - 1 - i : i
    }

    private static func weights(_ sigma:Double)->[Double] {
        let radius=Int(3.0*sigma+0.5)
        let count=2*radius+1
        var kernel=[Double](repeating:0,count:count)
        var total=0.0
        for i in 0..<count {
            let x=Double(i-radius)/sigma
            let value=exp(-0.5*x*x)
            kernel[i]=value
            total+=value
        }
        for i in 0..<count {kernel[i]/=total}
        return kernel
    }

    private static func yvvCoefficients(
        sigma:Double
    )->(Double,Double,Double,Double) {
        let q:Double
        if sigma>=2.5 {
            q=0.98711*sigma-0.96330
        } else {
            q=3.97156-4.14554*sqrt(1.0-0.26891*sigma)
        }
        let q2=q*q,q3=q2*q
        let b0=1.57825+2.44413*q+1.4281*q2+0.422205*q3
        let b1=2.44413*q+2.85619*q2+1.26661*q3
        let b2 = -(1.4281*q2+1.26661*q3)
        let b3=0.422205*q3
        let B=1.0-(b1+b2+b3)/b0
        return (B,b1/b0,b2/b0,b3/b0)
    }

    /// Replace one scalar image in place. Peak scratch is ONE Double/px,
    /// rather than a 3-channel input, 3-channel result and two other planes.
    /// Never quantize or change source full-frame boundary conditions.
    static func blurInPlace(
        _ input:inout [Double],width:Int,height:Int,sigma:Double
    ) throws {
        var intermediate=[Double]()
        try blurInPlace(&input,width:width,height:height,sigma:sigma,
                        intermediate:&intermediate)
    }

    /// One render may reuse this private scratch plane for all nine layers.
    /// Each FIR/YVV first pass overwrites every element before any read.
    /// No cached kernel output, cross-render state or spatial approximation.
    static func blurInPlace(
        _ input:inout [Double],width:Int,height:Int,sigma:Double,
        intermediate:inout [Double]
    ) throws {
        guard width>0,height>0,width<=8192,height<=8192,
              width<=32_000_000/height,
              input.count==width*height,
              sigma.isFinite,sigma>=0,
              input.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版单通道染料云 FIR/YVV 尺寸、sigma 或 Float64 数据无效")
        }
        if sigma<=0 {return}
        let pixels=width*height
        if intermediate.count != pixels {
            intermediate=[Double](repeating:0,count:pixels)
        }
        if sigma<3.0 {
            // Exact Python source order: reflect FIR vertical, horizontal.
            let kernel=weights(sigma)
            let radius=(kernel.count-1)/2
            for y in 0..<height {
                for x in 0..<width {
                    var sum=0.0
                    for k in -radius...radius {
                        let yy=reflect(y+k,height)
                        sum+=input[yy*width+x]*kernel[k+radius]
                    }
                    intermediate[y*width+x]=sum
                }
            }
            // All original input samples are now consumed.
            for y in 0..<height {
                for x in 0..<width {
                    var sum=0.0
                    for k in -radius...radius {
                        let xx=reflect(x+k,width)
                        sum+=intermediate[y*width+xx]*kernel[k+radius]
                    }
                    input[y*width+x]=sum
                }
            }
        } else {
            // Exact original YVV recurrence, full-frame edge initial state.
            let (B,B1,B2,B3)=yvvCoefficients(sigma:sigma)
            for y in 0..<height {
                var s1=input[y*width]
                var s2=s1,s3=s1
                for x in 0..<width {
                    let p=y*width+x
                    let v=B*input[p]+B1*s1+B2*s2+B3*s3
                    intermediate[p]=v
                    s3=s2;s2=s1;s1=v
                }
                let last=y*width+width-1
                s1=intermediate[last];s2=s1;s3=s1
                for x in stride(from:width-1,through:0,by:-1) {
                    let p=y*width+x
                    let v=B*intermediate[p]+B1*s1+B2*s2+B3*s3
                    intermediate[p]=v
                    s3=s2;s2=s1;s1=v
                }
            }
            for x in 0..<width {
                var s1=intermediate[x]
                var s2=s1,s3=s1
                for y in 0..<height {
                    let p=y*width+x
                    let v=B*intermediate[p]+B1*s1+B2*s2+B3*s3
                    input[p]=v
                    s3=s2;s2=s1;s1=v
                }
                let last=(height-1)*width+x
                s1=input[last];s2=s1;s3=s1
                for y in stride(from:height-1,through:0,by:-1) {
                    let p=y*width+x
                    let v=B*input[p]+B1*s1+B2*s2+B3*s3
                    input[p]=v
                    s3=s2;s2=s1;s1=v
                }
            }
        }
        guard input.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版单通道染料云 FIR/YVV 输出出现 NaN/Inf")
        }
    }
}
