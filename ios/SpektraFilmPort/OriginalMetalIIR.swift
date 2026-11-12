import Foundation
import Metal

/// Native four-sweep translation of src/spektrafilm/utils/fast_gaussian_filter.py:
/// _yvv_coeffs, _iir_horizontal and _iir_vertical.
/// This independent kernel is NOT yet connected to the production tiled
/// grain renderer: a YVV recurrence needs the full image row/column.
/// Do not substitute tile-local filtering for this routine.
enum OriginalMetalIIR {
    enum Error: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    struct Parameters {
        var b: SIMD4<Float>
        var b1: SIMD4<Float>
        var b2: SIMD4<Float>
        var b3: SIMD4<Float>
        var width: UInt32
        var height: UInt32
    }

    struct Coefficients {
        let b: Double
        let b1: Double
        let b2: Double
        let b3: Double
    }

    /// Preserve source coefficient calculation in Float64; convert once for
    /// Metal Float32 execution. Float64/Float32 *bit parity* is not claimed.
    static func coefficients(sigma: Double) throws -> Coefficients {
        guard sigma.isFinite && sigma >= 3 else {
            throw Error.invalid("原版 IIR：sigma 必须 ≥ 3，其他情况应调用原版 reflect FIR")
        }
        let q: Double
        if sigma >= 2.5 {
            q = 0.98711 * sigma - 0.96330
        } else {
            q = 3.97156 - 4.14554 * sqrt(1 - 0.26891 * sigma)
        }
        let q2 = q*q
        let q3 = q2*q
        let b0 = 1.57825 + 2.44413*q + 1.4281*q2 + 0.422205*q3
        let b1 = 2.44413*q + 2.85619*q2 + 1.26661*q3
        let b2 = -(1.4281*q2 + 1.26661*q3)
        let b3 = 0.422205*q3
        let b = 1.0 - (b1+b2+b3)/b0
        let values = [b, b1/b0, b2/b0, b3/b0]
        guard values.allSatisfy({ $0.isFinite }) else {
            throw Error.invalid("原版 IIR：系数溢出或非有限")
        }
        return Coefficients(b: values[0], b1: values[1],
                            b2: values[2], b3: values[3])
    }

    static func parameters(sigmas: [Double], width: Int,
                           height: Int) throws -> Parameters {
        guard sigmas.count == 3, width > 0, height > 0,
              width <= 50_000, height <= 50_000 else {
            throw Error.invalid("原版 IIR：尺寸或通道数无效")
        }
        let c = try sigmas.map { try coefficients(sigma: $0) }
        return Parameters(
            b: SIMD4<Float>(Float(c[0].b),Float(c[1].b),Float(c[2].b),0),
            b1: SIMD4<Float>(Float(c[0].b1),Float(c[1].b1),Float(c[2].b1),0),
            b2: SIMD4<Float>(Float(c[0].b2),Float(c[1].b2),Float(c[2].b2),0),
            b3: SIMD4<Float>(Float(c[0].b3),Float(c[1].b3),Float(c[2].b3),0),
            width: UInt32(width), height: UInt32(height)
        )
    }

    /// Four kernels: horizontal forward/backward, vertical forward/backward.
    /// One GPU thread owns a complete image row/column, keeping source
    /// recurrence order and endpoint-replication state initialization.
    /// Full-frame only; callers must not pass a grain tile.
    static func filter(_ source: MTLTexture, sigmas: [Double],
                       device: MTLDevice, library: MTLLibrary,
                       queue: MTLCommandQueue) throws -> MTLTexture {
        guard source.pixelFormat == .rgba32Float else {
            throw Error.invalid("原版 IIR：输入必须为 RGBA Float32 光学密度")
        }
        var args = try parameters(sigmas: sigmas,
                                  width: source.width, height: source.height)
        func make() throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: source.width,
                height: source.height, mipmapped: false)
            d.storageMode = .shared
            d.usage = [.shaderRead, .shaderWrite]
            guard let t = device.makeTexture(descriptor: d) else {
                throw Error.invalid("原版 IIR：GPU 全图纹理分配失败，禁止降级")
            }
            return t
        }
        let scratchA = try make()
        let scratchB = try make()
        let result = try make()
        guard let command = queue.makeCommandBuffer() else {
            throw Error.invalid("原版 IIR：命令缓冲区创建失败")
        }
        let passes: [(String,MTLTexture,MTLTexture,Int)] = [
            ("originalFilmIIRHorizontalForward",source,scratchA,source.height),
            ("originalFilmIIRHorizontalBackward",scratchA,scratchB,source.height),
            ("originalFilmIIRVerticalForward",scratchB,scratchA,source.width),
            ("originalFilmIIRVerticalBackward",scratchA,result,source.width)
        ]
        for (name, input, output, count) in passes {
            guard let f = library.makeFunction(name:name) else {
                throw Error.invalid("原版 IIR：缺少 Metal 内核 " + name)
            }
            let pipeline = try device.makeComputePipelineState(function:f)
            guard let encoder = command.makeComputeCommandEncoder() else {
                throw Error.invalid("原版 IIR：GPU 编码器创建失败")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input,index:0)
            encoder.setTexture(output,index:1)
            encoder.setBytes(&args,length:MemoryLayout<Parameters>.stride,index:0)
            let threads = MTLSize(width: min(32,pipeline.maxTotalThreadsPerThreadgroup),
                                  height:1,depth:1)
            encoder.dispatchThreadgroups(
                MTLSize(width:(count+threads.width-1)/threads.width,
                        height:1,depth:1),threadsPerThreadgroup:threads)
            encoder.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw Error.invalid("原版 IIR：GPU 递归执行失败：" +
                                (command.error?.localizedDescription ?? "unknown"))
        }
        return result
    }

    /// On-device equivalent to the CI IIR shader check, independent from
    /// virtualized GitHub Intel GPU execution. All 3 channels are checked.
    static func hardwareDiagnostic() throws -> String {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Error.invalid("原版 IIR 自检：本机 Metal GPU 不可用")
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        let fixtures = GeneratedSourceIIRReference.cases
        guard fixtures.count >= 2 else {
            throw Error.invalid("原版 IIR 自检：Python 参考数据未打包")
        }
        var totalError = 0.0
        var largestError = 0.0
        for fixture in fixtures {
            let w = fixture.width
            let h = fixture.height
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let source = device.makeTexture(descriptor: descriptor) else {
                throw Error.invalid("原版 IIR 自检：测试纹理分配失败")
            }
            guard fixture.input.count == w*h*3,
                  fixture.expected.count == fixture.input.count else {
                throw Error.invalid("原版 IIR 自检：Python 测试向量尺寸错误")
            }
            var values = [Float](repeating: 1, count: w*h*4)
            for pixel in 0..<(w*h) {
                for channel in 0..<3 {
                    values[pixel*4+channel] = Float(fixture.input[pixel*3+channel])
                }
            }
            values.withUnsafeBytes { bytes in
                source.replace(region: MTLRegionMake2D(0,0,w,h),
                               mipmapLevel: 0,
                               withBytes: bytes.baseAddress!,
                               bytesPerRow: w*4*MemoryLayout<Float>.stride)
            }
            let result = try filter(source, sigmas: fixture.sigmas,
                                    device: device, library: library, queue: queue)
            var observed = [Float](repeating: 0, count: w*h*4)
            observed.withUnsafeMutableBytes { bytes in
                result.getBytes(bytes.baseAddress!,
                                bytesPerRow: w*4*MemoryLayout<Float>.stride,
                                from: MTLRegionMake2D(0,0,w,h),
                                mipmapLevel: 0)
            }
            for pixel in 0..<(w*h) {
                for channel in 0..<3 {
                    let actual = Double(observed[pixel*4+channel])
                    let expected = fixture.expected[pixel*3+channel]
                    let error = abs(actual - expected)
                    guard actual.isFinite && error <= 0.0005 else {
                        throw Error.invalid(
                            "原版 IIR 真机对照失败：\(fixture.name) 像素\(pixel) / 通道\(channel)，实测\(actual)，源\(expected)，误差\(error)"
                        )
                    }
                    totalError += error
                    largestError = max(largestError,error)
                }
            }
        }
        let count = fixtures.reduce(0) { $0 + $1.expected.count }
        return "原版 YVV IIR 两组图 / 三通道对照 PASS，" +
               "MAE=\(String(format:"%.7g",totalError/Double(count)))，" +
               "max=\(String(format:"%.7g",largestError))，设备\(device.name)"
    }

}
