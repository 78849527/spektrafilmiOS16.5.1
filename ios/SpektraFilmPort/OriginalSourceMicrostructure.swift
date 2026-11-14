import Foundation
#if canImport(Metal)
import Metal
#endif

/// Exact deterministic source fast_lognormal_from_mean_std() transform for
/// mean=1, s=30nm/pixelUM. Normal N(0,1) values are supplied explicitly.
/// The upstream Numba prange() RNG is independently seeded/uncontrolled;
/// this DOES NOT claim the generated random field is source bit-identical.
enum OriginalSourceMicrostructure {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let s) = self { return s }
            return nil
        }
    }

    /// Python grain.py: micro_structure[0] is μm of blur and [1] is
    /// nm of lognormal variation. Defaults retain the upstream stock profile.
    /// The parameters must remain independent rather than fixed 0.2/30.
    static func physical(
        pixelUM: Double,
        microBlurUM: Double = 0.2,
        microStructureNM: Double = 30.0
    ) throws -> (microStd: Double, blur: Double, enabled: Bool) {
        guard pixelUM > 0, pixelUM.isFinite,
              microBlurUM.isFinite, microBlurUM >= 0,
              microStructureNM.isFinite, microStructureNM >= 0 else {
            throw Failure.invalid("原版微结构：像素尺寸或μm/nm原版参数无效")
        }
        // Keep the source's *exact* operation ordering and threshold.
        let blur = microBlurUM / pixelUM
        let microStd = microStructureNM * 0.001 / pixelUM
        guard microStd.isFinite, blur.isFinite else {
            throw Failure.invalid("原版微结构：源公式溢出")
        }
        return (microStd, blur, microStd > 0.05)
    }

    static func lognormal(
        microStd: Double, z: Double
    ) throws -> Double {
        guard microStd.isFinite, microStd >= 0, z.isFinite else {
            throw Failure.invalid("原版微结构：随机样本或标准差无效")
        }
        if microStd <= 0.05 { return 1 }
        // Direct source fast_stats.py:
        // sigma2 = np.log(1.0 + (s*s)/(m*m)), m=1.
        // flat_sigma=sqrt(sigma2), flat_mu=ln(m)-sigma2/2.
        let sigma2 = log(1.0 + microStd * microStd)
        let sigma = sqrt(sigma2)
        let mu = -sigma2 / 2.0
        let result = exp(mu + sigma * z)
        guard result.isFinite else {
            throw Failure.invalid("原版微结构：对数正态变换溢出")
        }
        return result
    }

    static func validateSourceMath() throws -> String {
        let cases = GeneratedSourceMicrostructureReference.cases
        guard cases.count >= 5,
              GeneratedSourceMicrostructureReference.grainSHA.count == 64,
              GeneratedSourceMicrostructureReference.fastStatsSHA.count == 64
        else {
            throw Failure.invalid("原版微结构：源 Python 参考向量缺失")
        }
        var errorMax = 0.0
        for fixture in cases {
            let got = try physical(pixelUM:fixture.pixelUM)
            guard abs(got.microStd - fixture.microStd) <= 1e-14,
                  abs(got.blur - fixture.microBlur) <= 1e-14,
                  got.enabled == fixture.enabled,
                  fixture.normals.count == fixture.expected.count
            else {
                throw Failure.invalid("原版微结构：像素尺寸/启用阈值与源不一致")
            }
            for (z,expected) in zip(fixture.normals, fixture.expected) {
                let actual = try lognormal(
                    microStd: fixture.microStd, z:z
                )
                let difference = abs(actual-expected)
                errorMax = max(errorMax,difference)
                guard difference <= 1e-12 * (1 + abs(expected)) else {
                    throw Failure.invalid("原版微结构：Double lognormal 与源不一致，差值=\(difference)")
                }
            }
        }
        return "源 Numba 对数正态确定性公式 5 组 / \(cases.count*9) 样本 Float64 PASS；" +
            "max=\(errorMax)；随机 Numba 线程流仍未移植"
    }

    /// Run the *same* float32 lognormal helper used by production Metal
    /// against source Python deterministic gaussian input reference vectors.
#if canImport(Metal)
    static func hardwareDiagnostic() throws -> String {
        let first = try validateSourceMath()
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(
                name:"originalFilmMicroFromNormals"
              ) else {
            throw Failure.invalid("原版微结构：缺少真机 Metal 内核")
        }
        let pipeline = try device.makeComputePipelineState(
            function: function
        )
        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat:.rgba32Float, width:3,height:1,mipmapped:false
        )
        textureDesc.storageMode = .shared
        textureDesc.usage = [.shaderRead,.shaderWrite]
        guard let input = device.makeTexture(descriptor:textureDesc),
              let output = device.makeTexture(descriptor:textureDesc)
        else { throw Failure.invalid("原版微结构：共享纹理分配失败") }
        var maxError = 0.0
        for fixture in GeneratedSourceMicrostructureReference.cases {
            var normals = [Float](repeating:1,count:12)
            for idx in 0..<9 {
                normals[(idx/3)*4+idx%3] = Float(fixture.normals[idx])
            }
            normals.withUnsafeBytes { bytes in
                input.replace(
                    region:MTLRegionMake2D(0,0,3,1),
                    mipmapLevel:0,withBytes:bytes.baseAddress!,
                    bytesPerRow:3*4*MemoryLayout<Float>.stride
                )
            }
            guard let command = queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder()
            else { throw Failure.invalid("原版微结构：GPU 指令生成失败") }
            var std = Float(fixture.microStd)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input,index:0)
            encoder.setTexture(output,index:1)
            encoder.setBytes(&std,length:MemoryLayout<Float>.stride,index:0)
            encoder.dispatchThreads(
                MTLSize(width:3,height:1,depth:1),
                threadsPerThreadgroup:MTLSize(width:3,height:1,depth:1)
            )
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw Failure.invalid("原版微结构：GPU 计算失败：" +
                    (command.error?.localizedDescription ?? "unknown"))
            }
            var actual = [Float](repeating:0,count:12)
            actual.withUnsafeMutableBytes { bytes in
                output.getBytes(bytes.baseAddress!,
                    bytesPerRow:3*4*MemoryLayout<Float>.stride,
                    from:MTLRegionMake2D(0,0,3,1),mipmapLevel:0)
            }
            for idx in 0..<9 {
                let expected=fixture.expected[idx]
                let value=Double(actual[(idx/3)*4+idx%3])
                let err=abs(expected-value)
                maxError=max(maxError,err)
                guard value.isFinite, err <= 0.00002*(1+abs(expected))
                else {
                    throw Failure.invalid(
                        "原版微结构 GPU 映射失败：pixelUM=\(fixture.pixelUM) idx=\(idx) " +
                        "source=\(expected) GPU=\(value) error=\(err)"
                    )
                }
            }
        }
        return first + "；生产同源 Metal 变换 max=\(maxError) PASS"
    }
#endif
}
