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
        let microSigma = 30.0 * 0.001 / pixelUM
        let microBlur = 0.2 / pixelUM
        let useMicro = microSigma > 0.05
        let useMicroBlur = useMicro && microBlur > 0.4
        let maxCloud = cloud.flatMap { $0 }.max() ?? 0
        // Composition of separately truncated kernels: each contribution
        // has a compact support; halo >= sum radii is exact within a tile.
        let cloudReach = Int(floor(3 * maxCloud + 0.5))
        let microReach = useMicroBlur ? Int(floor(3 * microBlur + 0.5)) : 0
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

    private static func vec(_ values: [Double]) -> SIMD4<Float> {
        SIMD4<Float>(
            Float(values[0]), Float(values[1]), Float(values[2]), 0
        )
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
        return "Metal 硬件自检通过 · \(device.name) · " +
            "纹理透传 PASS · reflect 误差 \(String(format: "%.7f", err))"
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

    private static func execute<P>(
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
            height: UInt32(image.height), axis: 0
        )
        try execute(
            command: command, pipeline: pipeline,
            textures: [image, scratch], params: &args,
            width: image.width, height: image.height
        )
        args.axis = 1
        try execute(
            command: command, pipeline: pipeline,
            textures: [scratch, output], params: &args,
            width: image.width, height: image.height
        )
        return output
    }

    static func render(
        normalizedDensity: CIImage,
        sublayerCubes: [Data], rawLayerMaxima: [Double],
        totalRanges: [Double], cubeDimension: Int,
        pixelUM: Double, amount: Double, seed: Double,
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
        if amount <= 0 { return normalizedDensity }
        let needed = cubeDimension * cubeDimension * cubeDimension * 16
        guard sublayerCubes.allSatisfy({ $0.count == needed }) else {
            throw Failure.invalid("原版 Metal 颗粒：缺少完整的三层胶片 LUT")
        }
        let physical = try physicalCoefficients(
            maxima: rawLayerMaxima, pixelUM: pixelUM
        )
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
        // Output is one retained 16-bit density texture. Intermediate
        // 32-bit source/emulsion textures are recycled tile by tile.
        // This avoids nine full-size textures on high-resolution RAW exports.
        let destination = try makeTexture(
            device, width: imageWidth, height: imageHeight, format: .rgba16Float
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
                            length: MemoryLayout<UInt32>.stride,
                            options: .storageModeShared
                          ) else {
                        throw Failure.invalid("原版 Metal 颗粒：GPU 指令或错误缓冲区不足")
                    }
                    failures.contents().storeBytes(of: UInt32(0), as: UInt32.self)
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
                    let failuresCount = failures.contents().load(as: UInt32.self)
                    guard failuresCount == 0 else {
                        throw Failure.invalid(
                            "原版 Metal 颗粒：Poisson 采样出现 \(failuresCount) 次不可收敛，已终止导出"
                        )
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
