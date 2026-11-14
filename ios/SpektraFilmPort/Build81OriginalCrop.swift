import Foundation

/// Build81/13: index-exact port of the pinned Python function:
/// spektrafilm.utils.crop_resize.crop_image.
///
/// Python sequence is deliberately retained:
///   flip(center) -> round(shape * center) ->
///   round(max(shape) * flip(size)) ->
///   round(center - size/2) -> int64 -> left clamp -> right clamp ->
///   NumPy [:] slice normalization.
/// np.round uses ties-to-even; .rounded(.toNearestOrEven) matches it.
/// Cropping copies source Float64 channel bits without ICC or resampling.
///
/// Empty Python slices cannot be represented as a valid source Frame:
/// these explicitly throw instead of silently replacing with another crop.
enum Build81OriginalCrop {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }

    struct Rect: Equatable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private static func integer(_ number: Double) throws -> Int {
        guard number.isFinite,
              number >= Double(Int.min / 4),
              number <= Double(Int.max / 4) else {
            throw Failure.invalid("Python crop index is nonfinite or outside native integer bounds")
        }
        return Int(number)
    }

    /// Python int64 slice: negative indexes are relative to source length
    /// even after the source's right-edge x0 = shape - size assignment.
    private static func normalisedSlice(
        rawStart: Int, requestedSize: Int, axisLength: Int
    ) throws -> Range<Int> {
        let rawStop = rawStart + requestedSize
        let start = min(axisLength, max(0,
            rawStart < 0 ? axisLength + rawStart : rawStart))
        let stop = min(axisLength, max(0,
            rawStop < 0 ? axisLength + rawStop : rawStop))
        guard stop > start else {
            throw Failure.invalid(
                "Python crop returned empty slice; refusing silent fallback to full frame"
            )
        }
        return start..<stop
    }

    static func geometry(
        width: Int, height: Int,
        center: (x: Double, y: Double) = (0.5, 0.5),
        size: (x: Double, y: Double) = (0.1, 0.1)
    ) throws -> Rect {
        guard width > 0, height > 0,
              width <= 8192, height <= 8192,
              center.x.isFinite, center.y.isFinite,
              size.x.isFinite, size.y.isFinite else {
            throw Failure.invalid("Original Python crop source geometry invalid")
        }
        // Source image.shape[0:2] = (height, width), after np.flip(center).
        let cnY = Double(height) * center.y
        let cnX = Double(width) * center.x
        let longSide = Double(max(height, width))
        let sizeY = try integer(
            (longSide * size.y).rounded(.toNearestOrEven)
        )
        let sizeX = try integer(
            (longSide * size.x).rounded(.toNearestOrEven)
        )
        var y0 = try integer(
            (cnY.rounded(.toNearestOrEven) - Double(sizeY)/2)
                .rounded(.toNearestOrEven)
        )
        var x0 = try integer(
            (cnX.rounded(.toNearestOrEven) - Double(sizeX)/2)
                .rounded(.toNearestOrEven)
        )
        // Preserve original sequential per-axis order and the case where
        // size > axis length causes x0 < 0 at the *second* clamp.
        if y0 < 0 { y0 = 0 }
        if x0 < 0 { x0 = 0 }
        if y0 + sizeY > height { y0 = height - sizeY }
        if x0 + sizeX > width { x0 = width - sizeX }

        let y = try normalisedSlice(
            rawStart:y0,requestedSize:sizeY,axisLength:height
        )
        let x = try normalisedSlice(
            rawStart:x0,requestedSize:sizeX,axisLength:width
        )
        return Rect(x:x.lowerBound,y:y.lowerBound,
                    width:x.count,height:y.count)
    }

    static func crop(
        _ source: OriginalSourcePixelIO.Frame,
        center: (x: Double, y: Double) = (0.5, 0.5),
        size: (x: Double, y: Double) = (0.1, 0.1)
    ) throws -> OriginalSourcePixelIO.Frame {
        guard source.width > 0,source.height > 0,
              source.width <= 8192,source.height <= 8192,
              source.width <= Int.max / source.height / 3,
              source.rgb.count == source.width * source.height * 3 else {
            throw Failure.invalid("Original Python crop input RGB dimensions mismatch")
        }
        let box = try geometry(
            width:source.width,height:source.height,
            center:center,size:size
        )
        var rgb=[Double]()
        rgb.reserveCapacity(box.width * box.height * 3)
        for y in box.y..<(box.y+box.height) {
            for x in box.x..<(box.x+box.width) {
                let index = (y*source.width+x)*3
                rgb.append(source.rgb[index])
                rgb.append(source.rgb[index+1])
                rgb.append(source.rgb[index+2])
            }
        }
        return OriginalSourcePixelIO.Frame(
            width:box.width,height:box.height,rgb:rgb
        )
    }
}
