import Foundation

/// Literal Float64 port of Python model.diffusion.apply_diffusion_filter_um:
/// four original PSF families, warmth redistribution, reflect padding,
/// and FFT convolution (radix-2 Double). Never use CI / Float32 fallback.
enum OriginalSourceDiffusion {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let s) = self { return s }; return nil
        }
    }
    enum Family: String, CaseIterable, Hashable {
        case glimmerglass
        case blackProMist = "black_pro_mist"
        case proMist = "pro_mist"
        case cinebloom
    }
    struct Settings {
        var active = false
        var family: Family = .blackProMist
        var strength = 0.5
        var spatialScale = 1.0
        var haloWarmth = 0.0
        var coreIntensity = 1.0
        var coreSize = 1.0
        var haloIntensity = 1.0
        var haloSize = 1.0
        var bloomIntensity = 1.0
        var bloomSize = 1.0
        func validate() throws {
            let all = [strength, spatialScale, haloWarmth, coreIntensity,
                       coreSize, haloIntensity, haloSize, bloomIntensity,
                       bloomSize]
            // Python accepts arbitrary finite scalar strengths and group
            // overrides; do not invent unsupported fixed mutual locks or
            // arbitrary upper bounds. Source math clips/blends itself.
            guard all.allSatisfy({ $0.isFinite }) else {
                throw Failure.invalid("原版扩散滤镜含非有限参数，禁止近似降级")
            }
        }
    }
    private struct Group {
        let center: Double
        let spread: Double
        let count: Int
        let alpha: Double
    }
    private struct Shape {
        let core: Group
        let halo: Group
        let bloom: Group
        let wc: Double
        let wh: Double
        let wb: Double
        let baseWarmth: Double
        let totalGain: Double
    }
    private static func shape(_ family: Family) -> Shape {
        switch family {
        case .glimmerglass:
            return Shape(core: .init(center:10,spread:1.5,count:2,alpha:3),
                         halo:.init(center:50,spread:2,count:3,alpha:3),
                         bloom:.init(center:260,spread:2.5,count:4,alpha:3.2),
                         wc:0.60,wh:0.30,wb:0.10,baseWarmth:0,totalGain:0.65)
        case .blackProMist:
            return Shape(core: .init(center:16,spread:1.5,count:2,alpha:3),
                         halo:.init(center:95,spread:2,count:3,alpha:3),
                         bloom:.init(center:380,spread:2.5,count:4,alpha:3.5),
                         wc:0.40,wh:0.47,wb:0.13,baseWarmth:0.65,totalGain:0.75)
        case .proMist:
            return Shape(core: .init(center:14,spread:1.5,count:2,alpha:3),
                         halo:.init(center:150,spread:2,count:3,alpha:3),
                         bloom:.init(center:650,spread:2.5,count:4,alpha:2.9),
                         wc:0.28,wh:0.42,wb:0.30,baseWarmth:0.40,totalGain:1.05)
        case .cinebloom:
            return Shape(core: .init(center:20,spread:1.5,count:2,alpha:3),
                         halo:.init(center:200,spread:2,count:3,alpha:3),
                         bloom:.init(center:1000,spread:2.5,count:4,alpha:2.5),
                         wc:0.22,wh:0.30,wb:0.48,baseWarmth:0.85,totalGain:1)
        }
    }
    static func scatterFraction(_ s: Settings) -> Double {
        if s.strength <= 0 { return 0 }
        let x = log2(max(s.strength,1e-6))
        let bp = [0.125,0.25,0.5,1.0,2.0].map(log2)
        let fr = [0.10,0.20,0.35,0.55,0.75]
        var raw = fr[0]
        if x >= bp[4] { raw = fr[4] }
        else if x > bp[0] {
            for j in 0..<4 where x >= bp[j] && x <= bp[j+1] {
                raw = fr[j] + (fr[j+1]-fr[j])*(x-bp[j])/(bp[j+1]-bp[j])
                break
            }
        }
        return max(0,min(0.99,raw*shape(s.family).totalGain))
    }
    private static func expanded(_ group: Group, size: Double,
                                 bloom: Bool) -> (scales:[Double],weights:[Double]) {
        let center = group.center * max(size,1e-6)
        let a=log(center/group.spread), b=log(center*group.spread)
        let scales=(0..<group.count).map { j in
            exp(a+(b-a)*Double(j)/Double(group.count-1))
        }
        var weights=scales.map { bloom ? pow($0,2-group.alpha) : 1.0 }
        let sum=weights.reduce(0,+)
        for j in weights.indices { weights[j]/=sum }
        return (scales,weights)
    }
    private static func haloWeights(_ weights:[Double],warmth:Double,
                                    channel:Int) -> [Double] {
        let n=weights.count
        if n < 2 { return weights }
        let g=(0..<n).map { -1.0+2.0*Double($0)/Double(n-1) }
        let weightedMean=zip(g,weights).reduce(0.0) { $0+$1.0*$1.1 }
        let axis=[1.30,0.15,-1.45][channel]
        let clampedWarmth=max(-1.5,min(1.5,warmth))
        var updated=zip(g,weights).map { grad,weight in
            max(0,weight*(1+clampedWarmth*axis*(grad-weightedMean)))
        }
        let total=updated.reduce(0,+)
        if total<=0 { return weights }
        let target=weights.reduce(0,+)
        for i in updated.indices { updated[i] *= target/total }
        return updated
    }
    private static func groupWeights(_ s: Settings,_ sh: Shape) -> [Double] {
        let c=sh.wc*max(s.coreIntensity,0)
        let h=sh.wh*max(s.haloIntensity,0)
        let b=sh.wb*max(s.bloomIntensity,0)
        let sum=c+h+b
        if sum<=0 { return [sh.wc,sh.wh,sh.wb] }
        return [c/sum,h/sum,b/sum]
    }
    static func radius(width:Int,height:Int,pixelUM:Double,
                       settings:Settings) throws -> Int {
        try settings.validate()
        guard width>=3,height>=3, pixelUM.isFinite,pixelUM>0 else {
            throw Failure.invalid("原版扩散 PSF 需要有效像素尺寸与至少 3×3 的图像")
        }
        let sh=shape(settings.family)
        let lambdaMax=sh.bloom.center*max(settings.bloomSize,1e-6) *
                      sh.bloom.spread*settings.spatialScale/pixelUM
        guard lambdaMax.isFinite,lambdaMax>=0,
              lambdaMax < Double(Int.max)/16 else {
            throw Failure.invalid("原版扩散 PSF 半径溢出；禁止回退近似滤波")
        }
        let uncapped=Int(ceil(max(8*lambdaMax,5)))
        return min(uncapped,max(min(width,height)/2-1,1))
    }
    /// Returns interleaved RGB channel-specific PSF of width/height 2r+1.
    static func psf(width:Int,height:Int,pixelUM:Double,
                    settings:Settings) throws -> (radius:Int,data:[Double]) {
        let r=try radius(width:width,height:height,pixelUM:pixelUM,settings:settings)
        let sh=shape(settings.family)
        let cw=groupWeights(settings,sh)
        let core=expanded(sh.core,size:settings.coreSize,bloom:false)
        let halo=expanded(sh.halo,size:settings.haloSize,bloom:false)
        let bloom=expanded(sh.bloom,size:settings.bloomSize,bloom:true)
        let warmth=sh.baseWarmth+settings.haloWarmth
        let haloChannel=(0..<3).map { haloWeights(halo.weights,warmth:warmth,channel:$0) }
        let n=2*r+1
        var grid=[Double](repeating:0,count:n*n*3)
        var sums=[Double](repeating:0,count:3)
        for y in 0..<n {
            for x in 0..<n {
                let radial=hypot(Double(x-r),Double(y-r))
                let base=(y*n+x)*3
                func radialSum(_ scales:[Double],_ weights:[Double]) -> Double {
                    var value=0.0
                    for j in scales.indices {
                        let lambda=max(scales[j]*settings.spatialScale/pixelUM,1e-6)
                        value += weights[j] * exp(-radial/lambda) /
                                 (2*Double.pi*lambda*lambda)
                    }
                    return value
                }
                let c=cw[0]*radialSum(core.scales,core.weights)
                let b=cw[2]*radialSum(bloom.scales,bloom.weights)
                for channel in 0..<3 {
                    let h=cw[1]*radialSum(halo.scales,haloChannel[channel])
                    grid[base+channel]=c+h+b
                    sums[channel]+=grid[base+channel]
                }
            }
        }
        guard sums.allSatisfy({$0.isFinite && $0>0}) else {
            throw Failure.invalid("原版扩散 PSF 能量归一化失败")
        }
        for k in 0..<(n*n) {
            for c in 0..<3 { grid[k*3+c]/=sums[c] }
        }
        return (r,grid)
    }
    private static func pow2(_ n:Int) throws -> Int {
        guard n>0,n<=32768 else {
            throw Failure.invalid("原版扩散 FFT 尺寸超出安全上限，禁止降低精度")
        }
        var k=1
        while k<n { k*=2 }
        return k
    }
    private static func fft1(_ real:inout [Double],_ imag:inout [Double],
                             inverse:Bool) {
        let n=real.count
        var j=0
        for i in 1..<n {
            var bit=n>>1
            while j&bit != 0 { j^=bit; bit>>=1 }
            j^=bit
            if i<j {
                real.swapAt(i,j); imag.swapAt(i,j)
            }
        }
        var len=2
        while len<=n {
            let a=(inverse ? 2.0 : -2.0)*Double.pi/Double(len)
            let wr=cos(a),wi=sin(a)
            for first in stride(from:0,to:n,by:len) {
                var ur=1.0,ui=0.0
                for k in 0..<(len>>1) {
                    let left=first+k,right=left+(len>>1)
                    let tr=real[right]*ur-imag[right]*ui
                    let ti=real[right]*ui+imag[right]*ur
                    real[right]=real[left]-tr
                    imag[right]=imag[left]-ti
                    real[left]+=tr;imag[left]+=ti
                    let nextR=ur*wr-ui*wi
                    ui=ur*wi+ui*wr;ur=nextR
                }
            }
            len*=2
        }
        if inverse {
            let scale=1.0/Double(n)
            for k in real.indices { real[k]*=scale;imag[k]*=scale }
        }
    }
    private static func fft2(_ real:inout [Double],_ imag:inout [Double],
                             width:Int,height:Int,inverse:Bool) {
        for y in 0..<height {
            var re=Array(real[y*width..<(y+1)*width])
            var im=Array(imag[y*width..<(y+1)*width])
            fft1(&re,&im,inverse:inverse)
            for x in 0..<width { real[y*width+x]=re[x];imag[y*width+x]=im[x] }
        }
        for x in 0..<width {
            var re=(0..<height).map { real[$0*width+x] }
            var im=(0..<height).map { imag[$0*width+x] }
            fft1(&re,&im,inverse:inverse)
            for y in 0..<height { real[y*width+x]=re[y];imag[y*width+x]=im[y] }
        }
    }
    private static func reflect(_ pos:Int,dimension:Int) -> Int {
        if pos<0 { return -pos }
        if pos>=dimension { return 2*dimension-2-pos }
        return pos
    }
    static func apply(_ rgb:[Double],width:Int,height:Int,
                      pixelUM:Double,settings:Settings) throws -> [Double] {
        try settings.validate()
        guard width>0,height>0,width<=Int.max/height/3,
              rgb.count==width*height*3,
              rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版扩散滤镜需要完整、有限的 Double RGB 光子帧")
        }
        if !settings.active || settings.strength<=0 || settings.spatialScale<=0 {
            return rgb
        }
        let fraction=scatterFraction(settings)
        if fraction<=0 { return rgb }
        // Preflight FFT workspace BEFORE allocating any large PSF.
        let r=try radius(width:width,height:height,
                         pixelUM:pixelUM,settings:settings)
        let ks=2*r+1
        let paddedW=width+2*r,paddedH=height+2*r
        let fftW=try pow2(paddedW+ks-1)
        let fftH=try pow2(paddedH+ks-1)
        let grid=fftW*fftH
        // Two Double complex FFT planes plus full-frame output and
        // scratch headroom, without shortening the original PSF.
        let estimated=UInt64(grid)*UInt64(8)*UInt64(5) +
                      UInt64(rgb.count)*UInt64(8)*UInt64(2)
        guard estimated<=UInt64(512_000_000) else {
            throw Failure.invalid("原版扩散滤镜需要超过 512 MB Float64 FFT 缓冲；无法精确执行，不自动降级或截断 PSF")
        }
        let kernel=try psf(width:width,height:height,
                           pixelUM:pixelUM,settings:settings)
        var output=[Double](repeating:0,count:rgb.count)
        for c in 0..<3 {
            var ar=[Double](repeating:0,count:grid)
            var ai=[Double](repeating:0,count:grid)
            var br=[Double](repeating:0,count:grid)
            var bi=[Double](repeating:0,count:grid)
            for y in 0..<paddedH {
                let sy=reflect(y-r,dimension:height)
                for x in 0..<paddedW {
                    let sx=reflect(x-r,dimension:width)
                    ar[y*fftW+x]=rgb[(sy*width+sx)*3+c]
                }
            }
            for y in 0..<ks {
                for x in 0..<ks {
                    br[y*fftW+x]=kernel.data[(y*ks+x)*3+c]
                }
            }
            fft2(&ar,&ai,width:fftW,height:fftH,inverse:false)
            fft2(&br,&bi,width:fftW,height:fftH,inverse:false)
            for i in 0..<grid {
                let rr=ar[i]*br[i]-ai[i]*bi[i]
                let ii=ar[i]*bi[i]+ai[i]*br[i]
                ar[i]=rr; ai[i]=ii
            }
            fft2(&ar,&ai,width:fftW,height:fftH,inverse:true)
            for y in 0..<height {
                for x in 0..<width {
                    let k=(y*width+x)*3+c
                    let blurred=ar[(y+2*r)*fftW+(x+2*r)]
                    output[k]=(1-fraction)*rgb[k]+fraction*blurred
                }
            }
        }
        guard output.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版扩散滤镜 FFT 输出包含 Inf/NaN")
        }
        return output
    }
}
