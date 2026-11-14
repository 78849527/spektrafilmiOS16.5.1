import Foundation

/// Build81/13-15 bridge: real source-stage Float64 frames, no bitmap
/// conversion, 8-bit demotion, CIImage thumbnails or silent mode changes.
/// These methods require explicit caller selection; legacy previews and
/// original source exports remain unchanged by default.
extension OriginalSourcePixelIO {
    static func cropOriginal81(
        _ frame:Frame,
        centerX:Double=0.5,centerY:Double=0.5,
        sizeX:Double=0.1,sizeY:Double=0.1
    ) throws -> Frame {
        let source=Build81OriginalCrop.Image(
            width:frame.width,height:frame.height,rgb:frame.rgb
        )
        let cropped=try Build81OriginalCrop.crop(
            source,centerX:centerX,centerY:centerY,
            sizeX:sizeX,sizeY:sizeY
        )
        return Frame(width:cropped.width,height:cropped.height,rgb:cropped.rgb)
    }

    static func previewOriginal81(_ frame:Frame,maxSide:Int) throws -> Frame {
        let source=Build81OriginalCrop.Image(
            width:frame.width,height:frame.height,rgb:frame.rgb
        )
        let scaled=try Build81OriginalPreview.resizeForPreview(
            source,maxSide:maxSide
        )
        return Frame(width:scaled.width,height:scaled.height,rgb:scaled.rgb)
    }
}
