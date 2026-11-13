import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import CoreGraphics

/// Source-ordered Spektrafilm optical-grain GPU path:
///   3 measured H-D sublayers -> 9 stochastic developer particle processes
///   -> per-layer/channel dye-cloud blur
///   -> sum layers -> conditional lognormal microstructure
///   -> subtract density_min -> original reflect Gaussian(0.65 px)
///   -> optical paper / scan LUT.
///
/// Source equations and thresholds from spektrafilm/model/grain.py:
/// layer_particle_model, apply_grain_to_density_layers, add_micro_structure.
/// This implementation uses the Poisson-thinning identity for the exact
/// marginal particle-count distribution, instead of SciPy's two RNG calls.
/// It does NOT reproduce SciPy's random streams or guarantee float64/float32
/// bit equality; export and preview use identical Metal source laws.
/// No approximate CI Gaussian or silent fallback is permitted here.
enum OriginalMetalGrain {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    struct Parameters {
        var ranges: SIMD4<Float>
        var peak0: SIMD4<Float>
        var peak1: SIMD4<Float>
        var peak2: SIMD4<Float>
        var fraction0: SIMD4<Float>
        var fraction1: SIMD4<Float>
        var fraction2: SIMD4<Float>
        var pixelUM: Float
        var amount: Float
        var seed: UInt32
        var originX: UInt32
        var originY: UInt32
        var width: UInt32
        var height: UInt32
        var microSigma: Float
        var microBlur: Float
    }

    struct BlurParameters {
        var sigma: SIMD4<Float>
        var width: UInt32
        var height: UInt32
        var axis: UInt32
        var unused: UInt32 = 0
    }

    struct CoreParameters {
        var ranges: SIMD4<Float>
        var amount: Float
        var width: UInt32
        var height: UInt32
        var originX: UInt32
        var originY: UInt32
        var coreX: UInt32
        var coreY: UInt32
        var coreWidth: UInt32
        var coreHeight: UInt32
    }

    struct PhysicalCoefficients {
        let maxima: [[Double]]
        let fraction: [[Double]]
        let cloudSigmas: [[Double]]
        let microSigma: Double
        let microBlur: Double
        let halo: Int
    }

    /// Public so numeric tests can compare each coefficient directly
    /// against upstream NumPy. Unit: optical-density Gaussian sigma pixels.
    static func physicalCoefficients(
        maxima rawMaxima: [Double], pixelUM: Double
    ) throws -> PhysicalCoefficients {
        guard rawMaxima.count == 9, pixelUM.isFinite,
              pixelUM > 0,
              rawMaxima.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw Failure.invalid("原版 Metal 颗粒：乳剂参数或像素尺寸无效")
        }
        let sublayerScales = [2.0, 1.0, 0.5]
        let channelScales = [1.6, 1.6, 3.2]
        let densityMinimum = [0.03, 0.03, 0.03]
        var maxima = [[Double]](repeating: [0, 0, 0], count: 3)
        var fractions = [[Double]](repeating: [0, 0, 0], count: 3)
        var cloud = [[Double]](repeating: [0, 0, 0], count: 3)

        for ch in 0..<3 {
            let total = (0..<3).reduce(0.0) {
                $0 + rawMaxima[$1 * 3 + ch]
            }
            guard total > 0 else {
                throw Failure.invalid("原版 Metal 颗粒：胶片亚层总密度为零")
            }
            for layer in 0..<3 {
                let maxD = rawMaxima[layer * 3 + ch]
                let f = maxD / total
                let dMinLayer = densityMinimum[ch] * f
                let n = pixelUM * pixelUM * f /
                    (0.2 * channelScales[ch] * sublayerScales[layer])
                // Source blur_particle * sqrt(od_particle);
                // od_particle = density_max_layer_with_dmin / n_particles.
                maxima[layer][ch] = maxD
                fractions[layer][ch] = f
                cloud[layer][ch] = sqrt((maxD + dMinLayer) / n)
            }
        }
        // Source grain.py and Numba fast_stats.py deterministic physical
        // terms now share the independently validated original formula.
        let sourceMicro = try OriginalSourceMicrostructure.physical(
            pixelUM: pixelUM
        )
        let microSigma = sourceMicro.microStd
        let microBlur = sourceMicro.blur
        let useMicro = sourceMicro.enabled
        let useMicroBlur = useMicro && microBlur > 0.4
        let maxCloud = cloud.flatMap { $0 }.max() ?? 0
        // Composition of separately truncated kernels: each contribution
        // has a compact support; halo >= sum radii is exact within a tile.
        // These halo radii apply ONLY to the sigma<3 FIR tile path.
        // IIR is global (infinite recursive support) and uses no tile halo.
        guard maxCloud.isFinite, microBlur.isFinite else {
            throw Failure.invalid("原版 Metal 颗粒：非有限染料云或微结构扩散半径")
        }
        let cloudReach = Int(floor(3 * min(maxCloud, 2.999) + 0.5))
        let microReach = useMicroBlur ?
            Int(floor(3 * min(microBlur, 2.999) + 0.5)) : 0
        let finalReach = Int(floor(3 * 0.65 + 0.5))
        let halo = cloudReach + microReach + finalReach + 2
        guard halo <= 128 else {
            throw Failure.invalid("原版 Metal 颗粒：当前尺寸需要超过 128 像素边界，禁止近似截断")
        }
        return PhysicalCoefficients(
            maxima: maxima, fraction: fractions, cloudSigmas: cloud,
            microSigma: microSigma, microBlur: microBlur, halo: halo
        )
    }

    /// Original source dispatch: sigma<3 -> reflect FIR, sigma>=3 -> YVV IIR.
    /// Keep coefficients valid; global IIR is handled by the separate
    /// streaming whole-frame route, never inside a 512px FIR tile.
    static func requireSupportedOriginalFilters(_ coefficients: PhysicalCoefficients) throws {
        let dye = coefficients.cloudSigmas.flatMap { $0 }
        guard dye.allSatisfy({ $0.isFinite && $0 >= 0 }),
              coefficients.microBlur.isFinite &&
              coefficients.microBlur >= 0 else {
            throw Failure.invalid("原版 Metal 颗粒：滤波 sigma 无效")
        }
    }

    static func needsWholeFrameIIR(_ coefficients: PhysicalCoefficients) -> Bool {
        coefficients.cloudSigmas.flatMap { $0 }.contains(where: { $0 >= 3.0 }) ||
            (coefficients.microSigma > 0.05 &&
             coefficients.microBlur > 0.4 &&
             coefficients.microBlur >= 3.0)
    }

    private static func vec(_ values: [Double]) -> SIMD4<Float> {
        SIMD4<Float>(
            Float(values[0]), Float(values[1]), Float(values[2]), 0
        )
    }

    /// v1.8.18: test an actual iPhone Metal shader with source Float32
    /// pixels, BEFORE introducing any CIImage. Half-precision Core Image
    /// interop was measured separately on 1,287 upstream DIR channels.
    /// A pass establishes bit-preserving GPU Float32 transport only.
    static func float32BoundaryDiagnostic() throws -> String {
        guard let device=MTLCreateSystemDefaultDevice(),
              let queue=device.makeCommandQueue() else {
            throw Failure.invalid("原版 Float32 边界：Metal 设备不可用")
        }
        let library:MTLLibrary
        do {
            library=try device.makeDefaultLibrary(bundle:.main)
        } catch {
            throw Failure.invalid("原版 Float32 边界：Metal 库缺失：" +
                                  error.localizedDescription)
        }
        guard let kernel=library.makeFunction(name:"originalFilmFloat32Identity")
        else {
            throw Failure.invalid("原版 Float32 边界：缺少直通 shader")
        }
        let pipeline=try device.makeComputePipelineState(function:kernel)
        let width=7,height=3
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat:.rgba32Float,width:width,height:height,
            mipmapped:false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead,.shaderWrite]
        guard let input=device.makeTexture(descriptor:descriptor),
              let output=device.makeTexture(descriptor:descriptor) else {
            throw Failure.invalid("原版 Float32 边界：无法创建 rgba32Float 纹理")
        }
        // Values include the measured A15 Float16 mismatch and source RGB,
        // negative optical inputs, fine gradients and HDR density values.
        let sourceSamples:[Double]=[
            0.5383333333333333,0.5316666666666667,
            0.6521075409510532,0.6748881902555738,
            0.3639440958801252,0.8270770426900451,
            0.0000327417,0.3333333333333333,
            0.001953155,0.999971,1.000122,
            -0.7657427760812949,3.507948959803666,
            2.7068396842422735,8.838671846699366
        ]
        var pixels=[Float](repeating:1,count:width*height*4)
        var maxInputRound=0.0
        for p in 0..<(width*height) {
            for c in 0..<3 {
                let v=sourceSamples[(p*3+c)%sourceSamples.count]
                let quantized=Float(v)
                pixels[p*4+c]=quantized
                maxInputRound=max(maxInputRound,abs(Double(quantized)-v))
            }
        }
        pixels.withUnsafeBytes { bytes in
            input.replace(region:MTLRegionMake2D(0,0,width,height),
                          mipmapLevel:0,withBytes:bytes.baseAddress!,
                          bytesPerRow:width*MemoryLayout<Float>.size*4)
        }
        guard let command=queue.makeCommandBuffer(),
              let encoder=command.makeComputeCommandEncoder() else {
            throw Failure.invalid("原版 Float32 边界：无法创建 compute 指令")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input,index:0)
        encoder.setTexture(output,index:1)
        encoder.dispatchThreadgroups(
            MTLSize(width:(width+7)/8,height:(height+7)/8,depth:1),
            threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw Failure.invalid("原版 Float32 边界：GPU 执行失败：" +
                (command.error?.localizedDescription ?? "unknown"))
        }
        var result=[Float](repeating:0,count:pixels.count)
        result.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!,
                            bytesPerRow:width*MemoryLayout<Float>.size*4,
                            from:MTLRegionMake2D(0,0,width,height),
                            mipmapLevel:0)
        }
        for i in pixels.indices {
            guard pixels[i].bitPattern == result[i].bitPattern else {
                throw Failure.invalid(
                    "原版 Float32 边界：Metal bitwise 不一致，" +
                    "index=\(i) source=\(pixels[i]) GPU=\(result[i])"
                )
            }
        }
        return "原生 Metal rgba32Float（无 Core Image）· " +
            "\(width*height*3) 个 RGB 通道、\(width*height) 个 alpha PASS，" +
            "GPU UInt32 位模式完全一致；Double→Float32 最大输入量化=" +
            String(format:"%.9g",maxInputRound) +
            "。仅认证纹理数据传输，不代表整图原版算法。"
    }

    /// Run this on a REAL iPhone from the floating editor. GitHub's
    /// Intel VM accepted Metal command buffers but returned all zeros even
    /// for a constant-value passthrough shader. This separates unavailable
    /// runner graphics acceleration from errors in the physical grain model.
    /// It deliberately verifies two actual GPU kernels, not library presence.
    static func hardwareDiagnostic() throws -> String {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Failure.invalid("Metal 自检：找不到可执行计算内核的 GPU")
        }
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            throw Failure.invalid("Metal 自检：缺少随 App 打包的内核：" +
                                  error.localizedDescription)
        }
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw Failure.invalid("Metal 自检：缺少 GPU 内核 " + name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        let passthrough = try state("originalFilmDebugProbe")
        let sourceGaussian = try state("originalFilmGaussianReflect")

        let width = 11
        let height = 7
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width,
            height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let source = device.makeTexture(descriptor: descriptor),
              let destination = device.makeTexture(descriptor: descriptor)
        else {
            throw Failure.invalid("Metal 自检：GPU 无法分配 11×7 测试纹理")
        }
        var impulse = [Float](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for channel in 0..<4 {
                impulse[row * width * 4 + channel] = 1
            }
        }
        impulse.withUnsafeBytes { raw in
            source.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0, withBytes: raw.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }

        var args = BlurParameters(
            sigma: SIMD4<Float>(0.65, 0.65, 0.65, 0),
            width: UInt32(width), height: UInt32(height), axis: 0
        )
        func executeDiagnostic(_ pipeline: MTLComputePipelineState)
        throws -> [Float] {
            guard let command = queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder() else {
                throw Failure.invalid("Metal 自检：无法创建 GPU 指令")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.setBytes(
                &args, length: MemoryLayout<BlurParameters>.stride, index: 0
            )
            let group = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreadgroups(
                MTLSize(width: (width + 7) / 8,
                        height: (height + 7) / 8, depth: 1),
                threadsPerThreadgroup: group
            )
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw Failure.invalid(
                    "Metal 自检：GPU 指令执行失败：" +
                    (command.error?.localizedDescription ?? "unknown")
                )
            }
            var output = [Float](
                repeating: 0, count: width * height * 4
            )
            output.withUnsafeMutableBytes { bytes in
                destination.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                    from: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0
                )
            }
            return output
        }
        let p = try executeDiagnostic(passthrough)
        let actualSigma = Double(p[1])
        let shaderWidth = Double(p[2])
        guard abs(Double(p[0]) - 1) < 0.00001,
              abs(Double(p[3 * width * 4]) - 1) < 0.00001,
              abs(actualSigma - 0.65) < 0.00001,
              abs(shaderWidth - Double(width)) < 0.00001 else {
            throw Failure.invalid(
                "Metal 纹理透传失败：GPU=\(device.name), " +
                "输入=1, 输出=\(p[0]), sigma=\(actualSigma), " +
                "width=\(shaderWidth)"
            )
        }
        let filtered = try executeDiagnostic(sourceGaussian)
        // Actual upstream fast_gaussian_filter_small (reflect,
        // truncate=3.0): a unit impulse at the first column.
        let expectedEdge = 0.8013463515071368
        let observed = Double(filtered[3 * width * 4])
        let err = abs(observed - expectedEdge)
        guard err <= 0.0002 else {
            throw Failure.invalid(
                "Metal reflect 数值未对齐：GPU=\(device.name), " +
                "原版=\(expectedEdge), 实测=\(observed), " +
                "误差=\(err)"
            )
        }
        let float32Proof=try float32BoundaryDiagnostic()
        return "Metal 硬件自检通过 · \(device.name) · " +
            "纹理透传 PASS · reflect 误差 \(String(format: "%.7f", err))" + "\\n" + float32Proof
    }

    struct PoissonDiagnosticParameters {
        var lambda: Float
        var width: UInt32
        var height: UInt32
        var seed: UInt32
    }

    /// Explicit user-triggered, real-device diagnostic of the production
    /// Poisson kernel. This is not run during every preview or export.
    /// A pass proves basic GPU sampler convergence and distribution moments;
    /// it does not prove bitwise SciPy RNG/Float64 equivalence.
    static func poissonHardwareDiagnostic() throws -> String {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Failure.invalid("Poisson 自检：无法创建 Metal GPU 指令")
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        guard let function = library.makeFunction(
            name: "originalFilmPoissonDiagnostic"
        ) else {
            throw Failure.invalid("Poisson 自检：缺少原生采样诊断内核")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        let w = 192
        let h = 192
        let total = w * h
        guard let samples = device.makeBuffer(
            length: total * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ), let faults = device.makeBuffer(
            length: 4 * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            throw Failure.invalid("Poisson 自检：分配 GPU 数值缓冲失败")
        }
        let reasons = faults.contents().bindMemory(to: UInt32.self, capacity: 4)
        let counts = samples.contents().bindMemory(to: Float.self, capacity: total)
        for rate: Float in [0.1, 7.29, 22.71, 29.9, 30.0, 100.0, 1_000.0] {
            for i in 0..<4 { reasons[i] = 0 }
            var params = PoissonDiagnosticParameters(
                lambda: rate, width: UInt32(w), height: UInt32(h), seed: 8888
            )
            guard let command = queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder() else {
                throw Failure.invalid("Poisson 自检：GPU 计算任务创建失败")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(samples, offset: 0, index: 0)
            encoder.setBytes(
                &params, length: MemoryLayout<PoissonDiagnosticParameters>.stride,
                index: 1
            )
            encoder.setBuffer(faults, offset: 0, index: 2)
            let threads = min(64, pipeline.maxTotalThreadsPerThreadgroup)
            let group = MTLSize(width: threads, height: 1, depth: 1)
            encoder.dispatchThreadgroups(
                MTLSize(width: (total + threads - 1) / threads,
                        height: 1, depth: 1),
                threadsPerThreadgroup: group
            )
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw Failure.invalid(
                    "Poisson 自检：GPU 内核执行失败：" +
                    (command.error?.localizedDescription ?? "unknown")
                )
            }
            guard reasons[0] == 0 else {
                throw Failure.invalid(
                    "Poisson 自检：λ=\(rate) 出现 \(reasons[0]) 次采样失败，" +
                    "无效参数=\(reasons[1])、低率耗尽=\(reasons[2])、" +
                    "高率耗尽=\(reasons[3])"
                )
            }
            var sum = 0.0
            var sumSquares = 0.0
            for i in 0..<total {
                let sample = Double(counts[i])
                guard sample.isFinite && sample >= 0 &&
                      sample.rounded(.down) == sample else {
                    throw Failure.invalid("Poisson 自检：GPU 采样存在无效计数")
                }
                sum += sample
                sumSquares += sample * sample
            }
            let mean = sum / Double(total)
            let variance = sumSquares / Double(total) - mean * mean
            let expected = Double(rate)
            // Expected standard error of the mean is sqrt(lambda / N).
            // Use a seven-sigma guard instead of a fixed 0.5 count cutoff,
            // which incorrectly rejects correct high-rate Poisson samples.
            let meanTolerance = max(0.50, 7.0 * sqrt(expected / Double(total)))
            guard abs(mean - expected) < meanTolerance,
                  abs(variance - expected) / expected < 0.15 else {
                throw Failure.invalid(
                    "Poisson 自检：λ=\(rate) 统计量异常，" +
                    "均值=\(mean)，方差=\(variance)"
                )
            }
        }
        return "原生 Metal Poisson 7 档（含高率 PTRS）采样通过，" +
            "每档 36,864 点，无失效；非 SciPy 逐像素同序验证"
    }

    private static func makeTexture(
        _ device: MTLDevice, width: Int, height: Int,
        format: MTLPixelFormat = .rgba32Float
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw Failure.invalid("原版 Metal 颗粒：GPU 纹理内存不足")
        }
        return texture
    }

    static func execute<P>(
        command: MTLCommandBuffer, pipeline: MTLComputePipelineState,
        textures: [MTLTexture], params: inout P,
        width: Int, height: Int,
        errors: MTLBuffer? = nil,
        sublayer: UInt32? = nil
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw Failure.invalid("原版 Metal 颗粒：无法创建 GPU 计算指令")
        }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        // Params are plain SIMD/number POD in every source kernel.
        // Use an explicit byte view rather than a generic raw pointer.
        withUnsafeBytes(of: &params) { bytes in
            encoder.setBytes(
                bytes.baseAddress!, length: bytes.count, index: 0
            )
        }
        if let errors {
            encoder.setBuffer(errors, offset: 0, index: 1)
        }
        if var layer = sublayer {
            encoder.setBytes(&layer, length: MemoryLayout<UInt32>.stride,
                             index: 2)
        }
        let w = min(8, pipeline.threadExecutionWidth)
        let group = MTLSize(width: w, height: 8, depth: 1)
        // Integer-aligned threadgroups work on Intel Mac GPUs and older
        // iPhone Metal feature sets without nonuniform dispatch support.
        // All kernels explicitly guard the excess border threads.
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + group.width - 1) / group.width,
                height: (height + group.height - 1) / group.height,
                depth: 1
            ), threadsPerThreadgroup: group
        )
        encoder.endEncoding()
    }

    private static func blur(
        _ image: MTLTexture, sigmas: [Double],
        command: MTLCommandBuffer, device: MTLDevice,
        pipeline: MTLComputePipelineState
    ) throws -> MTLTexture {
        guard sigmas.count == 3, sigmas.allSatisfy({
            $0.isFinite && $0 >= 0 && Int(floor(3*$0+0.5)) <= 128
        }) else {
            throw Failure.invalid("原版 Metal 高斯滤波：无效或超出边界的 sigma")
        }
        // Upstream FIR runs vertical then horizontal; see axis=1 then axis=0.
        // Upstream fast_gaussian_filter dispatches sigma >= 3.0 to a
        // Young–van Vliet recursive IIR, not the reflect FIR kernel below.
        // That IIR has non-local support: substituting FIR or running IIR
        // inside a bounded tile would NOT reproduce the original image.
        // Explicitly fail until full-frame, source-ordered IIR and its
        // boundary/float parity have passed native GPU reference tests.
        guard sigmas.allSatisfy({ $0 < 3.0 }) else {
            throw Failure.invalid(
                "原版 Metal 颗粒：sigma ≥ 3 需要上游 Young–van Vliet IIR 全图滤波；当前尚未通过数值对照，禁止以 FIR 近似执行"
            )
        }
        if sigmas.allSatisfy({ $0 == 0 }) { return image }
        let scratch = try makeTexture(
            device, width: image.width, height: image.height
        )
        let output = try makeTexture(
            device, width: image.width, height: image.height
        )
        var args = BlurParameters(
            sigma: vec(sigmas), width: UInt32(image.width),
            height: UInt32(image.height), axis: 1
        )
        try execute(
            command: command, pipeline: pipeline,
            textures: [image, scratch], params: &args,
            width: image.width, height: image.height
        )
        args.axis = 0
        try execute(
            command: command, pipeline: pipeline,
            textures: [scratch, output], params: &args,
            width: image.width, height: image.height
        )
        return output
    }


    /// Whole-frame blur in source order, with per-channel FIR/IIR dispatch.
    /// IIR mutates the density texture in place; FIR uses one temporary
    /// texture with two ordered passes. A sigma>=3 must NEVER take FIR.
    static func blurWholeFrameInPlace(
        _ image: MTLTexture, scratch: MTLTexture, sigmas: [Double],
        command: MTLCommandBuffer, device: MTLDevice,
        library: MTLLibrary, gaussian: MTLComputePipelineState
    ) throws {
        guard image.width == scratch.width, image.height == scratch.height,
              image.pixelFormat == .rgba32Float,
              scratch.pixelFormat == .rgba32Float,
              sigmas.count == 3,
              sigmas.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw Failure.invalid("原版 Metal 全图滤波：输入纹理或 sigma 不正确")
        }
        if sigmas.contains(where: { $0 >= 3.0 }) {
            try OriginalMetalIIR.encodeInPlace(
                image, sigmas: sigmas, device: device,
                library: library, command: command
            )
        }
        let small = sigmas.map { $0 < 3.0 ? $0 : 0.0 }
        if small.allSatisfy({ $0 == 0 }) { return }
        var args = BlurParameters(
            sigma: vec(small), width: UInt32(image.width),
            height: UInt32(image.height), axis: 1
        )
        try execute(
            command: command, pipeline: gaussian,
            textures: [image, scratch], params: &args,
            width: image.width, height: image.height
        )
        args.axis = 0
        try execute(
            command: command, pipeline: gaussian,
            textures: [scratch, image], params: &args,
            width: image.width, height: image.height
        )
    }

    /// Full-image YVV pipeline. Each layer is completed and accumulated
    /// before allocating the next one. Peak resident working images:
    /// destination + accumulated + particle layer + scratch = four
    /// RGBA32Float frames, not three retained dye-cloud layer fields.
    /// Fails explicitly on insufficient iPhone memory (never half-precision).
    private static func renderWholeFrameIIR(
        normalizedDensity: CIImage, cubes: [CIImage],
        physical: PhysicalCoefficients, totalRanges: [Double],
        pixelUM: Double, amount: Double, seed: Double,
        sourceSciPySampling: Bool,
        bounds: CGRect, device: MTLDevice, queue: MTLCommandQueue,
        library: MTLLibrary, context: CIContext, destination: MTLTexture,
        particles: MTLComputePipelineState,
        clumping: MTLComputePipelineState,
        gaussian: MTLComputePipelineState,
        save: MTLComputePipelineState
    ) throws {
        let width = destination.width
        let height = destination.height
        if sourceSciPySampling {
            try OriginalSourceSciPyParticles.validateMemory(
                width: width, height: height,
                physicalMemory: ProcessInfo.processInfo.physicalMemory
            )
        }
        let projectedBytes = UInt64(width) * UInt64(height) * 16 * 5
        let memoryBudget = min(
            UInt64(1_500_000_000),
            ProcessInfo.processInfo.physicalMemory / 3
        )
        guard projectedBytes <= memoryBudget else {
            throw Failure.invalid(
                "原版 Metal 全图 IIR：高清图像需要约 " +
                "\(projectedBytes / 1_000_000) MB GPU 工作空间，" +
                "超过本机安全预算 \(memoryBudget / 1_000_000) MB；" +
                "为保持原版全图递归和 Float32，已停止而非降质。"
            )
        }
        let accumulated = try makeTexture(device, width: width, height: height)
        guard let addKernel = library.makeFunction(name: "originalFilmAccumulate"),
              let composeKernel = library.makeFunction(
                name: "originalFilmCompositeAccumulated"
              ) else {
            throw Failure.invalid("原版 Metal 全图 IIR：缺少逐层累加或微结构合成内核")
        }
        let accumulate = try device.makeComputePipelineState(function: addKernel)
        let compose = try device.makeComputePipelineState(function: composeKernel)
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        var params = Parameters(
            ranges: vec(totalRanges),
            peak0: vec(physical.maxima[0]), peak1: vec(physical.maxima[1]),
            peak2: vec(physical.maxima[2]),
            fraction0: vec(physical.fraction[0]),
            fraction1: vec(physical.fraction[1]),
            fraction2: vec(physical.fraction[2]),
            pixelUM: Float(pixelUM), amount: Float(amount),
            seed: UInt32(seed), originX: 0, originY: 0,
            width: UInt32(width), height: UInt32(height),
            microSigma: Float(physical.microSigma),
            microBlur: Float(physical.microBlur)
        )
        for layer in 0..<3 {
            try autoreleasepool {
                guard let command = queue.makeCommandBuffer(),
                      let faults = device.makeBuffer(
                        length: 4 * MemoryLayout<UInt32>.stride,
                        options: .storageModeShared
                      ) else {
                    throw Failure.invalid("原版 Metal 全图 IIR：指令或 Poisson 计数缓冲分配失败")
                }
                let words = faults.contents().bindMemory(
                    to: UInt32.self, capacity: 4
                )
                for index in 0..<4 { words[index] = 0 }
                let scratch = try makeTexture(device, width: width, height: height)
                // Render one emulsion's measured LUT into full-image
                // Float32 scratch. No GPU sampling is allowed to change the
                // source SciPy global RNG stream in the opt-in path.
                context.render(
                    cubes[layer], to: scratch, commandBuffer: command,
                    bounds: bounds, colorSpace: linearSpace
                )
                let finishCommand: MTLCommandBuffer
                let particlesTexture: MTLTexture
                let sourceBacking: OriginalSourceSciPyParticles.Result?
                if sourceSciPySampling {
                    // CPU cannot inspect an uncommitted Core Image render.
                    command.commit()
                    command.waitUntilCompleted()
                    guard command.status == .completed else {
                        throw Failure.invalid(
                            "原版 SciPy：亚层 \(layer) 读取前 GPU 渲染失败：" +
                            (command.error?.localizedDescription ?? "unknown")
                        )
                    }
                    let field = try OriginalSourceSciPyParticles.renderLayer(
                        normalizedLayer: scratch, sublayer: layer,
                        physical: physical, pixelUM: pixelUM,
                        device: device, queue: queue, library: library
                    )
                    particlesTexture = field.texture
                    sourceBacking = field
                    guard let nextCommand = queue.makeCommandBuffer() else {
                        throw Failure.invalid("原版 SciPy：亚层后续 GPU 指令创建失败")
                    }
                    finishCommand = nextCommand
                } else {
                    let output = try makeTexture(
                        device, width: width, height: height
                    )
                    try execute(
                        command: command, pipeline: particles,
                        textures: [scratch, output], params: &params,
                        width: width, height: height, errors: faults,
                        sublayer: UInt32(layer)
                    )
                    particlesTexture = output
                    sourceBacking = nil
                    finishCommand = command
                }
                try blurWholeFrameInPlace(
                    particlesTexture, scratch: scratch,
                    sigmas: physical.cloudSigmas[layer],
                    command: finishCommand, device: device,
                    library: library, gaussian: gaussian
                )
                var first: UInt32 = layer == 0 ? 1 : 0
                try execute(
                    command: finishCommand, pipeline: accumulate,
                    textures: [particlesTexture, accumulated], params: &first,
                    width: width, height: height
                )
                finishCommand.commit()
                finishCommand.waitUntilCompleted()
                // Keep the buffer backing the linear RGBA32Float field
                // alive until the GPU has finished every filtering sweep.
                withExtendedLifetime(sourceBacking) {}
                guard finishCommand.status == .completed else {
                    throw Failure.invalid(
                        "原版 Metal 全图：亚层 \(layer) 显影失败：" +
                        (finishCommand.error?.localizedDescription ?? "unknown")
                    )
                }
                if !sourceSciPySampling {
                    guard words[0] == 0 else {
                        throw Failure.invalid(
                            "原版 Metal 全图：亚层 \(layer) Poisson 采样失败 " +
                            "\(words[0]) 次（无效 λ=\(words[1])，低率耗尽=" +
                            "\(words[2])，高率耗尽=\(words[3])），已停止导出。"
                        )
                    }
                }
            }
        }
        try autoreleasepool {
            guard let command = queue.makeCommandBuffer() else {
                throw Failure.invalid("原版 Metal 全图 IIR：最终合成指令创建失败")
            }
            let clump = try makeTexture(device, width: width, height: height)
            let scratch = try makeTexture(device, width: width, height: height)
            try execute(
                command: command, pipeline: clumping,
                textures: [clump], params: &params,
                width: width, height: height
            )
            if physical.microSigma > 0.05 && physical.microBlur > 0.4 {
                try blurWholeFrameInPlace(
                    clump, scratch: scratch,
                    sigmas: [Double](repeating: physical.microBlur, count: 3),
                    command: command, device: device,
                    library: library, gaussian: gaussian
                )
            }
            var unused: UInt32 = 0
            try execute(
                command: command, pipeline: compose,
                textures: [accumulated, clump], params: &unused,
                width: width, height: height
            )
            try blurWholeFrameInPlace(
                accumulated, scratch: scratch,
                sigmas: [0.65, 0.65, 0.65],
                command: command, device: device,
                library: library, gaussian: gaussian
            )
            // The original density is needed only for the final strength
            // interpolation. Reuse the now-discardable FIR scratch image.
            context.render(
                normalizedDensity, to: scratch, commandBuffer: command,
                bounds: bounds, colorSpace: linearSpace
            )
            var write = CoreParameters(
                ranges: vec(totalRanges), amount: Float(amount),
                width: UInt32(width), height: UInt32(height),
                originX: 0, originY: 0, coreX: 0, coreY: 0,
                coreWidth: UInt32(width), coreHeight: UInt32(height)
            )
            try execute(
                command: command, pipeline: save,
                textures: [scratch, accumulated, destination], params: &write,
                width: width, height: height
            )
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw Failure.invalid(
                    "原版 Metal 全图 IIR：最终合成失败：" +
                    (command.error?.localizedDescription ?? "unknown")
                )
            }
        }
    }

    static func render(
        normalizedDensity: CIImage,
        sublayerCubes: [Data], rawLayerMaxima: [Double],
        totalRanges: [Double], cubeDimension: Int,
        pixelUM: Double, amount: Double, seed: Double,
        sourceSciPySampling: Bool = false,
        libraryURL: URL? = nil
    ) throws -> CIImage {
        guard sublayerCubes.count == 3, rawLayerMaxima.count == 9,
              totalRanges.count == 3,
              totalRanges.allSatisfy({ $0 > 0 && $0.isFinite }),
              (9...33).contains(cubeDimension),
              amount.isFinite && (0...3).contains(amount),
              seed.isFinite && seed >= 0 && seed <= Double(UInt32.max) else {
            throw Failure.invalid("原版 Metal 颗粒：显影输入参数不完整")
        }
        if sourceSciPySampling && seed != 8888 {
            throw Failure.invalid(
                "原版 SciPy 随机流固定按源代码每乳剂层重置种子；" +
                "请使用既有 8888 基准，不允许隐式更改随机状态。"
            )
        }
        if amount <= 0 { return normalizedDensity }
        let needed = cubeDimension * cubeDimension * cubeDimension * 16
        guard sublayerCubes.allSatisfy({ $0.count == needed }) else {
            throw Failure.invalid("原版 Metal 颗粒：缺少完整的三层胶片 LUT")
        }
        let physical = try physicalCoefficients(
            maxima: rawLayerMaxima, pixelUM: pixelUM
        )
        try requireSupportedOriginalFilters(physical)
        // A completed command buffer can still return invalid GPU output
        // (observed on Intel hosted CI). Verify the actual shader before
        // trusting or exporting results from the original Metal path.
        if libraryURL == nil {
            _ = try hardwareDiagnostic()
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Failure.invalid("原版 Metal 颗粒：本设备没有可用的 Metal GPU")
        }
        let library: MTLLibrary
        do {
            if let libraryURL {
                library = try device.makeLibrary(URL: libraryURL)
            } else {
                library = try device.makeDefaultLibrary(bundle: .main)
            }
        } catch {
            throw Failure.invalid("原版 Metal 颗粒：找不到随 App 编译的 Metal 库：" +
                                  error.localizedDescription)
        }
        func state(_ functionName: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: functionName) else {
                throw Failure.invalid("原版 Metal 颗粒：缺少函数 " + functionName)
            }
            return try device.makeComputePipelineState(function: function)
        }
        let particles = try state("originalFilmParticles")
        let clumping = try state("originalFilmMicroClump")
        let gaussian = try state("originalFilmGaussianReflect")
        let composite = try state("originalFilmCombine")
        let save = try state("originalFilmWriteCore")

        let bounds = normalizedDensity.extent.integral
        let imageWidth = Int(bounds.width)
        let imageHeight = Int(bounds.height)
        guard imageWidth > 0 && imageHeight > 0 &&
              imageWidth <= 50_000 && imageHeight <= 50_000 else {
            throw Failure.invalid("原版 Metal 颗粒：图像尺寸无效或过大")
        }
        // Original-precision mode must not quantize the optical-density
        // result to Float16 before paper/scan. Keep the destination Float32
        // and recycle the tile-local Float32 intermediates. If a large RAW
        // exceeds available GPU memory, fail explicitly; never silently
        // switch to half precision or the mobile-fast path.
        let destination = try makeTexture(
            device, width: imageWidth, height: imageHeight, format: .rgba32Float
        )
        let context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: NSNull(), .cacheIntermediates: false
        ])
        let cubes = sublayerCubes.map { bytes -> CIImage? in
            let filter = CIFilter.colorCube()
            filter.inputImage = normalizedDensity
            filter.cubeDimension = Float(cubeDimension)
            filter.cubeData = bytes
            return filter.outputImage
        }
        guard cubes.count == 3, cubes.allSatisfy({ $0 != nil }) else {
            throw Failure.invalid("原版 Metal 颗粒：实测三层光学密度 LUT 无法渲染")
        }
        if needsWholeFrameIIR(physical) || sourceSciPySampling {
            try renderWholeFrameIIR(
                normalizedDensity: normalizedDensity,
                cubes: cubes.compactMap { $0 }, physical: physical,
                totalRanges: totalRanges, pixelUM: pixelUM,
                amount: amount, seed: seed,
                sourceSciPySampling: sourceSciPySampling, bounds: bounds,
                device: device, queue: queue, library: library,
                context: context, destination: destination,
                particles: particles, clumping: clumping,
                gaussian: gaussian, save: save
            )
        } else {
        let tile = 512
        for yy in stride(from: 0, to: imageHeight, by: tile) {
            for xx in stride(from: 0, to: imageWidth, by: tile) {
                try autoreleasepool {
                    let cw = min(tile, imageWidth - xx)
                    let ch = min(tile, imageHeight - yy)
                    let x0 = max(0, xx - physical.halo)
                    let y0 = max(0, yy - physical.halo)
                    let x1 = min(imageWidth, xx + cw + physical.halo)
                    let y1 = min(imageHeight, yy + ch + physical.halo)
                    let w = x1 - x0
                    let h = y1 - y0
                    let rect = CGRect(
                        x: bounds.minX + CGFloat(x0),
                        y: bounds.minY + CGFloat(y0),
                        width: CGFloat(w), height: CGFloat(h)
                    )
                    guard let command = queue.makeCommandBuffer(),
                          let failures = device.makeBuffer(
                            length: 4 * MemoryLayout<UInt32>.stride,
                            options: .storageModeShared
                          ) else {
                        throw Failure.invalid("原版 Metal 颗粒：GPU 指令或错误缓冲区不足")
                    }
                    // Counters: total / invalid lambda / low-rate budget /
                    // high-rate PTRS budget. Do not hide any failed sample.
                    let faultWords = failures.contents().bindMemory(
                        to: UInt32.self, capacity: 4
                    )
                    for reason in 0..<4 { faultWords[reason] = 0 }
                    func fromCI(_ source: CIImage) throws -> MTLTexture {
                        let texture = try makeTexture(
                            device, width: w, height: h
                        )
                        context.render(
                            source, to: texture, commandBuffer: command,
                            bounds: rect,
                            colorSpace: CGColorSpace(
                                name: CGColorSpace.linearSRGB
                            )!
                        )
                        return texture
                    }
                    let original = try fromCI(normalizedDensity)
                    var args = Parameters(
                        ranges: vec(totalRanges),
                        peak0: vec(physical.maxima[0]),
                        peak1: vec(physical.maxima[1]),
                        peak2: vec(physical.maxima[2]),
                        fraction0: vec(physical.fraction[0]),
                        fraction1: vec(physical.fraction[1]),
                        fraction2: vec(physical.fraction[2]),
                        pixelUM: Float(pixelUM), amount: Float(amount),
                        seed: UInt32(seed), originX: UInt32(x0),
                        originY: UInt32(y0),
                        width: UInt32(w), height: UInt32(h),
                        microSigma: Float(physical.microSigma),
                        microBlur: Float(physical.microBlur)
                    )
                    var layerBuffers = [MTLTexture]()
                    for sl in 0..<3 {
                        let values = try fromCI(cubes[sl]!)
                        let developed = try makeTexture(
                            device, width: w, height: h
                        )
                        try execute(
                            command: command, pipeline: particles,
                            textures: [values, developed], params: &args,
                            width: w, height: h, errors: failures,
                            sublayer: UInt32(sl)
                        )
                        // Source cloud blur uses a unique sigma for each
                        // emulsion and each colour (derived from OD/particle).
                        let cloud = try blur(
                            developed, sigmas: physical.cloudSigmas[sl],
                            command: command, device: device, pipeline: gaussian
                        )
                        layerBuffers.append(cloud)
                    }
                    let clump = try makeTexture(device, width: w, height: h)
                    try execute(
                        command: command, pipeline: clumping,
                        textures: [clump], params: &args,
                        width: w, height: h
                    )
                    let filteredClump: MTLTexture
                    if physical.microSigma > 0.05 && physical.microBlur > 0.4 {
                        filteredClump = try blur(
                            clump, sigmas: Array(
                                repeating: physical.microBlur, count: 3
                            ), command: command, device: device,
                            pipeline: gaussian
                        )
                    } else {
                        filteredClump = clump
                    }
                    let rawDensity = try makeTexture(
                        device, width: w, height: h
                    )
                    try execute(
                        command: command, pipeline: composite,
                        textures: layerBuffers + [filteredClump, rawDensity],
                        params: &args, width: w, height: h
                    )
                    let finalGrain = try blur(
                        rawDensity, sigmas: [0.65, 0.65, 0.65],
                        command: command, device: device, pipeline: gaussian
                    )
                    var write = CoreParameters(
                        ranges: vec(totalRanges), amount: Float(amount),
                        width: UInt32(w), height: UInt32(h),
                        originX: UInt32(xx), originY: UInt32(yy),
                        coreX: UInt32(xx - x0), coreY: UInt32(yy - y0),
                        coreWidth: UInt32(cw), coreHeight: UInt32(ch)
                    )
                    try execute(
                        command: command, pipeline: save,
                        textures: [original, finalGrain, destination],
                        params: &write, width: cw, height: ch
                    )
                    command.commit()
                    command.waitUntilCompleted()
                    guard command.status == .completed else {
                        throw Failure.invalid("原版 Metal 颗粒：GPU 显影执行失败：" +
                            (command.error?.localizedDescription ?? "unknown"))
                    }
                    let failuresCount = faultWords[0]
                    guard failuresCount == 0 else {
                        throw Failure.invalid(
                            "原版 Metal 颗粒：Poisson 采样失败 \(failuresCount) 次，" +
                            "其中无效 λ=\(faultWords[1])、" +
                            "低采样率耗尽=\(faultWords[2])、" +
                            "高采样率 PTRS 耗尽=\(faultWords[3])；" +
                            "位置=(\(xx),\(yy))，块=\(cw)×\(ch)。" +
                            "已终止高清导出，禁止近似降级。"
                        )
                    }
                }
            }
        }
        }
        guard let result = CIImage(
            mtlTexture: destination, options: [.colorSpace: NSNull()]
        ) else {
            throw Failure.invalid("原版 Metal 颗粒：无法从 GPU 纹理恢复光学密度")
        }
        return result.transformed(
            by: CGAffineTransform(
                translationX: bounds.minX, y: bounds.minY
            )
        )
    }
}
