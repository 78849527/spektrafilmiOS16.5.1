import Foundation

/// Build81/16: direct CPU Float64 port of upstream gamut_compression:
/// reinhard_knee -> _ray_polygon_distance -> compress_xy_radial.
/// Tested with a specified closed locus. Original default CIE polygon
/// needs an independently generated measured table before production use.
/// Oklch now follows original colour-science v0.4.6: 64x720 chroma
/// envelope / 18 bisections against the visible locus. Independently tested
/// with the source Python oracle; production TC-LUT baking is a separate gate.
enum Build81OriginalInputGamut {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let m)=self {return m}
            return nil
        }
    }

    struct Point {
        let x: Double
        let y: Double
    }

    struct Knee {
        let threshold:Double
        let limit:Double
        let power:Double

        static let originalDefault=Knee(threshold:0,limit:1,power:6)

        func validate() throws {
            guard threshold.isFinite,limit.isFinite,power.isFinite,
                  threshold>=0,threshold<1,limit>0,power>0 else {
                throw Failure.invalid("原版 input gamut Reinhard-knee 参数非法")
            }
            // Keep source InputGamutCompressSpec validation.
        }
    }

    enum Algorithm {
        case xy
        case oklch
    }

    /// Direct source reinhard_knee(d, threshold, limit, power).
    static func reinhardKnee(_ d:Double,knee:Knee = .originalDefault)
        throws -> Double {
        try knee.validate()
        guard d.isFinite else {
            throw Failure.invalid("原版 knee 输入为非有限数")
        }
        guard d>knee.threshold else {return d}
        let scale=knee.limit-knee.threshold
        guard scale != 0 else {
            throw Failure.invalid("原版 knee 极限与阈值相等，无法计算")
        }
        let n=(d-knee.threshold)/scale
        let numerator=pow(n,knee.power)
        let denominator=pow(1.0+numerator,1.0/knee.power)
        let v=knee.threshold+scale*(n/denominator)
        guard v.isFinite else {
            throw Failure.invalid("原版 knee 结果非有限；拒绝静默近似")
        }
        return v
    }

    /// Source first forward ray-polygon hit:
    /// t > 1e-9, segment fraction s in [0,1], |denom|>1e-12.
    static func rayBoundary(
        white:Point,unitDirection:Point,locus:[Point]
    ) throws -> Double {
        guard locus.count>=4,
              locus.first!.x==locus.last!.x,
              locus.first!.y==locus.last!.y,
              unitDirection.x.isFinite,unitDirection.y.isFinite,
              locus.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {
            throw Failure.invalid("原版 xy 色域 polygon 缺少闭合边界")
        }
        var nearest=Double.infinity
        for i in 0..<(locus.count-1) {
            let a=locus[i], b=locus[i+1]
            let ex=b.x-a.x,ey=b.y-a.y
            let dx=unitDirection.x,dy=unitDirection.y
            let denom=dx*ey-dy*ex
            if abs(denom)<=1e-12 {continue}
            let ox=white.x-a.x,oy=white.y-a.y
            let t=(-ox*ey+oy*ex)/denom
            let s=(-ox*dy+oy*dx)/denom
            if t>1e-9,s>=0,s<=1,t<nearest {nearest=t}
        }
        guard nearest.isFinite else {
            throw Failure.invalid("原版 xy 射线未交光谱边界，禁止伪默认")
        }
        return nearest
    }

    /// Production-default Python XY gamut with the *actual* CIE 1931
    /// measured locus, generated from pinned source Python/colour-science.
    /// Oklch remains explicitly unsupported; no default substitution.
    static func compressUsingOriginalSpectralLocus(
        _ xy:[Point],white:Point,knee:Knee = .originalDefault,
        active:Bool=true,algorithm:Algorithm = .xy
    ) throws -> [Point] {
        try compress(
            xy,white:white,knee:knee,active:active,algorithm:algorithm,
            locus:Build81GeneratedSpectralLocus.points
        )
    }

    static func compress(
        _ xy:[Point],white:Point,knee:Knee = .originalDefault,
        active:Bool=true,algorithm:Algorithm = .xy,locus:[Point]
    ) throws -> [Point] {
        if !active {return xy}
        try knee.validate()
        if algorithm == .oklch {
            // Original source Oklch does not use white_xy; L and hue
            // stay constant in Oklab, only chroma is compressed.
            return try compressOklch(xy,knee:knee,locus:locus)
        }
        guard white.x.isFinite,white.y.isFinite else {
            throw Failure.invalid("无效原版光源色品白点")
        }
        var result=[Point]()
        result.reserveCapacity(xy.count)
        for p in xy {
            let delta=Point(x:p.x-white.x,y:p.y-white.y)
            let dist=hypot(delta.x,delta.y)
            guard dist.isFinite else {
                throw Failure.invalid("原版输入色品 contains NaN/Inf")
            }
            // Exact original np.where(dist<1e-9,xy,new_xy) final route.
            if dist<1e-9 {
                result.append(p)
                continue
            }
            let safe=max(dist,1e-12)
            let direction=Point(x:delta.x/safe,y:delta.y/safe)
            let boundary=try rayBoundary(
                white:white,unitDirection:direction,locus:locus
            )
            let normalized=dist/max(boundary,1e-12)
            let compressed=try reinhardKnee(normalized,knee:knee)
            let radial=compressed*boundary
            let newPoint=Point(
                x:white.x+direction.x*radial,
                y:white.y+direction.y*radial
            )
            guard newPoint.x.isFinite,newPoint.y.isFinite else {
                throw Failure.invalid("原版输入 xy 压缩产生非有限输出")
            }
            result.append(newPoint)
        }
        return result
    }

    // Original pinned source:
    // src/spektrafilm/utils/gamut_compression.py blob
    // 9783e7fcfc2909c4acdf2da53595c5404645dde9
    // colour 0.4.6 Oklab matrices. Table geometry is exactly 64 L
    // nodes in [0.05,1] x 720 hue nodes [-pi,pi) x 18 bisects.
    // Nodes are computed ON DEMAND; equivalent to the source full array
    // for each cell; never a 3D LUT substitution.
    private static let oklchLock = NSLock()
    private static var oklchTable = [UInt64:[Int:Double]]()
    private static let xyzToLms:[Double] = [
        0.8189330101,0.3618667424,-0.1288597137,
        0.0329845436,0.9293118715,0.0361456387,
        0.0482003018,0.2643662691,0.6338517070
    ]
    private static let lmsToLab:[Double] = [
        0.2104542553,0.7936177850,-0.0040720468,
        1.9779984951,-2.4285922050,0.4505937099,
        0.0259040371,0.7827717662,-0.8086757660
    ]
    private static let labToLms:[Double] = [
        0.99999999845051968,0.3963377921737678,0.21580375806075877,
        1.0000000088817607,-0.10556134232365633,-0.063854174771705893,
        1.0000000546724108,-0.089484182094965739,-1.2914855378640917
    ]
    private static let lmsToXyz:[Double] = [
        1.2270138511035211,-0.55779998065182224,0.28125614896646778,
        -0.0405801784232806,1.11225686961683,-0.071676678665601193,
        -0.076381284505706901,-0.42148197841801271,1.5861632204407947
    ]
    private static func matrix(_ m:[Double],_ v:[Double])->[Double] {
        var out=[Double](repeating:0,count:3)
        for row in 0..<3 {
            let base=row*3
            let x=m[base]*v[0]
            let y=m[base+1]*v[1]
            let z=m[base+2]*v[2]
            out[row]=x+y+z
        }
        return out
    }
    private static func signedCbrt(_ v:Double)->Double {
        v<0 ? -pow(-v,1.0/3.0) : pow(v,1.0/3.0)
    }
    private static func oklab(_ xyz:[Double])->[Double] {
        matrix(lmsToLab,matrix(xyzToLms,xyz).map {signedCbrt($0)})
    }
    private static func xyz(_ lab:[Double])->[Double] {
        let lms=matrix(labToLms,lab).map {$0*$0*$0}
        return matrix(lmsToXyz,lms)
    }
    private static func chromaPoint(_ lab:[Double])->Point {
        let v=xyz(lab)
        let denom=max(v[0]+v[1]+v[2],1e-12)
        return Point(x:v[0]/denom,y:v[1]/denom)
    }
    private static func contains(_ p:Point,polygon:[Point])->Bool {
        // Same even-odd interior predicate as matplotlib.path.Path.
        // Vertex-boundary classification has no guaranteed interior;
        // the source oracle independently compares the 18-bisect result.
        var inside=false
        for k in 0..<(polygon.count-1) {
            let a=polygon[k],b=polygon[k+1]
            if (a.y>p.y) != (b.y>p.y) {
                let edge=a.x+(p.y-a.y)*(b.x-a.x)/(b.y-a.y)
                if p.x<edge {inside.toggle()}
            }
        }
        return inside
    }
    private static func fingerprint(_ polygon:[Point])->UInt64 {
        // Collision-resilient enough for an in-process numeric cache;
        // never reuse a cache just by pointer identity.
        var value:UInt64=14695981039346656037
        for p in polygon {
            for bit in [p.x.bitPattern,p.y.bitPattern] {
                value=(value ^ bit) &* 1099511628211
            }
        }
        return (value ^ UInt64(polygon.count)) &* 1099511628211
    }
    private static func cmaxNode(
        LIndex:Int,hIndex:Int,locus:[Point],key:UInt64
    )->Double {
        let node=LIndex*720+hIndex
        oklchLock.lock()
        let cached=oklchTable[key]?[node]
        oklchLock.unlock()
        if let cached{return cached}
        let L=0.05+0.95*Double(LIndex)/63.0
        let h = -Double.pi + 2.0*Double.pi*Double(hIndex)/720.0
        let ch=cos(h),sh=sin(h)
        var lo=0.0,hi=0.5
        for _ in 0..<18 {
            let mid=(lo+hi)*0.5
            let q=chromaPoint([L,mid*ch,mid*sh])
            if contains(q,polygon:locus) {lo=mid}
            else {hi=mid}
        }
        oklchLock.lock()
        var row=oklchTable[key] ?? [:]
        row[node]=lo
        oklchTable[key]=row
        oklchLock.unlock()
        return lo
    }
    private static func cmax(
        L:Double,h:Double,locus:[Point],key:UInt64
    )->Double {
        let clipped=max(0.05,min(1.0,L))
        let fractionalL=(clipped-0.05)/0.95*63.0
        let l0=max(0,min(62,Int(floor(fractionalL))))
        let l1=l0+1,lf=fractionalL-Double(l0)
        let hueIndex=(h+Double.pi)/(2.0*Double.pi)*720.0
        let floorHue=floor(hueIndex)
        let raw=Int(floorHue)
        let h0=((raw%720)+720)%720
        let h1=(h0+1)%720,hf=hueIndex-floorHue
        let a=cmaxNode(LIndex:l0,hIndex:h0,locus:locus,key:key)
        let b=cmaxNode(LIndex:l0,hIndex:h1,locus:locus,key:key)
        let c=cmaxNode(LIndex:l1,hIndex:h0,locus:locus,key:key)
        let d=cmaxNode(LIndex:l1,hIndex:h1,locus:locus,key:key)
        let left=a*(1-lf)*(1-hf)+b*(1-lf)*hf
        let right=c*lf*(1-hf)+d*lf*hf
        return left+right
    }
    private static func compressOklch(
        _ xy:[Point],knee:Knee,locus:[Point]
    ) throws->[Point] {
        guard locus.count>=4,
              locus.first?.x==locus.last?.x,
              locus.first?.y==locus.last?.y,
              locus.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              xy.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {
            throw Failure.invalid(
                "原版 Oklch 输入值或光谱边界无效；禁止用 xy/ACES 替代"
            )
        }
        let cacheKey=fingerprint(locus)
        return try xy.map { q in
            // Python _xy_to_xyz_unit_y preserves Y=1, even for
            // non-sRGB input chromaticities; do NOT clip source xy.
            let safeY=max(q.y,1e-12)
            let lab=oklab([q.x/safeY,1.0,(1-q.x-q.y)/safeY])
            let L=lab[0],C=hypot(lab[1],lab[2])
            let h=atan2(lab[2],lab[1])
            guard L.isFinite,C.isFinite,h.isFinite else {
                throw Failure.invalid("源 Oklch 计算出现非有限值")
            }
            let cap=max(cmax(L:L,h:h,locus:locus,key:cacheKey),1e-9)
            let normalized=C/cap
            let changed=try reinhardKnee(normalized,knee:knee)*cap
            let out=chromaPoint([
                L,changed*cos(h),changed*sin(h)
            ])
            guard out.x.isFinite,out.y.isFinite else {
                throw Failure.invalid("源 Oklch 压缩输出非有限")
            }
            return out
        }
    }
}
