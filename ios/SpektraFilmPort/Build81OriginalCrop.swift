import Foundation

/// Build81/13: exact source crop_resize.crop_image geometry and CPU Float64
/// RGB slicing. Source centre & size order is (x,y), numpy shape is (y,x).
/// NumPy round() is banker's rounding; no forced rounding away from zero.
enum Build81OriginalCrop {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let value)=self { return value }
            return nil
        }
    }
    struct Region {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    struct Image {
        let width: Int
        let height: Int
        let rgb: [Double]
    }

    private static func numpySliceIndex(_ index: Int, dimension: Int) -> Int {
        // NumPy ndarray[a:b] resolves each negative slice bound relative
        // to dimension, then clips into 0...dimension.
        let raw=index < 0 ? index + dimension : index
        return max(0,min(dimension,raw))
    }

    private static func interval(
        dimension: Int, center: Double, size: Double
    ) throws -> (start: Int, count: Int) {
        let c=Double(dimension)*center
        let sizeRounded=size.rounded(.toNearestOrEven)
        let centerRounded=c.rounded(.toNearestOrEven)
        let raw=(centerRounded-sizeRounded/2.0).rounded(.toNearestOrEven)
        guard sizeRounded.isFinite,centerRounded.isFinite,raw.isFinite,
              sizeRounded <= Double(Int.max/2),
              sizeRounded >= Double(Int.min/2),
              raw <= Double(Int.max/2),raw >= Double(Int.min/2) else {
            throw Failure.invalid("原版裁剪尺寸或中心发生溢出")
        }
        let count=Int(sizeRounded)
        var start=Int(raw)
        if start<0 { start=0 }
        if start+count>dimension {start=dimension-count}
        let lo=numpySliceIndex(start,dimension:dimension)
        let hi=numpySliceIndex(start+count,dimension:dimension)
        return (lo,max(0,hi-lo))
    }

    static func region(
        imageWidth: Int, imageHeight: Int,
        centerX: Double=0.5, centerY: Double=0.5,
        sizeX: Double=0.1, sizeY: Double=0.1
    ) throws -> Region {
        guard imageWidth>0,imageHeight>0,
              imageWidth<=8192,imageHeight<=8192,
              imageWidth<=Int.max/imageHeight,
              [centerX,centerY,sizeX,sizeY].allSatisfy({$0.isFinite}),
              (0...1).contains(centerX),(0...1).contains(centerY),
              sizeX>=0,sizeY>=0 else {
            throw Failure.invalid("非法原版裁剪输入；不隐式裁剪/重采样")
        }
        // Source: sz = np.round(np.double(np.max(shape))*np.flip(size)).
        let longest=Double(max(imageWidth,imageHeight))
        let vertical=try interval(dimension:imageHeight,
                                  center:centerY,size:longest*sizeY)
        let horizontal=try interval(dimension:imageWidth,
                                    center:centerX,size:longest*sizeX)
        return Region(x:horizontal.start,y:vertical.start,
                      width:horizontal.count,height:vertical.count)
    }

    static func crop(_ input: Image,
                     centerX: Double=0.5,centerY: Double=0.5,
                     sizeX: Double=0.1,sizeY: Double=0.1) throws -> Image {
        guard input.width>0,input.height>0,
              input.width<=Int.max/input.height,
              input.width*input.height<=Int.max/3,
              input.rgb.count==input.width*input.height*3 else {
            throw Failure.invalid("原版裁剪必须是完整 Float64 H×W×3")
        }
        let rect=try region(imageWidth:input.width,imageHeight:input.height,
                            centerX:centerX,centerY:centerY,
                            sizeX:sizeX,sizeY:sizeY)
        var result=[Double]()
        result.reserveCapacity(rect.width*rect.height*3)
        for y in rect.y..<(rect.y+rect.height) {
            let start=(y*input.width+rect.x)*3
            let end=start+rect.width*3
            result.append(contentsOf:input.rgb[start..<end])
        }
        return Image(width:rect.width,height:rect.height,rgb:result)
    }
}
