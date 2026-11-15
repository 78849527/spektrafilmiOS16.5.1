import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// Build96 macOS file-level proof. THIS DOES NOT use RAF, X-T5 hardware,
// iOS16.5.1 physical memory, rawpy or production film stage parity.
func assertOrFail(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("Build96 TEST FAIL: " + message) }
}

let flat = CIImage(color: CIColor(red: 0.27, green: 0.56,
                                  blue: 0.91, alpha: 1))
    .cropped(to: CGRect(x:0,y:0,width:16,height:12))
let url = try Build96TIFF16Writer.write(flat)
defer { try? FileManager.default.removeItem(at:url) }
assertOrFail(url.pathExtension == "tiff", "real TIFF suffix")
assertOrFail(((try? Data(contentsOf:url).count) ?? 0) > 128, "encoded file bytes")
try Build96TIFF16Writer.verifyFile(url,width:16,height:12)
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Build96 TEST FAIL: image decoding")
}
assertOrFail(image.width == 16 && image.height == 12, "pixel dimensions")
assertOrFail(image.bitsPerComponent == 16, "actual stored 16-bit component")
assertOrFail(image.bitsPerPixel == 64 || image.bitsPerPixel == 48,
             "real 16-bit RGB(A) TIFF")
let high = try Build96TIFF16Writer.estimate(width:7728,height:5152)
assertOrFail(high > 1_500_000_000,
             "40 MP RGB16 must be denied until user picks safe size")
var invalidDenied = false
do { _ = try Build96TIFF16Writer.estimate(width:0,height:10) }
catch { invalidDenied = true }
assertOrFail(invalidDenied, "invalid geometry rejected")
print("PASS Build96 real RGB16 TIFF ImageIO output, IFD BitsPerSample=16, " +
      "stored 16-bit pixel proof, 40MP conservative preflight")
