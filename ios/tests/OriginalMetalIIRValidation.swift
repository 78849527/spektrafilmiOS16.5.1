import Foundation
import Metal

/// Actual Metal GPU vs original Numba YVV IIR on all pixels/channels.
/// This test intentionally fails if the runner has nonfunctional GPU output.
@main
struct OriginalMetalIIRValidation {
    static func near(_ a: Double, _ b: Double, tolerance: Double,
                     description: String) {
        precondition(a.isFinite && b.isFinite && abs(a-b) < tolerance,
                     "\(description): GPU=\(a) source=\(b)")
    }

    static func main() throws {
        setbuf(stdout,nil)
        let cases = GeneratedSourceIIRReference.cases
        precondition(cases.count == 2)
        let allSigma = [3.0,5.0,7.5,3.2,3.4,4.1]
        for (i,sigma) in allSigma.enumerated() {
            let actual = try OriginalMetalIIR.coefficients(sigma:sigma)
            let expected = GeneratedSourceIIRReference.coefficients[i]
            for (a,b) in zip([actual.b,actual.b1,actual.b2,actual.b3],
                             expected) {
                near(a,b,tolerance:1e-12,
                     description:"Float64 source IIR coefficient \(sigma)")
            }
        }
        print("PASS: original Float64 YVV coefficients at 6 source sigma values")
        guard CommandLine.arguments.count > 1 else {
            fatalError("Pass a compiled original grain .metallib as argument")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("GPU required: do not certify an unexecuted shader")
        }
        let library = try device.makeLibrary(
            URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        for c in cases {
            precondition(c.input.count == c.width*c.height*3)
            precondition(c.expected.count == c.input.count)
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat:.rgba32Float,width:c.width,height:c.height,
                mipmapped:false)
            d.storageMode = .shared
            d.usage = [.shaderRead,.shaderWrite]
            guard let input = device.makeTexture(descriptor:d) else {
                fatalError("Metal input texture allocation failed")
            }
            var raw = [Float](repeating:1,count:c.width*c.height*4)
            for pixel in 0..<(c.width*c.height) {
                for ch in 0..<3 {
                    raw[pixel*4+ch] = Float(c.input[pixel*3+ch])
                }
            }
            raw.withUnsafeBytes { bytes in
                input.replace(
                    region:MTLRegionMake2D(0,0,c.width,c.height),
                    mipmapLevel:0,withBytes:bytes.baseAddress!,
                    bytesPerRow:c.width*4*MemoryLayout<Float>.stride)
            }
            let result = try OriginalMetalIIR.filter(
                input,sigmas:c.sigmas,device:device,library:library,queue:queue)
            var output = [Float](repeating:0,count:raw.count)
            output.withUnsafeMutableBytes { bytes in
                result.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow:c.width*4*MemoryLayout<Float>.stride,
                    from:MTLRegionMake2D(0,0,c.width,c.height),
                    mipmapLevel:0)
            }
            var mae = 0.0
            var peak = 0.0
            for pixel in 0..<(c.width*c.height) {
                for ch in 0..<3 {
                    let observed = Double(output[pixel*4+ch])
                    let expected = c.expected[pixel*3+ch]
                    let error = abs(observed-expected)
                    mae += error
                    peak = max(peak,error)
                    near(observed,expected,tolerance:0.0005,
                         description:"source YVV \(c.name) pixel \(pixel) channel \(ch)")
                }
            }
            // Same source fixture, using the production in-place pipeline.
            guard let inplaceCommand = queue.makeCommandBuffer() else {
                fatalError("In-place YVV command allocation failed")
            }
            try OriginalMetalIIR.encodeInPlace(
                input, sigmas: c.sigmas, device: device,
                library: library, command: inplaceCommand
            )
            inplaceCommand.commit()
            inplaceCommand.waitUntilCompleted()
            precondition(inplaceCommand.status == .completed,
                         "Production in-place YVV GPU execution failed")
            var inPlacePixels = [Float](repeating: 0, count: raw.count)
            inPlacePixels.withUnsafeMutableBytes { bytes in
                input.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow: c.width*4*MemoryLayout<Float>.stride,
                    from: MTLRegionMake2D(0,0,c.width,c.height),
                    mipmapLevel: 0
                )
            }
            for pixel in 0..<(c.width*c.height) {
                for channel in 0..<3 {
                    near(Double(inPlacePixels[pixel*4+channel]),
                         c.expected[pixel*3+channel],tolerance:0.0005,
                         description:"production YVV in-place source parity")
                }
            }
            // Mixed channels use original FIR path: IIR must preserve them.
            raw.withUnsafeBytes { bytes in
                input.replace(
                    region:MTLRegionMake2D(0,0,c.width,c.height),
                    mipmapLevel:0,withBytes:bytes.baseAddress!,
                    bytesPerRow:c.width*4*MemoryLayout<Float>.stride
                )
            }
            guard let mixedCommand = queue.makeCommandBuffer() else {
                fatalError("Mixed YVV command allocation failed")
            }
            try OriginalMetalIIR.encodeInPlace(
                input, sigmas:[c.sigmas[0],0,c.sigmas[2]],
                device:device, library:library, command:mixedCommand
            )
            mixedCommand.commit()
            mixedCommand.waitUntilCompleted()
            precondition(mixedCommand.status == .completed)
            inPlacePixels.withUnsafeMutableBytes { bytes in
                input.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow:c.width*4*MemoryLayout<Float>.stride,
                    from:MTLRegionMake2D(0,0,c.width,c.height),mipmapLevel:0
                )
            }
            for pixel in 0..<(c.width*c.height) {
                for channel in 0..<3 {
                    let expected = channel == 1 ?
                        c.input[pixel*3+channel] : c.expected[pixel*3+channel]
                    near(Double(inPlacePixels[pixel*4+channel]),expected,
                         tolerance:0.0005,
                         description:"mixed FIR(identity)/YVV routing")
                }
            }
            print("PASS: production whole-frame in-place YVV and mixed sigma channel routing")
            mae /= Double(c.expected.count)
            print("PASS: real GPU YVV \(c.name) \(c.width)x\(c.height), " +
                  "MAE=\(mae), maxAbs=\(peak), device=\(device.name)")
        }
    }
}
