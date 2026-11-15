import Foundation

/// Spektrafilm Python original gamut_compression.py:
/// compress_rgb_oklch_chroma / compress_rgb_oklrab_chroma.
///
/// Native CPU Float64 per pixel, Colour v0.4.6 EXACT original Oklab
/// matrices (generated at build from colour.models.oklab.py), signed
/// cube root, 64×720 Cmax(L,h) with 18 inverse-Oklab RGB cube bisections,
/// plus original bilinear table lookup, normalized Reinhard knee and
/// optional one-sided lightness compression.  This is NOT the former 33³
/// CIColorCube LUT nor an approximation implemented via Core Image.
enum Build89bOriginalOklabGamut {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self{return s}
            return nil
        }
    }
    private static let lock=NSLock()
    private static var table=[String:[Int:Double]]()

    private static func mul(_ rgb:[Double],_ matrix:[Double])->[Double] {
        (0..<3).map {out in
            (0..<3).reduce(0.0) {sum,input in
                sum+rgb[input]*matrix[input*3+out]
            }
        }
    }
    private static func matvec(_ matrix:[Double],_ xyz:[Double])->[Double] {
        (0..<3).map {out in
            (0..<3).reduce(0.0) {sum,input in
                sum+matrix[out*3+input]*xyz[input]
            }
        }
    }
    private static func signedCubeRoot(_ value:Double)->Double {
        value<0 ? -pow(-value,1.0/3.0) : pow(value,1.0/3.0)
    }
    static func xyzToOklab(_ xyz:[Double]) throws->[Double] {
        guard xyz.count==3,xyz.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Oklab XYZ 三通道必须为有限 Float64")
        }
        let lms=matvec(
            GeneratedScannerReference.sourceOklabXYZToLMS,xyz
        ).map{signedCubeRoot($0)}
        let lab=matvec(
            GeneratedScannerReference.sourceOklabLMSToLAB,lms
        )
        guard lab.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 XYZ_to_Oklab 产生非有限值")
        }
        return lab
    }
    static func oklabToXYZ(_ lab:[Double]) throws->[Double] {
        guard lab.count==3,lab.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 Oklab L,a,b 无效")
        }
        let lms=matvec(
            GeneratedScannerReference.sourceOklabLABToLMS,lab
        ).map{$0*$0*$0}
        let xyz=matvec(
            GeneratedScannerReference.sourceOklabLMSToXYZ,lms
        )
        guard xyz.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 Oklab_to_XYZ 产生非有限值")
        }
        return xyz
    }

    /// Original _oklab_L_to_oklrab_Lr and its inverse, Ottosson 2023.
    private static let k1=0.206
    private static let k2=0.03
    private static let k3=(1.0+0.206)/(1.0+0.03)
    static func oklabToOklrabLr(_ L:Double)->Double {
        let t=k3*L-k1
        return 0.5*(t+sqrt(t*t+4*k2*k3*L))
    }
    static func oklrabLrToOklab(_ Lr:Double)->Double {
        Lr*(Lr+k1)/(k3*(Lr+k2))
    }

    /// Exactly source _build_polar_perceptual_c_max_table:
    /// 64 L values linspace 0.02..1, 720 hues [-π,π), 18 bisections,
    /// maximum chroma 0.5; in gamut (-1e-6 ... 1+1e-6) inclusive.
    private static func cmaxNode(
        Li:Int,hi:Int,space:String,rebased:Bool,
        xyzToRGB:[Double]
    ) throws->Double {
        let label=(rebased ? "oklrab:":"oklch:")+space
        let key=Li*720+hi
        lock.lock()
        let current=table[label]?[key]
        lock.unlock()
        if let current{return current}
        let coord=0.02+0.98*Double(Li)/63.0
        let L=rebased ? oklrabLrToOklab(coord) : coord
        let h = -Double.pi+2*Double.pi*Double(hi)/720.0
        let x=cos(h),y=sin(h)
        var low=0.0,high=0.5
        for _ in 0..<18 {
            let mid=0.5*(low+high)
            let xyz=try oklabToXYZ([L,mid*x,mid*y])
            let rgb=mul(xyz,xyzToRGB)
            let inCube=rgb.allSatisfy {
                $0.isFinite && $0 >= -1e-6 && $0 <= 1.0+1e-6
            }
            if inCube{low=mid}else{high=mid}
        }
        lock.lock()
        var cache=table[label] ?? [:]
        cache[key]=low
        table[label]=cache
        lock.unlock()
        return low
    }

    private static func cmaxLookup(
        _ L:Double,_ h:Double,space:String,rebased:Bool,
        xyzToRGB:[Double]
    ) throws->Double {
        let position=max(0.02,min(1.0,L))
        let Li=(position-0.02)/0.98*63
        let l0=max(0,min(62,Int(floor(Li))))
        let lf=Li-Double(l0)
        let hx=(h+Double.pi)/(2.0*Double.pi)*720.0
        let hs=floor(hx)
        let h0=((Int(hs)%720)+720)%720
        let h1=(h0+1)%720
        let hf=hx-hs
        let v00=try cmaxNode(
            Li:l0,hi:h0,space:space,rebased:rebased,xyzToRGB:xyzToRGB
        )
        let v01=try cmaxNode(
            Li:l0,hi:h1,space:space,rebased:rebased,xyzToRGB:xyzToRGB
        )
        let v10=try cmaxNode(
            Li:l0+1,hi:h0,space:space,rebased:rebased,xyzToRGB:xyzToRGB
        )
        let v11=try cmaxNode(
            Li:l0+1,hi:h1,space:space,rebased:rebased,xyzToRGB:xyzToRGB
        )
        return v00*(1-lf)*(1-hf)+v01*(1-lf)*hf +
               v10*lf*(1-hf)+v11*lf*hf
    }

    static func compress(
        _ rgb:[Double],space:String,rebased:Bool,
        knee:Build89OriginalOutputGamut.Knee,
        lightness:Build89OriginalOutputGamut.Knee?
    ) throws->[Double] {
        try knee.validate()
        try lightness?.validate()
        guard rgb.count==3,rgb.allSatisfy({$0.isFinite}),
              let r2x=GeneratedScannerReference.sourceOutputRGBToXYZ[space],
              let x2r=GeneratedScannerReference.sourceOutputXYZToRGB[space]
        else {
            throw Failure.invalid(
                "Oklch／Oklrab 输入需要原版源 RGB↔XYZ Float64"
            )
        }
        let xyz=mul(rgb,r2x)
        let lab=try xyzToOklab(xyz)
        var L=lab[0]
        if let lightness {
            // Original _compress_lightness lightness knee operates on
            // L (NOT rebased Lr), normalized by Oklab white L=1.
            L=Build89OriginalOutputGamut.sourceKnee(L,lightness)
        }
        let Lcoord=rebased ? oklabToOklrabLr(L) : L
        guard Lcoord.isFinite else {
            throw Failure.invalid(
                "原版 Oklrab L→Lr 对该负亮度输入无定义，拒绝 ACES 降级"
            )
        }
        let C=hypot(lab[1],lab[2])
        let h=atan2(lab[2],lab[1])
        let cmax=max(1e-9,try cmaxLookup(
            Lcoord,h,space:space,rebased:rebased,xyzToRGB:x2r
        ))
        let fraction=C/cmax
        let newFraction=Build89OriginalOutputGamut.sourceKnee(
            fraction,knee
        )
        let compressedC=newFraction*cmax
        let xyzOut=try oklabToXYZ([
            L,compressedC*cos(h),compressedC*sin(h)
        ])
        let output=mul(xyzOut,x2r)
        guard output.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版 Oklch／Oklrab 转换返回非有限 RGB")
        }
        return output
    }
}
