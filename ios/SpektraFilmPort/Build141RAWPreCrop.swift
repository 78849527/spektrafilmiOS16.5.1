import Foundation

/// Build141: intentional non-destructive RAW pre-optical crop.
/// Exact source rectangle is derived with the original Build81 crop
/// geometry (NumPy nearest/even rounding); only PACKED LibRaw ACES16
/// pixels are sliced. No gamma, demosaic change, LUT or Float32 resizing.
/// This is NOT visually identical to cropping a full optical render after
/// spatial DIR, halation, grain or FFT diffusion at original borders.
enum Build141RAWPreCrop {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let msg)=self {return msg}
            return nil
        }
    }

    struct Selection: Equatable {
        let sourceWidth:Int
        let sourceHeight:Int
        let x:Int
        let y:Int
        let width:Int
        let height:Int

        var isWholeSource:Bool {
            x==0 && y==0 && width==sourceWidth && height==sourceHeight
        }

        func validate() throws {
            guard sourceWidth>0,sourceHeight>0,
                  sourceWidth<=8192,sourceHeight<=8192,
                  sourceWidth<=13_000_000/sourceHeight,
                  x>=0,y>=0,width>=64,height>=64,
                  x<=sourceWidth-width,
                  y<=sourceHeight-height,
                  width<=13_000_000/height else {
                throw Failure.invalid(
                    "RAW 冲印前裁切越界或小于 64×64；原片未改变"
                )
            }
        }
    }

    static func selection(
        sourceWidth:Int,sourceHeight:Int,
        normalizedX:Double,normalizedY:Double,
        normalizedWidth:Double,normalizedHeight:Double
    ) throws -> Selection {
        guard sourceWidth>0,sourceHeight>0,
              sourceWidth<=8192,sourceHeight<=8192,
              sourceWidth<=13_000_000/sourceHeight,
              [normalizedX,normalizedY,normalizedWidth,normalizedHeight]
                .allSatisfy({$0.isFinite}),
              normalizedX>=0,normalizedY>=0,
              normalizedWidth>0,normalizedHeight>0,
              normalizedX+normalizedWidth<=1.00000001,
              normalizedY+normalizedHeight<=1.00000001 else {
            throw Failure.invalid(
                "RAW 裁切比例不合法；保留上次已确认的范围"
            )
        }
        let longest=Double(max(sourceWidth,sourceHeight))
        let region=try Build81OriginalCrop.region(
            imageWidth:sourceWidth,imageHeight:sourceHeight,
            centerX:normalizedX+normalizedWidth/2.0,
            centerY:normalizedY+normalizedHeight/2.0,
            sizeX:normalizedWidth*Double(sourceWidth)/longest,
            sizeY:normalizedHeight*Double(sourceHeight)/longest
        )
        let crop=Selection(
            sourceWidth:sourceWidth,sourceHeight:sourceHeight,
            x:region.x,y:region.y,width:region.width,height:region.height
        )
        try crop.validate()
        return crop
    }

    /// Create cropped packed 16-bit RGB with one source-frame scanline copy
    /// at a time. Crucially allocate NO original-sized Float64 frame.
    static func cropPackedRGB16(
        _ data:Data,sourceWidth:Int,sourceHeight:Int,
        selection:Selection
    ) throws -> Data {
        try selection.validate()
        guard sourceWidth==selection.sourceWidth,
              sourceHeight==selection.sourceHeight,
              data.count==sourceWidth*sourceHeight*6 else {
            throw Failure.invalid(
                "RAW 裁切的原始解码尺寸与已确认的坐标不同；拒绝错位冲印"
            )
        }
        if selection.isWholeSource {return data}
        let rowBytes=selection.width*6
        var cropped=Data(count:rowBytes*selection.height)
        data.withUnsafeBytes { input in
            cropped.withUnsafeMutableBytes { output in
                guard let inputPtr=input.baseAddress,
                      let outputPtr=output.baseAddress else {return}
                for row in 0..<selection.height {
                    let sourceOffset=(
                        (selection.y+row)*sourceWidth+selection.x
                    )*6
                    let targetOffset=row*rowBytes
                    outputPtr.advanced(by:targetOffset).copyMemory(
                        from:inputPtr.advanced(by:sourceOffset),
                        byteCount:rowBytes
                    )
                }
            }
        }
        return cropped
    }
}
