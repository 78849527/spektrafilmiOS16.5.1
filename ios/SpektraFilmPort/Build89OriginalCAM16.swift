import Foundation

/// Build89 true per-pixel, source-order CAM16-UCS (Li & Luo 2017),
/// not the old 33^3 Float32 LUT. Ported from colour-science 0.4.6
/// CAM16 appearance model under source gamut_compression.py conditions:
/// XYZw=destination white at Y=1, L_A=64, Y_b=20,
/// average surround F=1, c=0.69, Nc=1, 64x720 Cmax, 18 bisections.
///
/// Cmax nodes are evaluated LAZILY with the original inverse CAM16
/// bisection and cached by (output RGB space,L_i,h_i). Unlike a
/// 33³ RGB lookup, *each pixel* executes the actual forward/inverse
/// CAM16 equations; only Cmax(L,h) has the original bilinear lookup.
/// No replacement with ACES when CAM16 yields an invalid result.
enum Build89OriginalCAM16 {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self{return s}
            return nil
        }
    }

    struct Appearance {
        let jp:Double
        let ap:Double
        let bp:Double
    }
    private struct Context {
        let white:[Double]
        let rgbToXYZ:[Double]
        let xyzToRGB:[Double]
        let adaptedWhite:[Double]
        let D:[Double]
        let fl:Double
        let n:Double
        let nbb:Double
        let z:Double
        let aw:Double
        let jWhite:Double
    }
    private static let matrix16:[Double]=[
        0.401288,0.650173,-0.051461,
        -0.250268,1.204414,0.045854,
        -0.002079,0.048952,0.953127
    ]
    private static let matrix16Inv:[Double]=[
        1.862067855087233,-1.011254630531684,0.149186775444451,
        0.387526543236137,0.621447441931475,-0.008973985167612,
        -0.015841498849334,-0.034122938028515,1.049964436877849
    ]
    private static let lock=NSLock()
    private static var cmaxCache=[String:[Int:Double]]()

    private static func mul(_ vector:[Double],_ matrix:[Double])->[Double] {
        (0..<3).map{out in
            (0..<3).reduce(0.0){sum,input in
                sum+vector[input]*matrix[input*3+out]
            }
        }
    }
    private static func matvec(_ matrix:[Double],_ vector:[Double])->[Double] {
        (0..<3).map{out in
            (0..<3).reduce(0.0){sum,input in
                sum+matrix[out*3+input]*vector[input]
            }
        }
    }
    private static func spow(_ value:Double,_ power:Double)->Double {
        if value==0{return 0}
        return (value<0 ? -1.0:1.0)*pow(abs(value),power)
    }
    private static func respond(_ adapted:Double,_ fl:Double)->Double {
        let t=pow(fl*abs(adapted)/100.0,0.42)
        return 400.0*(adapted<0 ? -1.0:1.0)*t/(27.13+t)+0.1
    }
    private static func undo(_ response:Double,_ fl:Double)->Double {
        let r=response-0.1
        let t=27.13*abs(r)/(400.0-abs(r))
        return (r<0 ? -1.0:1.0)*100.0/fl*spow(t,1.0/0.42)
    }
    private static func achromatic(_ rgb:[Double],_ nbb:Double)->Double {
        (2*rgb[0]+rgb[1]+rgb[2]/20.0-0.305)*nbb
    }
    private static func environment(_ space:String)throws->Context {
        guard let white=GeneratedScannerReference.sourceOutputWhiteXYZ[space],
              let rgb2xyz=GeneratedScannerReference.sourceOutputRGBToXYZ[space],
              let xyz2rgb=GeneratedScannerReference.sourceOutputXYZToRGB[space],
              white.count==3,rgb2xyz.count==9,xyz2rgb.count==9,
              white.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "Build89 该输出 RGB 色域缺少原版 colour-science Float64 " +
                "矩阵与自适应白点，精确模式禁止猜测或回退 ACES"
            )
        }
        let flAdapt=64.0
        // colour.appearance.ciecam02.luminance_level_adaptation_factor
        let k=1.0/(5.0*flAdapt+1.0)
        let fl=0.2*pow(k,4)*(5*flAdapt) +
               0.1*pow(1-pow(k,4),2)*cbrt(5*flAdapt)
        let n=20.0/100.0
        let nbb=0.725*pow(1.0/n,0.2)
        let z=1.48+sqrt(n)
        let adapt=max(0.0,min(1.0,1.0-(1.0/3.6)*exp((-flAdapt-42)/92)))
        let white100=white.map{$0*100.0}
        let rgbw=matvec(matrix16,white100)
        let d=(0..<3).map {ch in
            adapt*100.0/rgbw[ch]+1.0-adapt
        }
        let rgbaw=(0..<3).map{ch in respond(rgbw[ch]*d[ch],fl)}
        let aw=achromatic(rgbaw,nbb)
        let ctx=Context(
            white:white,rgbToXYZ:rgb2xyz,xyzToRGB:xyz2rgb,
            adaptedWhite:rgbaw,D:d,fl:fl,n:n,
            nbb:nbb,z:z,aw:aw,jWhite:100.0
        )
        let wp=try forwardXYZ(white,context:ctx)
        return Context(
            white:white,rgbToXYZ:rgb2xyz,xyzToRGB:xyz2rgb,
            adaptedWhite:rgbaw,D:d,fl:fl,n:n,
            nbb:nbb,z:z,aw:aw,jWhite:wp.jp
        )
    }

    private static func forwardXYZ(
        _ xyz:[Double],context c:Context
    ) throws->Appearance {
        let sharpened=matvec(matrix16,xyz.map{$0*100.0})
        let adapted=(0..<3).map{ch in
            respond(sharpened[ch]*c.D[ch],c.fl)
        }
        let a=adapted[0]-12*adapted[1]/11+adapted[2]/11
        let b=(adapted[0]+adapted[1]-2*adapted[2])/9.0
        let h=atan2(b,a)
        let et=0.25*(cos(2+h)+3.8)
        let A=achromatic(adapted,c.nbb)
        let J=100.0*spow(A/c.aw,0.69*c.z)
        let numerator=(50000.0/13.0)*c.nbb*et*hypot(a,b)
        let denominator=adapted[0]+adapted[1]+21*adapted[2]/20.0
        let t=denominator==0 ? 0.0:numerator/denominator
        let C=spow(t,0.9)*spow(J/100.0,0.5)*
              pow(1.64-pow(0.29,c.n),0.73)
        let M=C*pow(c.fl,0.25)
        // Li2017 CAM16-UCS c1=.007 c2=.0228
        let jp=1.7*J/(1.0+0.007*J)
        let mp=log1p(0.0228*M)/0.0228
        let result=Appearance(jp:jp,ap:mp*cos(h),bp:mp*sin(h))
        guard [result.jp,result.ap,result.bp].allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "CAM16-UCS 原版遇到不可定义的光谱／色域输入；" +
                "不能自动改用 33³ LUT 或 ACES"
            )
        }
        return result
    }

    private static func inverseXYZ(
        _ appearance:Appearance,context c:Context
    ) throws->[Double] {
        let jp=appearance.jp
        let mp=hypot(appearance.ap,appearance.bp)
        let h=atan2(appearance.bp,appearance.ap)
        let J=jp/(1.7-0.007*jp)
        let M=expm1(0.0228*mp)/0.0228
        let C=M/pow(c.fl,0.25)
        let effectiveJ=max(J,Double.ulpOfOne)
        let chromaScale=sqrt(effectiveJ/100)*
            pow(1.64-pow(0.29,c.n),0.73)
        let t=spow(C/chromaScale,1/0.9)
        let et=0.25*(cos(2+h)+3.8)
        let A=c.aw*spow(J/100,1/(0.69*c.z))
        let p2=A/c.nbb+0.305
        let p3=21.0/20.0
        var a=0.0,b=0.0
        if t != 0 {
            let p1=(50000.0/13.0)*c.nbb*et/t
            let n=p2*(2+p3)*(460.0/1403.0)
            let sinH=sin(h),cosH=cos(h)
            if abs(sinH)>=abs(cosH) {
                let ratio=cosH/sinH
                b=n/(p1/sinH+(2+p3)*(220.0/1403.0)*ratio -
                     27.0/1403.0+p3*(6300.0/1403.0))
                a=b*ratio
            } else {
                let ratio=sinH/cosH
                a=n/(p1/cosH+(2+p3)*(220.0/1403.0) -
                     (27.0/1403.0-p3*(6300.0/1403.0))*ratio)
                b=a*ratio
            }
        }
        let ar=[
            (460*p2+451*a+288*b)/1403,
            (460*p2-891*a-261*b)/1403,
            (460*p2-220*a-6300*b)/1403
        ]
        let uncompressed=(0..<3).map{ch in
            undo(ar[ch],c.fl)/c.D[ch]
        }
        let xyz=matvec(matrix16Inv,uncompressed).map{$0/100.0}
        guard xyz.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 CAM16-UCS 反演 XYZ 非有限")
        }
        return xyz
    }

    /// Independently exposed stage probes for original Python comparison.
    static func forward(_ rgb:[Double],space:String="sRGB") throws->Appearance {
        guard rgb.count==3,rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("CAM16 精确 RGB 输入值无效")
        }
        let c=try environment(space)
        return try forwardXYZ(mul(rgb,c.rgbToXYZ),context:c)
    }

    static func inverse(
        _ appearance:Appearance,space:String="sRGB"
    ) throws->[Double] {
        let c=try environment(space)
        return mul(try inverseXYZ(appearance,context:c),c.xyzToRGB)
    }

    /// Source _get_output_c_max_table computes a 64x720 18-bisect
    /// table. Computing nodes lazily and caching the same nodes preserves
    /// the exact mathematical table, without a giant Float32 RGB cube.
    private static func sourceCMax(
        LIndex:Int,hIndex:Int,space:String,context c:Context
    ) throws->Double {
        let key=LIndex*720+hIndex
        lock.lock()
        let cached=cmaxCache[space]?[key]
        lock.unlock()
        if let cached {return cached}
        let L=1.0+(110.0-1.0)*Double(LIndex)/63.0
        let h = -Double.pi + 2.0*Double.pi*Double(hIndex)/720.0
        var low=0.0,high=150.0
        for _ in 0..<18 {
            let mid=0.5*(low+high)
            let probe=Appearance(
                jp:L,ap:mid*cos(h),bp:mid*sin(h)
            )
            let inside:Bool
            do {
                let xyz=try inverseXYZ(probe,context:c)
                let rgb=mul(xyz,c.xyzToRGB)
                inside=rgb.allSatisfy {
                    $0.isFinite && $0 >= -1e-6 && $0 <= 1.0+1e-6
                }
            } catch {
                // The source's np.all((rgb>=-1e-6)&(rgb<=1+1e-6))
                // treats nonfinite inverse-CAM16 probes as OUTSIDE.
                inside=false
            }
            if inside {low=mid} else {high=mid}
        }
        lock.lock()
        var table=cmaxCache[space] ?? [:]
        table[key]=low
        cmaxCache[space]=table
        lock.unlock()
        return low
    }

    private static func sourceCMaxLookup(
        Jp:Double,h:Double,space:String,context c:Context
    ) throws->Double {
        let L=max(1.0,min(110.0,Jp))
        let lIdx=(L-1.0)/(110.0-1.0)*63.0
        let lo=min(62,max(0,Int(floor(lIdx))))
        let lf=lIdx-Double(lo)
        let scaled=(h+Double.pi)/(2*Double.pi)*720.0
        let hf=scaled-floor(scaled)
        let h0=((Int(floor(scaled))%720)+720)%720
        let h1=(h0+1)%720
        let v00=try sourceCMax(LIndex:lo,hIndex:h0,space:space,context:c)
        let v01=try sourceCMax(LIndex:lo,hIndex:h1,space:space,context:c)
        let v10=try sourceCMax(LIndex:lo+1,hIndex:h0,space:space,context:c)
        let v11=try sourceCMax(LIndex:lo+1,hIndex:h1,space:space,context:c)
        return v00*(1-lf)*(1-hf)+v01*(1-lf)*hf +
               v10*lf*(1-hf)+v11*lf*hf
    }

    static func sourceKnee(_ v:Double,settings:(Double,Double,Double))->Double {
        let (threshold,limit,power)=settings
        guard v>threshold else{return v}
        let scale=limit-threshold
        let x=(v-threshold)/scale
        return threshold+scale*x/pow(1.0+pow(x,power),1.0/power)
    }

    static func compress(
        _ rgb:[Double],space:String="sRGB",
        knee:(Double,Double,Double)=(0,1,6),
        lightness:(Double,Double,Double)?=(0.7,1,2.2)
    ) throws->[Double] {
        guard rgb.count==3,rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("CAM16 源逐像素 Float64 输入无效")
        }
        let c=try environment(space)
        let j=try forwardXYZ(mul(rgb,c.rgbToXYZ),context:c)
        var jp=j.jp
        if let lightness {
            jp=sourceKnee(jp/c.jWhite,settings:lightness)*c.jWhite
        }
        let cp=hypot(j.ap,j.bp)
        let h=atan2(j.bp,j.ap)
        let cmax=max(
            1e-9,try sourceCMaxLookup(Jp:jp,h:h,space:space,context:c)
        )
        let normalized=cp/cmax
        let compressed=sourceKnee(normalized,settings:knee)*cmax
        let xyz=try inverseXYZ(
            Appearance(jp:jp,ap:compressed*cos(h),
                       bp:compressed*sin(h)),
            context:c
        )
        let output=mul(xyz,c.xyzToRGB)
        guard output.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "原版 CAM16 逐像素输出非有限；禁止静默替换为 ACES"
            )
        }
        return output
    }
}