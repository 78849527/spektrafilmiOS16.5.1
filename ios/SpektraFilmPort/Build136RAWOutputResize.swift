import Foundation

/// Build136: user-selected output-only Float64 downsampling AFTER the
/// original RAW demosaic + full-resolution film/paper/scanner pipeline.
/// Does not modify the original RAW, optical settings, RNG or source dimensions.
/// Area-overlap averaging preserves signed and >1.0 values without Float32/CI.
enum Build136RAWOutputResize {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }
    struct Result {
        let width:Int
        let height:Int
        let rgb:[Double]
    }
    private struct Tap {
        let index:Int
        let weight:Double
    }

    private static func taps(source:Int,target:Int) -> [[Tap]] {
        let scale=Double(source)/Double(target)
        return (0..<target).map { pixel in
            let start=Double(pixel)*scale
            let end=Double(pixel+1)*scale
            let first=Int(start.rounded(.down))
            let last=Int(end.rounded(.up))
            return (first..<last).compactMap { sample -> Tap? in
                guard sample>=0,sample<source else {return nil}
                let overlap=min(end,Double(sample+1)) -
                    max(start,Double(sample))
                return overlap>0 ?
                    Tap(index:sample,weight:overlap/scale) : nil
            }
        }
    }

    static func resample(
        width:Int,height:Int,rgb:[Double],
        targetWidth:Int,targetHeight:Int
    ) throws -> Result {
        guard width>0,height>0,width<=8192,height<=8192,
              width<=13_000_000/height,
              targetWidth>0,targetHeight>0,
              targetWidth<=width,targetHeight<=height,
              targetWidth<=8192,targetHeight<=8192,
              targetWidth<=13_000_000/targetHeight,
              rgb.count==width*height*3 else {
            throw Failure.invalid(
                "Build136 RAW 缩图尺寸或 Float64 缓冲非法，不裁切不放大"
            )
        }
        if targetWidth==width && targetHeight==height {
            return Result(width:width,height:height,rgb:rgb)
        }
        let ratioX=Double(targetWidth)/Double(width)
        let ratioY=Double(targetHeight)/Double(height)
        guard abs(ratioX-ratioY) <=
                max(1.0/Double(width),1.0/Double(height)) else {
            throw Failure.invalid("RAW 成品缩图必须保持原长宽比")
        }
        let xTaps=taps(source:width,target:targetWidth)
        let yTaps=taps(source:height,target:targetHeight)
        var output=[Double](repeating:0,count:targetWidth*targetHeight*3)
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                let dst=(y*targetWidth+x)*3
                for yt in yTaps[y] {
                    let srcRow=yt.index*width*3
                    for xt in xTaps[x] {
                        let src=srcRow+xt.index*3
                        let w=yt.weight*xt.weight
                        output[dst] += rgb[src]*w
                        output[dst+1] += rgb[src+1]*w
                        output[dst+2] += rgb[src+2]*w
                    }
                }
            }
        }
        return Result(width:targetWidth,height:targetHeight,rgb:output)
    }
}
