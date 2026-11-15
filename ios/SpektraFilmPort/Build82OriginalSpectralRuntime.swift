import Foundation
import CryptoKit
import Darwin

/// Build82/17-18 original 81-wavelength Hanatos TC LUT recomputation.
///
/// Source irradiance is read from the *original* 192x192x81 NumPy F16
/// .npy binary, promoted to CPU Double exactly as Python np.double(np.load).
/// Applies the upstream spectral Gaussian (SciPy reflect), 4-param erf
/// source adaptation window, illuminant-normalized UV/IR camera filter,
/// source polynomial exposure surface, then default xy gamut LUT remap.
///
/// No CIColorCube or existing UNFILTERED film LUT is allowed as a fallback.
enum Build82OriginalSpectralRuntime {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let s)=self {return s}
            return nil
        }
    }
    typealias Point=Build82OriginalHanatosSurface.Point
    struct Profile {
        let stock:String
        let reference:String
        let referenceXY:Point
        let illuminant:[Double]   // source wavelength axis [380..780;5]
        let sensitivity:[Double]  // row-major 81*3; original 10**log values
        let window:[Double]       // source erf4 [c_uv,sigma_uv,c_ir,sigma_ir]
        let surface:[[Double]]    // source poly4, 3*15
    }
    struct Grid {
        let side:Int
        let sourceSHA:String
        let values:[Double] // original NumPy (192,192,81), Float16 promoted
        func spectrum(x:Int,y:Int,lambda:Int)->Double {
            values[(x*side+y)*81+lambda]
        }
    }

    private static func decodeHalf(_ bits:UInt16)->Double {
        let sign=(bits & 0x8000)==0 ? 1.0 : -1.0
        let exponent=Int((bits>>10)&0x1f)
        let fraction=Int(bits & 0x03ff)
        if exponent==0 {return sign*Double(fraction)*pow(2,-24.0)}
        if exponent==31 {
            return fraction==0 ? sign*Double.infinity : Double.nan
        }
        return sign*Double(1024+fraction)*pow(2,Double(exponent-25))
    }

    static func loadOriginalNPY(_ url:URL,expectedSide:Int=192)
        throws -> Grid {
        let data=try Data(contentsOf:url,options:.mappedIfSafe)
        let digest=SHA256.hash(data:data).map {
            String(format:"%02x",$0)
        }.joined()
        guard digest==Build82GeneratedHanatosProfiles.sourceSHA256 else {
            throw Failure.invalid("Hanatos 原版光谱文件 SHA256 不匹配")
        }
        let bytes=[UInt8](data)
        guard bytes.count>12,
              Array(bytes[0..<6])==[0x93,78,85,77,80,89],
              bytes[6]==1,bytes[7]==0 else {
            throw Failure.invalid("Hanatos 原版光谱 npy 需 NumPy v1.0 F16")
        }
        let length=Int(bytes[8]) | (Int(bytes[9])<<8)
        guard 10+length<=bytes.count,
              let header=String(bytes:bytes[10..<(10+length)],
                                encoding:.ascii),
              header.contains("'descr': '<f2'") ||
                  header.contains("\"descr\": \"<f2\""),
              header.contains("'fortran_order': False") ||
                  header.contains("\"fortran_order\": false") else {
            throw Failure.invalid("Hanatos npy shape/dtype/字节序不匹配原版")
        }
        let pattern="\\(([0-9]+),\\s*([0-9]+),\\s*([0-9]+)\\)"
        let regex=try NSRegularExpression(pattern:pattern)
        let ns=header as NSString
        guard let match=regex.firstMatch(
                in:header,range:NSRange(location:0,length:ns.length)),
              match.numberOfRanges==4 else {
            throw Failure.invalid("Hanatos npy 维度头信息不合法")
        }
        let sizes=(1...3).compactMap {
            Int(ns.substring(with:match.range(at:$0)))
        }
        guard sizes.count==3,sizes[0]==expectedSide,
              sizes[1]==expectedSide,sizes[2]==81,
              expectedSide>0,expectedSide<=512 else {
            throw Failure.invalid("Hanatos npy 必须原版 192×192×81")
        }
        let start=10+length
        let count=expectedSide*expectedSide*81
        guard start+count*2==bytes.count else {
            throw Failure.invalid("Hanatos npy 二进制长度不一致")
        }
        var values=[Double](repeating:0,count:count)
        for i in 0..<count {
            let at=start+2*i
            values[i]=decodeHalf(
                UInt16(bytes[at]) | (UInt16(bytes[at+1])<<8)
            )
        }
        guard values.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Hanatos 原始光谱包含 NaN/Inf")
        }
        return Grid(side:expectedSide,
                    sourceSHA:digest,
                    values:values)
    }

    private static func reflect(_ k:Int,count:Int)->Int {
        if count<=1 {return 0}
        // SciPy ndimage 'reflect': d c b a | a b c d | d c b a
        let period=2*count
        let wrapped=((k%period)+period)%period
        return wrapped<count ? wrapped : period-1-wrapped
    }

    static func spectralGaussian(_ values:[Double],sigma:Double)
        throws -> [Double] {
        guard values.count==81,sigma.isFinite,sigma>=0,sigma<=50 else {
            throw Failure.invalid("Hanatos 原版光谱 Gaussian sigma 无效")
        }
        if sigma==0 {return values}
        let radius=Int(4.0*sigma+0.5)
        let w=(-radius...radius).map {
            exp(-0.5*pow(Double($0)/sigma,2))
        }
        let mass=w.reduce(0,+)
        let weights=w.map {$0/mass}
        return (0..<81).map {index in
            var v=0.0
            for j in -radius...radius {
                v+=weights[j+radius]*values[reflect(index+j,count:81)]
            }
            return v
        }
    }

    static func originalERF4Window(_ params:[Double])
        throws -> [Double] {
        guard params.count==4,params.allSatisfy({$0.isFinite}),
              params[1]>0,params[3]>0 else {
            throw Failure.invalid("Hanatos 原版窗口仅认证 erf4 四参数")
        }
        return (0..<81).map {i in
            let wl=Double(380+5*i)
            let uv=0.5*(1+Darwin.erf(
                (wl-params[0])/(params[1]*sqrt(2.0))
            ))
            let ir=0.5*(1-Darwin.erf(
                (wl-params[2])/(params[3]*sqrt(2.0))
            ))
            return uv*ir
        }
    }

    /// Original source spectral-lut compute. For nondefault adaptation
    /// or arbitrary UV/IR, rebuild the film TC response instead of quietly
    /// using GeneratedHanatosPreciseData (which has no source surface/filter).
    static func make(
        profile:Profile,grid:Grid,
        filter:OriginalSourceCameraBandpass.Settings = .init(),
        spectralGaussianBlur:Double=0,
        applyWindow:Bool=true,
        applySurface:Bool=true,
        compressInputXY:Bool=true
    ) throws -> [Double] {
        try filter.validate()
        guard grid.values.count==grid.side*grid.side*81,
              grid.side==192,
              profile.sensitivity.count==243,
              profile.illuminant.count==81,
              profile.surface.count==3,
              profile.surface.allSatisfy({$0.count==15}),
              profile.sensitivity.allSatisfy({$0.isFinite}),
              profile.illuminant.allSatisfy({$0.isFinite}),
              spectralGaussianBlur.isFinite,
              spectralGaussianBlur>=0,spectralGaussianBlur<=50 else {
            throw Failure.invalid("Hanatos 原版 81 波长/3 层输入参数不完整")
        }
        let count=grid.side
        let window=try applyWindow ? originalERF4Window(profile.window)
            : [Double](repeating:1,count:81)
        let camera=(0..<81).map {i in
            OriginalSourceCameraBandpass.transmission(
                wavelengthNM:Double(380+5*i),settings:filter
            )
        }
        var filtered=[Double](repeating:0,count:243)
        for c in 0..<3 {
            var before=0.0,after=0.0
            // Source camera filter is normalized against stock's reference
            // illuminant before any Hanatos window normalization.
            for wl in 0..<81 {
                let source=profile.sensitivity[wl*3+c]
                    * profile.illuminant[wl]
                before+=source
                after+=source*camera[wl]
            }
            guard before>0,after>0,before.isFinite,after.isFinite else {
                throw Failure.invalid("Hanatos UV/IR 原版白点归一化失败")
            }
            let cameraNorm=after/before
            var windowBefore=0.0,windowAfter=0.0
            for wl in 0..<81 {
                let source=profile.sensitivity[wl*3+c]*
                    camera[wl]/cameraNorm*profile.illuminant[wl]
                windowBefore+=source
                windowAfter+=source*window[wl]
            }
            guard windowBefore>0,windowAfter>0 else {
                throw Failure.invalid("Hanatos window 原版通道归一化失败")
            }
            let windowNorm=windowAfter/windowBefore
            for wl in 0..<81 {
                filtered[wl*3+c] =
                    profile.sensitivity[wl*3+c]*camera[wl]/cameraNorm*
                    window[wl]/windowNorm
            }
        }
        // Source contraction: einsum('ijl,lm->ijm', spectra_lut,
        // sensitivity*window), followed by raw_lut *= 2**surface.
        var output=[Double](repeating:0,count:count*count*3)
        for x in 0..<count {
            for y in 0..<count {
                let tc=Point(x:Double(x)/Double(count-1),
                             y:Double(y)/Double(count-1))
                let start=(x*count+y)*81
                let spectrum:[Double]
                if spectralGaussianBlur>0 {
                    spectrum=try spectralGaussian(
                        Array(grid.values[start..<(start+81)]),
                        sigma:spectralGaussianBlur
                    )
                } else {
                    spectrum=Array(grid.values[start..<(start+81)])
                }
                for ch in 0..<3 {
                    var value=0.0
                    for wl in 0..<81 {
                        value+=spectrum[wl]*filtered[wl*3+ch]
                    }
                    if applySurface {
                        value *= try Build82OriginalHanatosSurface.gain(
                            tc:tc,channel:ch,params:profile.surface,
                            referenceXY:profile.referenceXY,model:.poly4
                        )
                    }
                    output[(x*count+y)*3+ch]=value
                }
            }
        }
        if compressInputXY {
            output=try bakeOriginalXYGamut(
                output,side:count,referenceXY:profile.referenceXY
            )
        }
        guard output.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Hanatos 动态光谱 LUT 非有限；拒绝旧 LUT 降级")
        }
        return output
    }

    /// Source gamut_compression.remap_tc_lut_for_compression:
    /// TC -> CIE xy -> default Reinhard radial xy -> TC -> bilinear nearest.
    static func bakeOriginalXYGamut(
        _ original:[Double],side:Int,referenceXY:Point
    ) throws -> [Double] {
        guard side>1,original.count==side*side*3 else {
            throw Failure.invalid("Hanatos 输入 gamut 源 LUT 维度错误")
        }
        var result=[Double](repeating:0,count:original.count)
        let white=Build81OriginalInputGamut.Point(
            x:referenceXY.x,y:referenceXY.y
        )
        for i in 0..<side {
            for j in 0..<side {
                let tc=Point(x:Double(i)/Double(side-1),
                             y:Double(j)/Double(side-1))
                let xy=Build82OriginalHanatosSurface.quad2tri(tc)
                let mapped=try Build81OriginalInputGamut
                    .compressUsingOriginalSpectralLocus(
                        [.init(x:xy.x,y:xy.y)],white:white
                    )[0]
                let compressed=Build82OriginalHanatosSurface.tri2quad(
                    Point(x:mapped.x,y:mapped.y)
                )
                let ix=min(Double(side-1),max(0,compressed.x*Double(side-1)))
                let iy=min(Double(side-1),max(0,compressed.y*Double(side-1)))
                let x0=Int(floor(ix)),y0=Int(floor(iy))
                let x1=min(side-1,x0+1),y1=min(side-1,y0+1)
                let fx=ix-Double(x0),fy=iy-Double(y0)
                for ch in 0..<3 {
                    let a=original[(x0*side+y0)*3+ch]
                    let b=original[(x0*side+y1)*3+ch]
                    let c=original[(x1*side+y0)*3+ch]
                    let d=original[(x1*side+y1)*3+ch]
                    result[(i*side+j)*3+ch]=
                        (a*(1-fy)+b*fy)*(1-fx)
                        +(c*(1-fy)+d*fy)*fx
                }
            }
        }
        return result
    }
}
