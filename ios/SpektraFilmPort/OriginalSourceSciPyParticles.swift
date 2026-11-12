import Foundation
import CoreImage
import Metal

/// Production, opt-in SciPy-sequence particle field builder.
///
/// Upstream grain.py does NOT draw each pixel independently:
///   for ch in 0..<3 {
///     for sl in 0..<3 {
///       np.random.seed(ch + sl * 10)
///       poisson = scipy.stats.poisson.rvs(n / saturation) // WHOLE IMAGE
///       developed = scipy.stats.binom.rvs(poisson, p)    // WHOLE IMAGE
///       density = Double(developed) * (fullMax/n) * saturation
///     }
///   }
///
/// Each complete (layer,channel) is generated sequentially in ROW-MAJOR
/// order using the source NumPy MT19937/Poisson/Binomial engine. The renderer
/// then uses the already validated Metal FIR/IIR and density composition.
/// GPU input, transport and shader arithmetic remain Float32, so this is
/// source-equivalent RNG COUNTS given identical parameters, not a claim of
/// end-to-end bit-exact Python/RAW/RGB output.
///
/// Memory: one 4-byte/channel readback, a 4-byte/pixel Poisson count plane,
/// and a single 16-byte/pixel buffer-backed RGBA32Float result per emulsion
/// layer. No nine-field array, full Float64 image or independent tile RNG.
enum OriginalSourceSciPyParticles {
    struct Result {
        let texture: MTLTexture
        // Explicitly retain the shared backing until the consuming GPU
        // command buffer has completed.
        let backingBuffer: MTLBuffer
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    /// Flat CPU buffer indexes match NumPy C-order (y * width + x).
    static func renderLayer(
        normalizedLayer: MTLTexture,
        sublayer: Int,
        physical: OriginalMetalGrain.PhysicalCoefficients,
        pixelUM: Double,
        device: MTLDevice,
        queue: MTLCommandQueue,
        library: MTLLibrary
    ) throws -> Result {
        let w = normalizedLayer.width
        let h = normalizedLayer.height
        guard normalizedLayer.pixelFormat == .rgba32Float,
              (0..<3).contains(sublayer),
              w > 0, h > 0,
              w <= 50_000, h <= 50_000,
              pixelUM.isFinite && pixelUM > 0 else {
            throw Failure.invalid("原版 SciPy 显影：图像尺寸或亚层参数不正确")
        }
        let count = w * h
        guard count <= Int.max / 32 else {
            throw Failure.invalid("原版 SciPy 显影：照片尺寸超出地址空间")
        }
        let alignment = max(
            16, device.minimumLinearTextureAlignment(for: .rgba32Float)
        )
        let rowBytes = ((w * 16 + alignment - 1) / alignment) * alignment
        guard rowBytes <= Int.max / h,
              count * 4 <= device.maxBufferLength,
              rowBytes * h <= device.maxBufferLength else {
            throw Failure.invalid("原版 SciPy 显影：CPU/GPU 共享显影缓冲超出设备能力")
        }
        guard let channelBuffer = device.makeBuffer(
                  length: count * 4, options: .storageModeShared
              ),
              let resultBuffer = device.makeBuffer(
                  length: rowBytes * h, options: .storageModeShared
              ),
              let function = library.makeFunction(
                  name: "originalFilmSourceExtractChannel"
              ) else {
            throw Failure.invalid("原版 SciPy 显影：共享内存不足或缺少读取内核")
        }
        let extraction = try device.makeComputePipelineState(function: function)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: w, height: h, mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.shaderRead]
        guard let output = resultBuffer.makeTexture(
            descriptor: textureDescriptor, offset: 0,
            bytesPerRow: rowBytes
        ) else {
            throw Failure.invalid("原版 SciPy 显影：本机不支持线性共享 Float32 GPU 纹理")
        }
        let widthFloats = rowBytes / MemoryLayout<Float>.stride
        let rgba = resultBuffer.contents().bindMemory(
            to: Float.self, capacity: rowBytes * h / 4
        )
        let samples = channelBuffer.contents().bindMemory(
            to: Float.self, capacity: count
        )
        // Source arrays are C-order, CHANNEL-LAST. The source processes
        // one whole channel per seeded sublayer: never reseed per 512px tile.
        for ch in 0..<3 {
            guard let command = queue.makeCommandBuffer() else {
                throw Failure.invalid("原版 SciPy 显影：GPU 通道读取指令创建失败")
            }
            var channel = UInt32(ch)
            try OriginalMetalGrain.execute(
                command: command, pipeline: extraction,
                textures: [normalizedLayer], params: &channel,
                width: w, height: h, errors: channelBuffer
            )
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw Failure.invalid(
                    "原版 SciPy 显影：读取乳剂层 \(sublayer) 通道 \(ch) 失败：" +
                    (command.error?.localizedDescription ?? "unknown")
                )
            }

            let fraction = physical.fraction[sublayer][ch]
            let maxD = physical.maxima[sublayer][ch]
            let fullMax = maxD + 0.03 * fraction
            let n = pixelUM * pixelUM * fraction /
                (0.2 * [1.6, 1.6, 3.2][ch] * [2.0, 1.0, 0.5][sublayer])
            let uniformity = [0.97, 0.99, 0.97][ch]
            guard fullMax.isFinite && n.isFinite && n > 0 &&
                  uniformity > 0 && uniformity < 1 else {
                throw Failure.invalid("原版 SciPy 显影：光学密度或每像素粒子参数无效")
            }
            let odParticle = fullMax / n

            // Two full, sequential array phases per source channel.
            // UInt32 retains all sample counts up to 2^32-1; overflow
            // explicitly fails instead of silently wrapping or clipping.
            var seeds = [UInt32](repeating: 0, count: count)
            var random = OriginalSourceSciPySampler(
                seed: UInt32(ch + sublayer * 10)
            )
            for i in 0..<count {
                let y = i / w
                let x = i % w
                let normalized = Double(samples[i])
                guard normalized.isFinite else {
                    throw Failure.invalid("原版 SciPy 显影：乳剂层输入存在 NaN/Inf")
                }
                let d = min(1.0, max(0.0, normalized)) * maxD +
                    0.03 * fraction
                let p = min(1.0 - 1e-6, max(1e-6, d / fullMax))
                let saturation = 1.0 - p * uniformity * (1.0 - 1e-6)
                let draw = try random.poisson(n / saturation)
                guard draw >= 0 && draw <= Int64(UInt32.max) else {
                    throw Failure.invalid(
                        "原版 SciPy 显影：亚层 \(sublayer) 通道 \(ch) " +
                        "像素(\(x),\(y)) Poisson 粒子数超出 Uint32 范围，禁止截断"
                    )
                }
                seeds[i] = UInt32(draw)
            }
            for i in 0..<count {
                let normalized = Double(samples[i])
                let d = min(1.0, max(0.0, normalized)) * maxD +
                    0.03 * fraction
                let p = min(1.0 - 1e-6, max(1e-6, d / fullMax))
                let saturation = 1.0 - p * uniformity * (1.0 - 1e-6)
                let draw = try random.binomial(
                    Int64(seeds[i]), probability: p
                )
                let density = Double(draw) * odParticle * saturation
                guard density.isFinite &&
                      abs(density) <= Double(Float.greatestFiniteMagnitude) else {
                    throw Failure.invalid("原版 SciPy 显影：粒子光学密度溢出")
                }
                let y = i / w
                let x = i % w
                let pixel = y * widthFloats + x * 4
                rgba[pixel + ch] = Float(density)
                if ch == 0 { rgba[pixel + 3] = 1 }
            }
        }
        return Result(texture: output, backingBuffer: resultBuffer)
    }

    /// Lower bound is intentionally conservative: all working GPU fields,
    /// two shared transport buffers, Poisson seeds and CI intermediates.
    static func validateMemory(width: Int, height: Int,
                               physicalMemory: UInt64) throws {
        guard width > 0, height > 0,
              width <= 50_000, height <= 50_000 else {
            throw Failure.invalid("原版 SciPy 高清显影：尺寸无效")
        }
        let pixels = UInt64(width) * UInt64(height)
        let projected = pixels * 104
        let budget = min(UInt64(1_500_000_000), physicalMemory / 3)
        guard projected <= budget else {
            throw Failure.invalid(
                "原版 SciPy 高清显影需要约 \(projected/1_000_000) MB，" +
                "本机安全预算 \(budget/1_000_000) MB。已停止，" +
                "不会分块重置随机数或降为近似算法。可关闭 SciPy 原版随机数使用现有 Metal 路径。"
            )
        }
    }
}
