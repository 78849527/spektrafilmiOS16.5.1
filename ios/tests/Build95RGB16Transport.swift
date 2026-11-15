import Foundation
import CoreGraphics
import CoreImage

// Build95 native CoreGraphics 48-bit transport sanity test (macOS only).
// No camera RAW fixture, no iOS physical certification, no rawpy parity.
let width = 3, height = 2
let samples: [UInt16] = [
    0, 1024, 65535, 32768, 14567, 8192, 65535, 65534, 0,
    556, 62800, 12600, 1, 30122, 45123, 40000, 50000, 60000
]
var bytes = [UInt8]()
for value in samples {
    bytes.append(UInt8(truncatingIfNeeded: value))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
}
let data = Data(bytes)
guard data.count == width * height * 3 * 2,
      let provider = CGDataProvider(data: data as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Build95 test invalid input provider")
}
let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue |
                                  CGBitmapInfo.byteOrder16Little.rawValue)
guard let cg = CGImage(
    width: width, height: height,
    bitsPerComponent: 16, bitsPerPixel: 48,
    bytesPerRow: width * 6, space: space,
    bitmapInfo: info, provider: provider, decode: nil,
    shouldInterpolate: false, intent: .defaultIntent
) else {
    fatalError("Build95 48-bit RGB CGImage creation failed (do not downgrade)")
}
guard cg.bitsPerComponent == 16,
      cg.bitsPerPixel == 48,
      let recovered = cg.dataProvider?.data as Data?,
      recovered == data else {
    fatalError("Build95 original UInt16 byte stream changed in CGImage provider")
}
let ci = CIImage(cgImage: cg, options: [.colorSpace: space])
let context = CIContext(options: [.cacheIntermediates: false])
var result = [Float](repeating: .nan, count: width * height * 4)
result.withUnsafeMutableBytes { buffer in
    context.render(
        ci, toBitmap: buffer.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: CGRect(x: 0, y: 0, width: width, height: height),
        format: .RGBAf, colorSpace: space
    )
}
guard result.allSatisfy({$0.isFinite}) else {
    fatalError("Build95 Core Image 16-bit RGB input did not render finite pixels")
}
print("PASS Build95 macOS 16-bit native-endian RGB48 -> CGImage -> CIImage -> RGBAf; does not certify iOS16.5.1/RAW")
