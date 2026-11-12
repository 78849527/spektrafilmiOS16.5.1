import Foundation

/// Original Python default CAM16-UCS perceptual gamut compression, baked
/// offline with colour-science and actual source gamut_compression.py.
/// Mobile evaluates the source table by trilinear interpolation in an
/// extended linear-sRGB region [-0.25, 1.75]. Values outside this finite
/// table use the source-supported ACES alternative, and thus do not
/// claim exact default CAM16 behaviour out of its baked domain.
///
/// This is loaded LAZILY only when a user explicitly selects CAM16,
/// keeping the known-stable iOS16.5.1 startup path unchanged.
enum OriginalCAM16Gamut {
    static var invalidSourceNodes: Int {
        GeneratedCAM16Gamut.invalidSourceNodes
    }
    static let dimension = GeneratedCAM16Gamut.dimension
    static let minimum = GeneratedCAM16Gamut.minimum
    static let maximum = GeneratedCAM16Gamut.maximum

    private static let values: [Float] = {
        guard let bytes = Data(base64Encoded: GeneratedCAM16Gamut.payload),
              bytes.count == dimension*dimension*dimension*3*4 else {
            return []
        }
        // Carefully decode unaligned little-endian float32 bytes.
        let source = [UInt8](bytes)
        let count = source.count/4
        var result = [Float](repeating: 0, count: count)
        for j in 0..<count {
            let start = j*4
            let bits = UInt32(source[start]) |
                       UInt32(source[start+1]) << 8 |
                       UInt32(source[start+2]) << 16 |
                       UInt32(source[start+3]) << 24
            result[j] = Float(bitPattern: bits)
        }
        return result
    }()

    static func compress(_ rgb: [Double]) -> [Double] {
        guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite }),
              values.count == dimension*dimension*dimension*3 else {
            return OriginalScannerMath.compressACESRGC(rgb)
        }
        if rgb.contains(where: { $0 < minimum || $0 > maximum }) {
            return OriginalScannerMath.compressACESRGC(rgb)
        }
        let n=dimension
        let coords=rgb.map { ($0-minimum)/(maximum-minimum)*Double(n-1) }
        let indexes=coords.map { min(n-2,max(0,Int(floor($0)))) }
        let weights=(0..<3).map { min(1,max(0,coords[$0]-Double(indexes[$0]))) }
        var result=[Double](repeating:0,count:3)
        for db in 0...1 {
            let bz=indexes[2]+db
            let wb=db==0 ? 1-weights[2] : weights[2]
            for dg in 0...1 {
                let gy=indexes[1]+dg
                let wg=dg==0 ? 1-weights[1] : weights[1]
                for dr in 0...1 {
                    let rx=indexes[0]+dr
                    let wr=dr==0 ? 1-weights[0] : weights[0]
                    let w=wb*wg*wr
                    let start=((bz*n+gy)*n+rx)*3
                    for channel in 0..<3 {
                        result[channel] += w*Double(values[start+channel])
                    }
                }
            }
        }
        guard result.allSatisfy({ $0.isFinite }) else {
            return OriginalScannerMath.compressACESRGC(rgb)
        }
        return result
    }

    /// Exact source grid points are verified against native Float32,
    /// independent arbitrary probes test interpolation error separately.
    static func sampleGridPoint(red: Int, green: Int, blue: Int) -> [Double] {
        let n=dimension
        guard (0..<n).contains(red), (0..<n).contains(green),
              (0..<n).contains(blue), values.count==n*n*n*3 else {
            return []
        }
        let start=((blue*n+green)*n+red)*3
        return [Double(values[start]),Double(values[start+1]),
                Double(values[start+2])]
    }
}
