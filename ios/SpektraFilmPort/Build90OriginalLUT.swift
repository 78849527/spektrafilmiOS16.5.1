import Foundation

/// Port of original fast_interp_lut.py: CPU Double PCHIP default,
/// optional Mitchell B=C=1/3 with reflect boundaries, no Float32 cube.
enum Build90OriginalLUT {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self{return s}
            return nil
        }
    }
    enum Method {case pchip,mitchell}
    struct Prepared {
        let n:Int
        let values:[Double]
        let minDomain:[Double]
        let maxDomain:[Double]
        let revision:String
        let sx:[Double],sy:[Double],sz:[Double]
        let cellMin:[Double],cellMax:[Double]

        init(size:Int,values:[Double],revision:String,
             minimum:[Double]=[0,0,0],
             maximum:[Double]=[1,1,1]) throws {
            guard size>=1,size<=129,
                  values.count==size*size*size*3,
                  values.allSatisfy({$0.isFinite}),
                  !revision.isEmpty,
                  minimum.count==3,maximum.count==3,
                  (0..<3).allSatisfy({
                      minimum[$0].isFinite &&
                      maximum[$0].isFinite &&
                      maximum[$0]>minimum[$0]
                  }) else {
                throw Failure.invalid(
                    "原版 LUT 需要 1..129³×3 Double " +
                    "样本、3 轴有效 domain 和明确缓存 revision"
                )
            }
            self.n=size
            self.values=values
            self.minDomain=minimum
            self.maxDomain=maximum
            self.revision=revision
            let count=values.count
            var slopesX=[Double](repeating:0,count:count)
            var slopesY=slopesX,slopesZ=slopesX
            func index(_ x:Int,_ y:Int,_ z:Int,_ ch:Int)->Int {
                (((x*size+y)*size+z)*3)+ch
            }
            for axis in 0..<3 {
                for i in 0..<size {
                    for j in 0..<size {
                        for ch in 0..<3 {
                            let line=(0..<size).map{k -> Double in
                                switch axis {
                                case 0:return values[index(k,i,j,ch)]
                                case 1:return values[index(i,k,j,ch)]
                                default:return values[index(i,j,k,ch)]
                                }
                            }
                            let slope=Build90OriginalLUT.slopes(line)
                            for k in 0..<size {
                                let pos:Int
                                switch axis {
                                case 0:pos=index(k,i,j,ch)
                                case 1:pos=index(i,k,j,ch)
                                default:pos=index(i,j,k,ch)
                                }
                                switch axis {
                                case 0:slopesX[pos]=slope[k]
                                case 1:slopesY[pos]=slope[k]
                                default:slopesZ[pos]=slope[k]
                                }
                            }
                        }
                    }
                }
            }
            sx=slopesX;sy=slopesY;sz=slopesZ
            let cells=max(0,size-1)
            var lows=[Double](repeating:0,count:cells*cells*cells*3)
            var highs=lows
            if size>1 {
                for x in 0..<cells {
                    for y in 0..<cells {
                        for z in 0..<cells {
                            for ch in 0..<3 {
                                var low=values[index(x,y,z,ch)],high=low
                                for dx in 0..<2 {
                                    for dy in 0..<2 {
                                        for dz in 0..<2 {
                                            let v=values[index(
                                                x+dx,y+dy,z+dz,ch
                                            )]
                                            low=min(low,v);high=max(high,v)
                                        }
                                    }
                                }
                                let pos=(((x*cells+y)*cells+z)*3)+ch
                                lows[pos]=low;highs[pos]=high
                            }
                        }
                    }
                }
            }
            cellMin=lows;cellMax=highs
        }
        func index(_ x:Int,_ y:Int,_ z:Int,_ ch:Int)->Int {
            (((x*n+y)*n+z)*3)+ch
        }
        func sample(_ point:[Double],method:Method = .pchip)throws->[Double] {
            guard point.count==3,point.allSatisfy({$0.isFinite}) else {
                throw Failure.invalid("源 LUT 输入 RGB 非有限／维度错误")
            }
            if n==1 {
                // Original prepare_lut_pchip_3d calls the soft monotonic
                // validator before its size=1 fast path. np.max(diff)
                // on an empty 1-node line RAISES ValueError. Preserve
                // source behavior instead of silently returning a color.
                if method == .pchip {
                    throw Failure.invalid(
                        "原版 PCHIP 1-node LUT: Python monotonic check " +
                        "raises ValueError (empty diff); no silent fallback"
                    )
                }
                return (0..<3).map{values[index(0,0,0,$0)]}
            }
            let coordinate=(0..<3).map {ch in
                (point[ch]-minDomain[ch])/
                (maxDomain[ch]-minDomain[ch])*Double(n-1)
            }
            let c=coordinate.map{Build90OriginalLUT.cell($0,n)}
            switch method {
            case .pchip:
                let x=c[0].0,y=c[1].0,z=c[2].0
                let tx=c[0].1,ty=c[1].1,tz=c[2].1
                func mix(_ x:Double,_ y:Double,_ t:Double)->Double {
                    x+t*(y-x)
                }
                var result=[Double](repeating:0,count:3)
                for ch in 0..<3 {
                    func hr(_ yy:Int,_ zz:Int)->Double {
                        let a=index(x,yy,zz,ch),b=index(x+1,yy,zz,ch)
                        return Build90OriginalLUT.hermite(
                            values[a],values[b],sx[a],sx[b],tx
                        )
                    }
                    let v000=hr(y,z),v010=hr(y+1,z)
                    let v001=hr(y,z+1),v011=hr(y+1,z+1)
                    func interpolateSlopeY(_ yy:Int,_ zz:Int)->Double {
                        mix(sy[index(x,yy,zz,ch)],
                            sy[index(x+1,yy,zz,ch)],tx)
                    }
                    let vz0=Build90OriginalLUT.hermite(
                        v000,v010,
                        interpolateSlopeY(y,z),
                        interpolateSlopeY(y+1,z),ty
                    )
                    let vz1=Build90OriginalLUT.hermite(
                        v001,v011,
                        interpolateSlopeY(y,z+1),
                        interpolateSlopeY(y+1,z+1),ty
                    )
                    func interpolateSlopeZ(_ zz:Int)->Double {
                        let w00=sz[index(x,y,zz,ch)]
                        let w10=sz[index(x+1,y,zz,ch)]
                        let w01=sz[index(x,y+1,zz,ch)]
                        let w11=sz[index(x+1,y+1,zz,ch)]
                        return mix(mix(w00,w10,tx),mix(w01,w11,tx),ty)
                    }
                    let value=Build90OriginalLUT.hermite(
                        vz0,vz1,
                        interpolateSlopeZ(z),
                        interpolateSlopeZ(z+1),tz
                    )
                    let cell=(((x*(n-1)+y)*(n-1)+z)*3)+ch
                    result[ch]=min(cellMax[cell],max(cellMin[cell],value))
                }
                return result
            case .mitchell:
                let weights=c.map {(_,fraction) in
                    [
                        Build90OriginalLUT.weight(fraction+1),
                        Build90OriginalLUT.weight(fraction),
                        Build90OriginalLUT.weight(fraction-1),
                        Build90OriginalLUT.weight(fraction-2)
                    ]
                }
                var result=[Double](repeating:0,count:3)
                var sum=0.0
                for i in 0..<4 {
                    let x=Build90OriginalLUT.reflect(c[0].0-1+i,n)
                    for j in 0..<4 {
                        let y=Build90OriginalLUT.reflect(c[1].0-1+j,n)
                        for k in 0..<4 {
                            let z=Build90OriginalLUT.reflect(c[2].0-1+k,n)
                            let w=weights[0][i]*weights[1][j]*weights[2][k]
                            sum+=w
                            for ch in 0..<3 {
                                result[ch]+=w*values[index(x,y,z,ch)]
                            }
                        }
                    }
                }
                if sum != 0 {for ch in 0..<3 {result[ch]/=sum}}
                return result
            }
        }
        func applyImage(
            _ rgb:[Double],method:Method = .pchip
        )throws->[Double] {
            guard rgb.count%3==0 else {
                throw Failure.invalid("源 LUT RGB 图像长度必须为 3 的倍数")
            }
            var out=[Double](repeating:0,count:rgb.count)
            for start in stride(from:0,to:rgb.count,by:3) {
                let pixel=try sample(
                    Array(rgb[start..<start+3]),method:method
                )
                for ch in 0..<3{out[start+ch]=pixel[ch]}
            }
            return out
        }
    }

    static func generate(
        steps:Int,minimum:[Double],maximum:[Double],
        revision:String,
        transform:([Double])throws->[Double]
    )throws->Prepared {
        guard steps>=1,steps<=129,minimum.count==3,
              maximum.count==3 else {
            throw Failure.invalid("源 LUT steps/domain shape invalid")
        }
        var values=[Double]()
        values.reserveCapacity(steps*steps*steps*3)
        for r in 0..<steps {
            for g in 0..<steps {
                for b in 0..<steps {
                    let p=[r,g,b]
                    let x=(0..<3).map {ch in
                        minimum[ch]+(maximum[ch]-minimum[ch])*
                          Double(p[ch])/Double(max(1,steps-1))
                    }
                    let sample=try transform(x)
                    guard sample.count==3,
                          sample.allSatisfy({$0.isFinite}) else {
                        throw Failure.invalid("原版 LUT 生成函数返回无效通道")
                    }
                    values.append(contentsOf:sample)
                }
            }
        }
        return try Prepared(
            size:steps,values:values,revision:revision,
            minimum:minimum,maximum:maximum
        )
    }
    static func slopes(_ v:[Double])->[Double] {
        let n=v.count
        if n==1{return [0]}
        let d=(0..<(n-1)).map{v[$0+1]-v[$0]}
        if n==2{return [d[0],d[0]]}
        var m=[Double](repeating:0,count:n)
        let left=0.5*(3*d[0]-d[1])
        if left*d[0]<=0 {m[0]=0}
        else if d[0]*d[1]<0 && abs(left)>abs(3*d[0]){
            m[0]=3*d[0]
        } else{m[0]=left}
        for i in 1..<(n-1) {
            let prev=d[i-1],next=d[i]
            m[i]=(prev==0 || next==0 || prev*next<=0)
                ? 0 : 2*prev*next/(prev+next)
        }
        let right=0.5*(3*d[n-2]-d[n-3])
        if right*d[n-2]<=0{m[n-1]=0}
        else if d[n-2]*d[n-3]<0 && abs(right)>abs(3*d[n-2]){
            m[n-1]=3*d[n-2]
        } else{m[n-1]=right}
        return m
    }
    static func cell(_ val:Double,_ n:Int)->(Int,Double) {
        let c=max(0,min(Double(n-1),val))
        if c>=Double(n-1) {return (n-2,1)}
        let base=Int(floor(c))
        return (base,c-Double(base))
    }
    static func reflect(_ i:Int,_ n:Int)->Int {
        if i<0{return -i}
        if i>=n{return 2*(n-1)-i}
        return i
    }
    static func weight(_ t:Double)->Double {
        let x=abs(t),B=1.0/3.0,C=1.0/3.0
        if x<1 {
            return (1.0/6.0)*
                ((12-9*B-6*C)*x*x*x+(-18+12*B+6*C)*x*x+6-2*B)
        }
        if x<2 {
            return (1.0/6.0)*
                ((-B-6*C)*x*x*x+(6*B+30*C)*x*x+
                 (-12*B-48*C)*x+(8*B+24*C))
        }
        return 0
    }
    static func hermite(
        _ y0:Double,_ y1:Double,
        _ m0:Double,_ m1:Double,_ t:Double
    )->Double {
        let t2=t*t,t3=t2*t
        return (2*t3-3*t2+1)*y0+
               (t3-2*t2+t)*m0+
               (-2*t3+3*t2)*y1+
               (t3-t2)*m1
    }
}
