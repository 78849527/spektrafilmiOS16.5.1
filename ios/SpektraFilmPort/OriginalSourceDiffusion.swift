import Foundation
#if canImport(Accelerate)
import Accelerate
#endif
#if os(iOS)
import os
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    /// Python _resolve_family_cfg drops ALL user group multipliers,
    /// including size overrides, if the three intensities sum to zero.
    /// That fallback is shared by both kernel radius and per-pixel PSF.
    private static func sourceDefaultGroupGeometry(_ s:Settings) -> Bool {
        let sh=shape(s.family)
        let core:Double=sh.wc*max(s.coreIntensity,0.0)
        let halo:Double=sh.wh*max(s.haloIntensity,0.0)
        let bloom:Double=sh.wb*max(s.bloomIntensity,0.0)
        return (core+halo+bloom)<=0.0
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
        // Original NumPy reflect pads 1x1 / 1xN / 2xN source images as
        // well. The previous ≥3 restriction silently removed branches.
        guard width>=1,height>=1,pixelUM.isFinite,pixelUM>0 else {
            throw Failure.invalid("原版扩散 PSF 需要有效图像与像素尺寸")
        }
        let sh=shape(settings.family)
        let bloomSize=sourceDefaultGroupGeometry(settings)
            ? 1.0 : settings.bloomSize
        let lambdaMax=sh.bloom.center*max(bloomSize,1e-6) *
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
        let geometryDefaults=sourceDefaultGroupGeometry(settings)
        let core=expanded(
            sh.core,size:geometryDefaults ? 1 : settings.coreSize,
            bloom:false
        )
        let halo=expanded(
            sh.halo,size:geometryDefaults ? 1 : settings.haloSize,
            bloom:false
        )
        let bloom=expanded(
            sh.bloom,size:geometryDefaults ? 1 : settings.bloomSize,
            bloom:true
        )
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
                        let lambda=max(
                            scales[j]*max(settings.spatialScale,1e-6)/pixelUM,
                            1e-6
                        )
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
    // OPT-07: deterministic PSF preparation cache only. No optical image,
    // RNG state or developed density survives a render. All numeric settings
    // use IEEE-754 bit patterns, not approximate equality.
    struct PSFKey: Equatable {
        let family: Family
        let active: Bool
        let width: Int
        let height: Int
        let values: [UInt64]

        init(width:Int,height:Int,pixelUM:Double,settings:Settings) {
            self.family=settings.family
            self.active=settings.active
            self.width=width
            self.height=height
            self.values=[
                pixelUM,settings.strength,settings.spatialScale,settings.haloWarmth,
                settings.coreIntensity,settings.coreSize,settings.haloIntensity,
                settings.haloSize,settings.bloomIntensity,settings.bloomSize
            ].map { $0.bitPattern }
        }
    }

    private final class PSFCache {
        typealias Kernel = (radius:Int,data:[Double])
        private let lock=NSLock()
        private var entry:(key:PSFKey,kernel:Kernel)?
        private var generation:UInt64=0
        private let maximumBytes=1024*1024

        func lookup(_ key:PSFKey) -> (kernel:Kernel?,generation:UInt64) {
            lock.lock()
            defer {lock.unlock()}
            return (entry?.key==key ? entry?.kernel : nil,generation)
        }

        func store(_ key:PSFKey,kernel:Kernel,generation expected:UInt64) {
            lock.lock()
            defer {lock.unlock()}
            guard expected==generation,!Task.isCancelled,
                  kernel.data.count<=maximumBytes/MemoryLayout<Double>.stride else {return}
            entry=(key,kernel)
        }

        func clear() {
            lock.lock()
            defer {lock.unlock()}
            generation &+= 1
            entry=nil
        }
    }

    private static let psfCache=PSFCache()
    static func clearPreparedPSFCache() { psfCache.clear() }

    static func preparedPSF(width:Int,height:Int,pixelUM:Double,
                            settings:Settings) throws -> (radius:Int,data:[Double]) {
        try Task.checkCancellation()
        try settings.validate()
        let key=PSFKey(width:width,height:height,pixelUM:pixelUM,settings:settings)
        let cached=psfCache.lookup(key)
        if let kernel=cached.kernel {return kernel}
        let kernel=try psf(width:width,height:height,pixelUM:pixelUM,settings:settings)
        try Task.checkCancellation()
        psfCache.store(key,kernel:kernel,generation:cached.generation)
        return kernel
    }

    private static func pow2(_ n:Int) throws -> Int {
        guard n>0,n<=32768 else {
            throw Failure.invalid("原版扩散 FFT 尺寸超出安全上限，禁止降低精度")
        }
        var k=1
        while k<n { k*=2 }
        return k
    }
    private static func fft1Frozen(_ real:inout [Double],_ imag:inout [Double],
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
    private static func fft1(_ real:inout [Double],_ imag:inout [Double],
                             inverse:Bool) {
        let n=real.count
        precondition(n==imag.count && n>=1 && n.nonzeroBitCount==1)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                let real=rp.baseAddress!,imag=ip.baseAddress!
        var j=0
        for i in 1..<n {
            var bit=n>>1
            while j&bit != 0 { j^=bit; bit>>=1 }
            j^=bit
            if i<j {
                let r=real[i],v=imag[i]
                real[i]=real[j];imag[i]=imag[j]
                real[j]=r;imag[j]=v
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
            for k in 0..<n { real[k]*=scale;imag[k]*=scale }
        }
            }
        }
    }
    // Test the exact 1D production butterfly against its frozen pre-151
    // operation sequence, in both directions with signed and mixed inputs.
    static func verifyExactButterfly() {
        for n in [1,2,4,8,32,128,512,2048,8192,32768] {
            for inverse in [false,true] {
                var r=(0..<n).map{Double(($0*37+13)%997)/313.0-1.0}
                var i=(0..<n).map{Double(($0*19+17)%499)/251.0-1.0}
                r[0] = -0.0;i[0] = 0.0
                var rr=r,ii=i
                fft1Frozen(&rr,&ii,inverse:inverse)
                fft1(&r,&i,inverse:inverse)
                precondition(r.map{$0.bitPattern}==rr.map{$0.bitPattern} &&
                    i.map{$0.bitPattern}==ii.map{$0.bitPattern},
                    "Build151 Double FFT butterfly differs")
            }
        }
    }
    private static func fft2(_ real:inout [Double],_ imag:inout [Double],
                             width:Int,height:Int,inverse:Bool) {
        // Build91 CPU Double: keep one pair of row scratch arrays and one
        // pair of column scratch arrays for the WHOLE FFT2 invocation.
        // Historical code allocated fresh heap arrays for every row and
        // every column (and for each of three RGB channels).
        // The one-dimensional butterfly ORDER remains bit-for-bit the
        // same: rows then columns, original fft1 untouched.
        var rowReal=[Double](repeating:0,count:width)
        var rowImag=[Double](repeating:0,count:width)
        for y in 0..<height {
            let origin=y*width
            for x in 0..<width {
                rowReal[x]=real[origin+x]
                rowImag[x]=imag[origin+x]
            }
            fft1(&rowReal,&rowImag,inverse:inverse)
            for x in 0..<width {
                real[origin+x]=rowReal[x]
                imag[origin+x]=rowImag[x]
            }
        }
        var colReal=[Double](repeating:0,count:height)
        var colImag=[Double](repeating:0,count:height)
        for x in 0..<width {
            for y in 0..<height {
                colReal[y]=real[y*width+x]
                colImag[y]=imag[y*width+x]
            }
            fft1(&colReal,&colImag,inverse:inverse)
            for y in 0..<height {
                real[y*width+x]=colReal[y]
                imag[y*width+x]=colImag[y]
            }
        }
    }
    /// OPT-06: explicit diagnostic-only candidate. Production calls
    /// continue using the existing radix-2 Float64 implementation.
    enum FFTBackend {
        case reference
        case accelerateCandidate
    }

    #if canImport(Accelerate)
    private final class AccelerateFFT {
        private let setup:FFTSetupD
        private let width:Int
        private let height:Int
        init(width:Int,height:Int) throws {
            self.width=width
            self.height=height
            let log2n=max(width.trailingZeroBitCount,height.trailingZeroBitCount)
            guard let value=vDSP_create_fftsetupD(vDSP_Length(log2n),FFTRadix(kFFTRadix2)) else {
                throw Failure.invalid("Double Accelerate FFT setup allocation failed")
            }
            setup=value
        }
        deinit { vDSP_destroy_fftsetupD(setup) }

        func transform(_ real:inout [Double],_ imag:inout [Double],inverse:Bool) throws {
            let w=width,h=height
            let direction=FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD)
            try real.withUnsafeMutableBufferPointer { rp in
                try imag.withUnsafeMutableBufferPointer { ip in
                    guard let r=rp.baseAddress,let i=ip.baseAddress else {
                        throw Failure.invalid("Double FFT empty plane")
                    }
                    for y in 0..<h {
                        if y & 31 == 0 { try Task.checkCancellation() }
                        var split=DSPDoubleSplitComplex(realp:r.advanced(by:y*w),imagp:i.advanced(by:y*w))
                        if w>1 {
                            vDSP_fft_zipD(setup,&split,1,vDSP_Length(w.trailingZeroBitCount),direction)
                        }
                    }
                    for x in 0..<w {
                        if x & 31 == 0 { try Task.checkCancellation() }
                        var split=DSPDoubleSplitComplex(realp:r.advanced(by:x),imagp:i.advanced(by:x))
                        if h>1 {
                            vDSP_fft_zipD(setup,&split,vDSP_Stride(w),vDSP_Length(h.trailingZeroBitCount),direction)
                        }
                    }
                    if inverse {
                        let scale=1.0/Double(w*h)
                        for k in 0..<(w*h) {
                            r[k]*=scale
                            i[k]*=scale
                        }
                    }
                }
            }
        }
    }
    #endif

    /// Explicit, bounded device diagnostic only. No change to the
    /// production FFT backend or renderer. Reference and candidate share
    /// precisely the same input, source PSF, reflection and geometry.
    static func runDeviceComparison(
        observe:(String,[String:String])->Void
    ) throws -> Bool {
        let w=512,h=384,pixelUM=100.0
        let input=(0..<(w*h*3)).map { Double(($0*37+11)%251)/251.0 }
        var passed=true
        for family in Family.allCases {
            var cfg=Settings()
            cfg.active=true
            cfg.family=family
            let start=ProcessInfo.processInfo.systemUptime
            let reference=try apply(input,width:w,height:h,pixelUM:pixelUM,
                                    settings:cfg,fftBackend:.reference,usePreparedPSFCache:false)
            let referenceSeconds=ProcessInfo.processInfo.systemUptime-start
            observe("fft_reference_ready",["family":family.rawValue,
                "seconds":String(referenceSeconds),"width":String(w),"height":String(h)])
            let candidateStart=ProcessInfo.processInfo.systemUptime
            let candidate=try apply(input,width:w,height:h,pixelUM:pixelUM,
                                    settings:cfg,fftBackend:.accelerateCandidate,usePreparedPSFCache:false)
            let candidateSeconds=ProcessInfo.processInfo.systemUptime-candidateStart
            guard candidate.count==reference.count else {
                throw Failure.invalid("FFT diagnostic candidate size differs")
            }
            var maxAbsolute=0.0,maxScaled=0.0
            for k in reference.indices {
                let delta=abs(reference[k]-candidate[k])
                guard delta.isFinite else {throw Failure.invalid("FFT diagnostic nonfinite")}
                maxAbsolute=max(maxAbsolute,delta)
                maxScaled=max(maxScaled,delta/max(1,abs(reference[k])))
            }
            let equal=maxScaled<=1e-10
            passed = passed && equal
            observe("fft_candidate_ready",["family":family.rawValue,
                "referenceSeconds":String(referenceSeconds),"candidateSeconds":String(candidateSeconds),
                "maxAbsolute":String(maxAbsolute),"maxScaled":String(maxScaled),
                "tolerance":"1e-10","passed":String(equal)])
        }
        observe("fft_comparison_result",["passed":String(passed),"scope":"synthetic_512x384_four_families_not_full_RAW"])
        return passed
    }

    private static func reflect(_ pos:Int,dimension:Int) -> Int {
        precondition(dimension>0)
        // numpy.pad(mode="reflect") repeats its mirrored period; a
        // 1-pixel axis has no neighbour and therefore repeats the pixel.
        if dimension==1 {return 0}
        let period=2*dimension-2
        let residue=(pos%period+period)%period
        return residue<dimension ? residue : period-residue
    }
    static func apply(_ rgb:[Double],width:Int,height:Int,
                      pixelUM:Double,settings:Settings,
                      fftBackend:FFTBackend = .reference,
                      usePreparedPSFCache:Bool = true) throws -> [Double] {
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
        // Build136: the 512MB FFT limit was a local experimental cap,
        // not an original Python numerical boundary. Check the actual
        // yet-to-be-allocated 4× complex-plane storage, output and
        // row/column scratch against current OS headroom instead.
        // The full-sized frame is already allocated at this stage.
        let remainingScratch=UInt64(grid)*32 +
            UInt64(rgb.count)*8 + UInt64(fftW+fftH)*16 +
            UInt64(ks)*UInt64(ks)*3*8
        let available:UInt64
        #if os(iOS)
        available=UInt64(os_proc_available_memory())
        #else
        available=ProcessInfo.processInfo.physicalMemory/3
        #endif
        guard available>0,remainingScratch <= (available/10)*8 else {
            throw Failure.invalid(
                "原版 Float64 FFT 仍需约 \(remainingScratch/1_000_000) MB，" +
                "当前可分配约 \(available/1_000_000) MB；需要 20% 余量，" +
                "不缩短 PSF、不转 Float32、不自动缩图"
            )
        }
        // The candidate shares the identical PSF/reflect/grid/convolution
        // and blending code; it is never selected implicitly or on failure.
        #if canImport(Accelerate)
        let candidate = fftBackend == .accelerateCandidate
            ? try AccelerateFFT(width:fftW,height:fftH) : nil
        #else
        guard fftBackend == .reference else {
            throw Failure.invalid("Accelerate Double FFT unavailable")
        }
        #endif
        func transform(_ real:inout [Double],_ imag:inout [Double],inverse:Bool) throws {
            try Task.checkCancellation()
            #if canImport(Accelerate)
            if let candidate {
                try candidate.transform(&real,&imag,inverse:inverse)
                return
            }
            #endif
            fft2(&real,&imag,width:fftW,height:fftH,inverse:inverse)
        }
        let kernel=try (usePreparedPSFCache
            ? preparedPSF(width:width,height:height,pixelUM:pixelUM,settings:settings)
            : psf(width:width,height:height,pixelUM:pixelUM,settings:settings))
        var output=[Double](repeating:0,count:rgb.count)
        // Reuse the SAME four double-precision FFT planes for all three
        // channels. Every value is zeroed before refilling the next RGB
        // plane, so the old per-channel four-plane allocation / reduction
        // order are preserved without a large heap allocation per pass.
        var ar=[Double](repeating:0,count:grid)
        var ai=[Double](repeating:0,count:grid)
        var br=[Double](repeating:0,count:grid)
        var bi=[Double](repeating:0,count:grid)
        for c in 0..<3 {
            if c>0 {
                // Initialize existing Double elements to the exact
                // IEEE-754 +0.0 bit pattern. The old Swift per-element
                // loops incurred 4 × grid bounds/CoW checks per channel;
                // memset keeps the original zero-padded FFT grid and
                // prevents any allocation/Float32 approximation.
                let bytes=grid*MemoryLayout<Double>.stride
                ar.withUnsafeMutableBufferPointer {
                    if let ptr=$0.baseAddress { _=memset(ptr,0,bytes) }
                }
                ai.withUnsafeMutableBufferPointer {
                    if let ptr=$0.baseAddress { _=memset(ptr,0,bytes) }
                }
                br.withUnsafeMutableBufferPointer {
                    if let ptr=$0.baseAddress { _=memset(ptr,0,bytes) }
                }
                bi.withUnsafeMutableBufferPointer {
                    if let ptr=$0.baseAddress { _=memset(ptr,0,bytes) }
                }
            }
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
            try transform(&ar,&ai,inverse:false)
            try transform(&br,&bi,inverse:false)
            for i in 0..<grid {
                let rr=ar[i]*br[i]-ai[i]*bi[i]
                let ii=ar[i]*bi[i]+ai[i]*br[i]
                ar[i]=rr; ai[i]=ii
            }
            try transform(&ar,&ai,inverse:true)
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
