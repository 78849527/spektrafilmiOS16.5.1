import Foundation
import Metal

/// v1.8.2 deterministic reference replay of the UNMODIFIED Python model.
///
/// The 9 seeded SciPy Poisson->Binomial particle textures come directly from
/// original grain.py. Numba's independent microstructure RNG is also injected
/// as a frozen input. This isolates the PRODUCTION Metal FIR/YVV, three-layer
/// density addition and microstructure composite from unrelated PRNG streams.
///
/// Source Float64 vs Metal Float32 remains a measured numeric error; this is
/// NOT proof that the application's hash RNG equals SciPy/Numba's stream.
enum OriginalMetalSourceReplay {
    enum Error: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(value) = self { return value }
            return nil
        }
    }

    private static func makeTexture(_ device: MTLDevice, width: Int,
                                    height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width,
            height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let result = device.makeTexture(descriptor: descriptor) else {
            throw Error.invalid("原版密度回放：无法分配 Float32 GPU 纹理")
        }
        return result
    }

    private static func upload(_ rgb: [Double], to texture: MTLTexture) throws {
        let count = texture.width * texture.height
        guard rgb.count == count * 3 else {
            throw Error.invalid("原版密度回放：输入颗粒数据长度不正确")
        }
        var bytes = [Float](repeating: 1, count: count * 4)
        for pixel in 0..<count {
            for ch in 0..<3 {
                let value = rgb[pixel * 3 + ch]
                guard value.isFinite && abs(value) <= Double(Float.greatestFiniteMagnitude) else {
                    throw Error.invalid("原版密度回放：Python 输入含无效密度")
                }
                bytes[pixel * 4 + ch] = Float(value)
            }
        }
        bytes.withUnsafeBytes { data in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0, withBytes: data.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float>.stride
            )
        }
    }

    private static func read(_ texture: MTLTexture) -> [Float] {
        let count = texture.width * texture.height
        var rgba = [Float](repeating: 0, count: count * 4)
        rgba.withUnsafeMutableBytes { data in
            texture.getBytes(
                data.baseAddress!,
                bytesPerRow: texture.width * 4 * MemoryLayout<Float>.stride,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        var rgb = [Float](repeating: 0, count: count * 3)
        for pixel in 0..<count {
            for ch in 0..<3 {
                rgb[pixel * 3 + ch] = rgba[pixel * 4 + ch]
            }
        }
        return rgb
    }

    private static func state(_ library: MTLLibrary, device: MTLDevice,
                              name: String) throws -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw Error.invalid("原版密度回放：Metal 缺少 " + name)
        }
        return try device.makeComputePipelineState(function: function)
    }

    private static func finish(_ command: MTLCommandBuffer,
                               stage: String) throws {
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw Error.invalid(
                "原版密度回放：" + stage + "GPU 执行失败：" +
                (command.error?.localizedDescription ?? "unknown")
            )
        }
    }

    static func hardwareDiagnostic() throws -> String {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Error.invalid("原版密度回放：没有可用的 Metal GPU")
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        return try validate(device: device, queue: queue, library: library)
    }

    /// Uses the identical production blurWholeFrameInPlace path and actual
    /// originalFilmAccumulate / originalFilmCompositeAccumulated Metal kernels.
    /// It is an opt-in self-test, not a new production rendering mode.
    static func validate(
        device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary
    ) throws -> String {
        let fixtures = GeneratedSourceReplayReference.cases
        guard fixtures.count >= 2,
              GeneratedSourceReplayReference.grainSHA256.count == 64 else {
            throw Error.invalid("原版密度回放：原始 Python fixture 未打包")
        }
        let gaussian = try state(library, device: device,
                                 name: "originalFilmGaussianReflect")
        let accumulate = try state(library, device: device,
                                   name: "originalFilmAccumulate")
        let composite = try state(library, device: device,
                                  name: "originalFilmCompositeAccumulated")
        var report = [String]()
        var coveredIIR = false
        var coveredMicro = false
        for fixture in fixtures {
            let w = fixture.width
            let h = fixture.height
            let count = w * h
            guard w > 1 && h > 1, count <= 16_384,
                  fixture.maxima.count == 9,
                  fixture.dyeSigmas.count == 9,
                  fixture.particlesBySublayer.count == 3,
                  fixture.particlesBySublayer.allSatisfy({ $0.count == count * 3 }),
                  fixture.microstructureInput.count == count * 3,
                  fixture.expectedDensity.count == count * 3 else {
                throw Error.invalid("原版密度回放：fixture 不完整")
            }
            let physical = try OriginalMetalGrain.physicalCoefficients(
                maxima: fixture.maxima, pixelUM: fixture.pixelUM
            )
            for sl in 0..<3 {
                for ch in 0..<3 {
                    let a = physical.cloudSigmas[sl][ch]
                    let b = fixture.dyeSigmas[sl*3+ch]
                    guard abs(a-b) < 1e-10 else {
                        throw Error.invalid("原版密度回放：染料云 sigma 与源不一致")
                    }
                }
            }
            coveredIIR = coveredIIR || OriginalMetalGrain.needsWholeFrameIIR(physical)
            coveredMicro = coveredMicro ||
                (physical.microSigma > 0.05 && physical.microBlur > 0.4)

            let total = try makeTexture(device, width: w, height: h)
            for sl in 0..<3 {
                let particle = try makeTexture(device, width: w, height: h)
                let scratch = try makeTexture(device, width: w, height: h)
                try upload(fixture.particlesBySublayer[sl], to: particle)
                guard let command = queue.makeCommandBuffer() else {
                    throw Error.invalid("原版密度回放：分层计算指令创建失败")
                }
                try OriginalMetalGrain.blurWholeFrameInPlace(
                    particle, scratch: scratch,
                    sigmas: physical.cloudSigmas[sl],
                    command: command, device: device,
                    library: library, gaussian: gaussian
                )
                var first: UInt32 = sl == 0 ? 1 : 0
                try OriginalMetalGrain.execute(
                    command: command, pipeline: accumulate,
                    textures: [particle, total], params: &first,
                    width: w, height: h
                )
                try finish(command, stage: "亚层 \(sl)")
            }
            let micro = try makeTexture(device, width: w, height: h)
            let scratch = try makeTexture(device, width: w, height: h)
            try upload(fixture.microstructureInput, to: micro)
            guard let final = queue.makeCommandBuffer() else {
                throw Error.invalid("原版密度回放：合成计算指令创建失败")
            }
            if physical.microSigma > 0.05 && physical.microBlur > 0.4 {
                try OriginalMetalGrain.blurWholeFrameInPlace(
                    micro, scratch: scratch,
                    sigmas: [Double](repeating: physical.microBlur, count: 3),
                    command: final, device: device,
                    library: library, gaussian: gaussian
                )
            }
            var unused: UInt32 = 0
            try OriginalMetalGrain.execute(
                command: final, pipeline: composite,
                textures: [total, micro], params: &unused,
                width: w, height: h
            )
            try OriginalMetalGrain.blurWholeFrameInPlace(
                total, scratch: scratch,
                sigmas: [0.65, 0.65, 0.65],
                command: final, device: device,
                library: library, gaussian: gaussian
            )
            try finish(final, stage: "最终密度合成")
            let actual = read(total)
            var sumAbsolute = 0.0
            var sumSquare = 0.0
            var largest = 0.0
            for i in 0..<actual.count {
                let expected = fixture.expectedDensity[i]
                let observed = Double(actual[i])
                let difference = abs(observed - expected)
                guard observed.isFinite, expected.isFinite else {
                    throw Error.invalid("原版密度回放：出现 NaN 或 Inf（" +
                                        fixture.name + "）")
                }
                sumAbsolute += difference
                sumSquare += difference * difference
                largest = max(largest, difference)
                // Absolute and relative tolerances are deliberately
                // conservative Float32 diagnostics, NOT pixel equivalence.
                let tolerance = 0.002 + 0.001 * abs(expected)
                guard difference <= tolerance else {
                    throw Error.invalid(
                        "原版密度回放偏差超限：\(fixture.name) " +
                        "像素=\(i/3) 通道=\(i%3)，" +
                        "Python Float64=\(expected)，Metal Float32=\(observed)，" +
                        "绝对误差=\(difference)，门限=\(tolerance)"
                    )
                }
            }
            let n = Double(actual.count)
            let mae = sumAbsolute / n
            let rmse = sqrt(sumSquare / n)
            report.append(
                "\(fixture.name) MAE=\(String(format: "%.7g", mae)) " +
                "RMSE=\(String(format: "%.7g", rmse)) " +
                "max=\(String(format: "%.7g", largest))"
            )
        }
        guard coveredIIR && coveredMicro else {
            throw Error.invalid("原版密度回放：测试没有覆盖 IIR 与微结构")
        }
        return "源 Python 九路随机场回放（不含 RNG 同序）通过：" +
            report.joined(separator: "；")
    }
}
