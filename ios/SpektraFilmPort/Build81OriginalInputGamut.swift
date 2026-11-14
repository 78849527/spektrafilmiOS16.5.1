import Foundation

/// Build81/16: direct CPU Float64 port of upstream gamut_compression:
/// reinhard_knee -> _ray_polygon_distance -> compress_xy_radial.
/// Tested with a specified closed locus. Original default CIE polygon
/// needs an independently generated measured table before production use.
/// Oklch mode remains NOT MIGRATED and throws; no silent switch to xy.
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
        guard algorithm == .xy else {
            throw Failure.invalid(
                "Python 原版 input gamut Oklch 路径尚未数值移植；不得降级到 xy"
            )
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
}
