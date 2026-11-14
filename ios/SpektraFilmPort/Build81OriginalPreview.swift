import Foundation

/// Build81/14-15: source preview.resize_for_preview for Float64 H×W×3.
/// This is NOT ImageIO's fast thumbnail or Core Image's linear resize.
/// It models skimage 0.25.2 resize(preserve_range=True,
/// anti_aliasing=True,order=1,mode="reflect"):
/// scipy.ndimage gaussian_filter(mode="mirror",truncate=4) followed by
/// ndi.zoom(order=1,grid_mode=True,mode="mirror"), then original range clip.
/// Float32 source preview precision is a separate not-yet-certified path.
enum Build81OriginalPreview {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let value)=self {return value}
            return nil
        }
    }

    typealias Image=Build81OriginalCrop.Image
    struct Size {
        let width:Int
        let height:Int
        let scaled:Bool
    }

    static func outputSize(width:Int,height:Int,maxSide:Int) throws -> Size {
        guard width>0,height>0,maxSide>0,
              width<=8192,height<=8192,
              width<=Int.max/height else {
            throw Failure.invalid("原版预览宽高或 max_size 无效")
        }
        let longest=max(width,height)
        guard longest>maxSide else {
            return Size(width:width,height:height,scaled:false)
        }
        let ratio=Double(maxSide)/Double(longest)
        // Python's int() truncates toward zero. No ceil/round-up.
        let w=Int(Double(width)*ratio)
        let h=Int(Double(height)*ratio)
        guard w>0,h>0 else {
            throw Failure.invalid("原版 skimage 目标边长为 0；显式失败")
        }
        return Size(width:w,height:h,scaled:true)
    }

    private static func mirror(_ coordinate:Int,_ count:Int) -> Int {
        if count<=1 {return 0}
        let period=2*(count-1)
        let value=(coordinate%period+period)%period
        return value<count ? value : period-value
    }

    private static func axisBlur(
        _ data:[Double],width:Int,height:Int,alongY:Bool,sigma:Double
    ) -> [Double] {
        if sigma<=1e-15 {return data}
        let radius=Int(4.0*sigma+0.5)
        let unnormalized=(-radius...radius).map { i in
            exp(-0.5*pow(Double(i)/sigma,2))
        }
        let sum=unnormalized.reduce(0,+)
        let kernel=unnormalized.map {$0/sum}
        var output=[Double](repeating:0,count:data.count)
        for y in 0..<height {
            for x in 0..<width {
                for ch in 0..<3 {
                    var value=0.0
                    for k in -radius...radius {
                        let yy=alongY ? mirror(y+k,height) : y
                        let xx=alongY ? x : mirror(x+k,width)
                        value+=kernel[k+radius]*data[(yy*width+xx)*3+ch]
                    }
                    output[(y*width+x)*3+ch]=value
                }
            }
        }
        return output
    }

    static func resizeForPreview(_ input:Image,maxSide:Int) throws -> Image {
        let n=try outputSize(width:input.width,height:input.height,
                             maxSide:maxSide)
        guard input.width<=Int.max/input.height,
              input.width*input.height<=Int.max/3,
              input.rgb.count==input.width*input.height*3 else {
            throw Failure.invalid("原版预览输入必须是 H×W×3 Float64")
        }
        // Python source no-resize path returns original ndarray object.
        if !n.scaled {return input}
        guard input.rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("原版预览数值验证只接受有限 Float64")
        }
        let minInput=input.rgb.min() ?? 0
        let maxInput=input.rgb.max() ?? 0
        let sigmaY=max(0,(Double(input.height)/Double(n.height)-1)/2)
        let sigmaX=max(0,(Double(input.width)/Double(n.width)-1)/2)
        let blurY=axisBlur(input.rgb,width:input.width,height:input.height,
                           alongY:true,sigma:sigmaY)
        let filtered=axisBlur(blurY,width:input.width,height:input.height,
                              alongY:false,sigma:sigmaX)
        var output=[Double](repeating:0,count:n.width*n.height*3)
        for y in 0..<n.height {
            let sourceY=(Double(y)+0.5)*Double(input.height)/Double(n.height)-0.5
            let iy=Int(floor(sourceY))
            let fy=sourceY-Double(iy)
            let y0=mirror(iy,input.height),y1=mirror(iy+1,input.height)
            for x in 0..<n.width {
                let sourceX=(Double(x)+0.5)*Double(input.width)/Double(n.width)-0.5
                let ix=Int(floor(sourceX))
                let fx=sourceX-Double(ix)
                let x0=mirror(ix,input.width),x1=mirror(ix+1,input.width)
                for ch in 0..<3 {
                    let v00=filtered[(y0*input.width+x0)*3+ch]
                    let v01=filtered[(y0*input.width+x1)*3+ch]
                    let v10=filtered[(y1*input.width+x0)*3+ch]
                    let v11=filtered[(y1*input.width+x1)*3+ch]
                    let top=v00*(1-fx)+v01*fx
                    let bottom=v10*(1-fx)+v11*fx
                    let interpolated=top*(1-fy)+bottom*fy
                    output[(y*n.width+x)*3+ch]=min(max(interpolated,minInput),maxInput)
                }
            }
        }
        return Image(width:n.width,height:n.height,rgb:output)
    }
}
