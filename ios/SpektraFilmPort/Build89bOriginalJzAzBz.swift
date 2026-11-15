import Foundation

/// Exact original Spektrafilm source JzAzBz output gamut (Safdar 2017),
/// using original colour-science 0.4.6 matrices and their NumPy inverses.
/// Explicit SDR white = 100 cd/m², ST2084 m2=1.7*(2523/32) PQ,
/// 64×720 original Cmax(Jz,h) with 18 source inverse-PQ RGB cube
/// bisections, plus original one-sided Jz lightness and Reinhard knee.
/// CPU Float64 per pixel. No baked 3D LUT / no fallback to ACES.
enum Build89bOriginalJzAzBz {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self{return s}
            return nil
        }
    }
    private static let lock=NSLock()
    private static var cmax=[String:[Int:Double]]()

    private static let B=1.15
    private static let G=0.66
    private static let D = -0.56
    private static let D0 = 1.6295499532821566e-11
    private static let m1 = (2610.0/4096.0)*0.25
    private static let m2 = 1.7*2523.0/32.0
    private static let c1 = 3424.0/4096.0
    private static let c2 = (2413.0/4096.0)*32.0
    private static let c3 = (2392.0/4096.0)*32.0

    private static func spow(_ x:Double,_ exp:Double)->Double {
        x < 0 ? -pow(-x,exp) : pow(x,exp)
    }
    private static func matvec(_ m:[Double],_ xyz:[Double])->[Double] {
        (0..<3).map{out in
            (0..<3).reduce(0.0){sum,input in
                sum+m[out*3+input]*xyz[input]
            }
        }
    }
    private static func mul(_ vector:[Double],_ m:[Double])->[Double] {
        (0..<3).map{out in
            (0..<3).reduce(0.0){sum,input in
                sum+vector[input]*m[input*3+out]
            }
        }
    }
    private static func pqForward(_ cd:Double)->Double {
        // colour.eotf_inverse_ST2084 in domain_range_scale("ignore"):
        // it accepts signed inputs via colour.algebra.spow.
        let lp=spow(cd/10000.0,m1)
        return spow((c1+c2*lp)/(c3*lp+1.0),m2)
    }
    private static func pqInverse(_ encoded:Double)->Double {
        let vp=spow(encoded,1.0/m2)
        let numerator=max(0.0,vp-c1)
        return 10000.0*spow(numerator/(c2-c3*vp),1.0/m1)
    }

    /// Source colour.XYZ_to_Jzazbz absolute XYZ(cd/m²)→JzAzBz.
    static func forward(_ xyz:[Double]) throws->[Double] {
        guard xyz.count==3,xyz.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 JzAzBz 需要 3 通道绝对亮度 XYZ")
        }
        let Xp=B*xyz[0]-(B-1)*xyz[2]
        let Yp=G*xyz[1]-(G-1)*xyz[0]
        let sharpened=[Xp,Yp,xyz[2]]
        let cone=matvec(
            GeneratedScannerReference.sourceJzXYZToLMS,sharpened
        )
        let encoded=cone.map{pqForward($0)}
        let iz=matvec(GeneratedScannerReference.sourceJzLMSToIz,encoded)
        let Jz=((1+D)*iz[0])/(1+D*iz[0])-D0
        let out=[Jz,iz[1],iz[2]]
        guard out.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "原版 JzAzBz absolute PQ 在此输入无定义，不允许降级"
            )
        }
        return out
    }

    /// Source colour.Jzazbz_to_XYZ→absolute cd/m².
    static func inverse(_ jzab:[Double]) throws->[Double] {
        guard jzab.count==3,jzab.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 JzAzBz 感知坐标无效")
        }
        let iz=(jzab[0]+D0)/
            (1+D-D*(jzab[0]+D0))
        let lmsEncoded=matvec(
            GeneratedScannerReference.sourceJzIzToLMS,
            [iz,jzab[1],jzab[2]]
        )
        let lms=lmsEncoded.map{pqInverse($0)}
        let adjusted=matvec(
            GeneratedScannerReference.sourceJzLMSToXYZ,lms
        )
        let X=(adjusted[0]+(B-1)*adjusted[2])/B
        let Y=(adjusted[1]+(G-1)*X)/G
        let xyz=[X,Y,adjusted[2]]
        guard xyz.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "原版 JzAzBz PQ 反演非有限，禁止近似回退"
            )
        }
        return xyz
    }

    /// Source lookup table source _get_output_c_max_table("jzazbz"):
    /// 64 lightness nodes 0.002..0.18; 720 hues [-π,π);
    /// 18 bisections upper Cz=0.3, [-1e-6,1+1e-6] RGB cube.
    private static func cmaxNode(
        Li:Int,hi:Int,space:String,xyzToRGB:[Double]
    )throws->Double {
        let key=Li*720+hi
        lock.lock()
        let cached=cmax[space]?[key]
        lock.unlock()
        if let cached{return cached}
        let L=0.002+(0.18-0.002)*Double(Li)/63.0
        let h = -Double.pi+2*Double.pi*Double(hi)/720.0
        let cx=cos(h),cy=sin(h)
        var low=0.0,high=0.3
        for _ in 0..<18 {
            let mid=(low+high)*0.5
            let inCube:Bool
            do {
                let absXYZ=try inverse([
                    L,mid*cx,mid*cy
                ])
                let relative=absXYZ.map{$0/100.0}
                let rgb=mul(relative,xyzToRGB)
                inCube=rgb.allSatisfy{
                    $0.isFinite && $0>=(-1e-6) && $0<=1.0+1e-6
                }
            } catch {
                inCube=false
            }
            if inCube {low=mid} else {high=mid}
        }
        lock.lock()
        var nodes=cmax[space] ?? [:]
        nodes[key]=low
        cmax[space]=nodes
        lock.unlock()
        return low
    }

    private static func cmaxLookup(
        light:Double,h:Double,space:String,x2r:[Double]
    )throws->Double {
        let clamped=max(0.002,min(0.18,light))
        let grid=(clamped-0.002)/(0.18-0.002)*63
        let l0=max(0,min(62,Int(floor(grid))))
        let lf=grid-Double(l0)
        let hs=(h+Double.pi)/(2*Double.pi)*720.0
        let hv=floor(hs)
        let h0=((Int(hv)%720)+720)%720
        let h1=(h0+1)%720
        let hf=hs-hv
        let p00=try cmaxNode(Li:l0,hi:h0,space:space,xyzToRGB:x2r)
        let p01=try cmaxNode(Li:l0,hi:h1,space:space,xyzToRGB:x2r)
        let p10=try cmaxNode(Li:l0+1,hi:h0,space:space,xyzToRGB:x2r)
        let p11=try cmaxNode(Li:l0+1,hi:h1,space:space,xyzToRGB:x2r)
        return p00*(1-lf)*(1-hf)+p01*(1-lf)*hf +
               p10*lf*(1-hf)+p11*lf*hf
    }

    static func compress(
        _ rgb:[Double],space:String,
        knee:Build89OriginalOutputGamut.Knee,
        lightness:Build89OriginalOutputGamut.Knee?
    )throws->[Double] {
        try knee.validate()
        try lightness?.validate()
        guard rgb.count==3,rgb.allSatisfy({$0.isFinite}),
              let r2x=GeneratedScannerReference.sourceOutputRGBToXYZ[space],
              let x2r=GeneratedScannerReference.sourceOutputXYZToRGB[space],
              let white=GeneratedScannerReference.sourceOutputWhiteXYZ[space]
        else {
            throw Failure.invalid(
                "JzAzBz 缺失精确原版目标 RGB 空间矩阵或白点"
            )
        }
        let xyz=mul(rgb,r2x).map{$0*100.0}
        let jz=try forward(xyz)
        var L=jz[0]
        if let lightness {
            // Original source _jzazbz_white_Jz uses absolute 100 cd/m².
            let whiteJz=try forward(white.map{$0*100.0})[0]
            L=Build89OriginalOutputGamut.sourceKnee(
                L/whiteJz,lightness
            )*whiteJz
        }
        let c=hypot(jz[1],jz[2])
        let h=atan2(jz[2],jz[1])
        let cmaxValue=max(
            1e-9,try cmaxLookup(light:L,h:h,space:space,x2r:x2r)
        )
        let d=c/cmaxValue
        let reduced=Build89OriginalOutputGamut.sourceKnee(
            d,knee
        )*cmaxValue
        let inverseXYZ=try inverse([
            L,reduced*cos(h),reduced*sin(h)
        ])
        let output=mul(inverseXYZ.map{$0/100.0},x2r)
        guard output.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 JzAzBz 输出非有限")
        }
        return output
    }
}
