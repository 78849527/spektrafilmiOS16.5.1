import Foundation
import Darwin

/// Build82/17: original upstream spectral_upsampling.py polynomial4
/// surface and Mobius-warp option. CPU Double; source axes TC=(x,y),
/// reference white from integrated measured CIE 1931 source illuminant.
enum Build82OriginalHanatosSurface {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let x)=self {return x}
            return nil
        }
    }
    struct Point {let x:Double;let y:Double}
    enum Model {case poly4, poly4WarpXY}
    static let maxCorrectionStops=2.0

    static func tri2quad(_ xy:Point)->Point {
        let xx=min(1.0,max(0.0,pow(1.0-xy.x,2)))
        let yy=min(1.0,max(0.0,xy.y/max(1.0-xy.x,1e-10)))
        return Point(x:xx,y:yy)
    }

    static func quad2tri(_ tc:Point)->Point {
        let xx=sqrt(tc.x)
        return Point(x:1-xx,y:tc.y*xx)
    }

    static func radialMobiusWarp(
        xy:Point,center:Point,alpha:Double
    )->Point {
        let dx=xy.x-center.x,dy=xy.y-center.y
        let d=sqrt(dx*dx+dy*dy)
        let s=1.0/(1.0+alpha*d)
        return Point(x:center.x+dx*s,y:center.y+dy*s)
    }

    /// The source ignores c0 so that neutral tc-center correction = 0.
    static func polynomial4(tc:Point,params:[Double],center:Point)
        throws -> Double {
        guard params.count==15,params.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("Hanatos poly4 源曲面必须每层 15 个参数")
        }
        let x=tc.x-center.x,y=tc.y-center.y
        let x2=x*x,y2=y*y,xy=x*y
        let x3=x2*x,y3=y2*y
        let c=params
        return c[1]*x+c[2]*y+c[3]*x2+c[4]*y2+c[5]*xy
             + c[6]*x3+c[7]*y3+c[8]*(x2*y)+c[9]*(x*y2)
             + c[10]*(x2*x2)+c[11]*(y2*y2)+c[12]*(x3*y)
             + c[13]*(x2*y2)+c[14]*(x*y3)
    }

    static func hanikaSigmoid(_ z:Double)->Double {
        z/sqrt(1.0+pow(z/maxCorrectionStops,2))
    }

    static func correctionStops(
        tc:Point,channel:Int,params:[[Double]],referenceXY:Point,
        model:Model
    ) throws -> Double {
        guard channel>=0,channel<3,params.count==3,
              referenceXY.x.isFinite,referenceXY.y.isFinite else {
            throw Failure.invalid("Hanatos 光谱曲面通道/白点无效")
        }
        let center=tri2quad(referenceXY)
        let raw:Double
        switch model {
        case .poly4:
            raw=try polynomial4(tc:tc,params:params[channel],center:center)
        case .poly4WarpXY:
            let profile=params[channel]
            guard profile.count==16 else {
                throw Failure.invalid("Hanatos warped poly4 必须每层 16 参数")
            }
            let warped=radialMobiusWarp(
                xy:quad2tri(tc),center:referenceXY,alpha:profile[15]
            )
            raw=try polynomial4(
                tc:tri2quad(warped),params:Array(profile[..<15]),center:center
            )
        }
        let result=hanikaSigmoid(raw)
        guard result.isFinite else {
            throw Failure.invalid("Hanatos 原版曲面出现非有限数")
        }
        return result
    }

    static func gain(
        tc:Point,channel:Int,params:[[Double]],referenceXY:Point,
        model:Model
    ) throws -> Double {
        // Python: raw_lut *= 2**surface, not exposure factor 10**.
        pow(2.0,try correctionStops(
            tc:tc,channel:channel,params:params,
            referenceXY:referenceXY,model:model
        ))
    }
}
