import Foundation
import CoreGraphics
import CoreImage
import Metal

@main
struct OriginalMetalGrainValidation {
    static func near(_ a: Double, _ b: Double, tolerance: Double,
                     _ title: String) {
        precondition(a.isFinite && abs(a-b)<tolerance,
                     "\(title): \(a) vs \(b)")
    }

    static func identityCube(_ size: Int) -> Data {
        var result = [Float]()
        let step = Float(1)/Float(size-1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    result += [Float(r)*step,Float(g)*step,Float(b)*step,1]
                }
            }
        }
        return result.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: $0.count*4)
        }
    }

    /// Test the *actual native Metal compute shader* against scipy
    /// ndimage reflect boundary, not a source-code text assertion.
    static func gaussianReference(
        _ device: MTLDevice, library: MTLLibrary
    ) throws {
        let f = library.makeFunction(name: "originalFilmGaussianReflect")!
        let pipeline = try device.makeComputePipelineState(function:f)
        let w=11, h=7
        func make() -> MTLTexture {
            let desc=MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat:.rgba32Float,width:w,height:h,mipmapped:false
            )
            desc.storageMode = .shared
            desc.usage = [.shaderRead,.shaderWrite]
            return device.makeTexture(descriptor:desc)!
        }
        let a=make(), out=make()
        var pixels=[Float](repeating:0,count:w*h*4)
        for y in 0..<h {
            for channel in 0..<4 {
                pixels[(y*w)*4+channel] = 1
            }
        }
        pixels.withUnsafeBytes { raw in
            a.replace(
                region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,
                withBytes:raw.baseAddress!,bytesPerRow:w*4*4
            )
        }
        var uploaded=[Float](repeating:0,count:pixels.count)
        uploaded.withUnsafeMutableBytes { raw in
            a.getBytes(raw.baseAddress!,bytesPerRow:w*4*4,
                from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
        }
        precondition(abs(uploaded[0]-1)<0.000001 &&
                     abs(uploaded[1]-1)<0.000001 &&
                     abs(uploaded[2]-1)<0.000001,
                     "GPU edge test source texture upload failed")
        // Probe the identical uploaded texture and packed Swift/Metal
        // BlurParameters before judging the Gaussian convolution.
        guard let probeFunc = library.makeFunction(name: "originalFilmDebugProbe")
        else { fatalError("Missing test-only GPU shader probe") }
        let probePipe = try device.makeComputePipelineState(function:probeFunc)
        let probeOut = make()
        let probeCommand = device.makeCommandQueue()!.makeCommandBuffer()!
        let probeEncoder = probeCommand.makeComputeCommandEncoder()!
        probeEncoder.setComputePipelineState(probePipe)
        probeEncoder.setTexture(a, index:0)
        probeEncoder.setTexture(probeOut, index:1)
        var probeArgs = OriginalMetalGrain.BlurParameters(
            sigma:SIMD4<Float>(0.65,0.65,0.65,0),
            width:UInt32(w),height:UInt32(h),axis:0
        )
        probeEncoder.setBytes(
            &probeArgs,length:MemoryLayout<OriginalMetalGrain.BlurParameters>.stride,
            index:0
        )
        probeEncoder.dispatchThreads(
            MTLSize(width:w,height:h,depth:1),
            threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1)
        )
        probeEncoder.endEncoding()
        probeCommand.commit()
        probeCommand.waitUntilCompleted()
        precondition(probeCommand.status == .completed,
                     "Metal debug texture probe execution failed")
        var probeValues = [Float](repeating:0,count:pixels.count)
        probeValues.withUnsafeMutableBytes { raw in
            probeOut.getBytes(raw.baseAddress!,bytesPerRow:w*4*4,
                from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
        }
        print("METAL PROBE input=",uploaded[0], " output r=",probeValues[0],
              " shader sigma=",probeValues[1],
              " shader width=",probeValues[2],
              " y=3 rgb=",Array(probeValues[(3*w)*4..<(3*w)*4+3]))
        precondition(abs(probeValues[0]-1) < 0.00001 &&
                     abs(probeValues[1]-0.65) < 0.00001 &&
                     abs(probeValues[2]-Float(w)) < 0.00001 &&
                     abs(probeValues[(3*w)*4]-1) < 0.00001,
                     "Metal shader texture binding or Swift struct ABI does not match")
        let expected=GeneratedOriginalMetalGrainReference.reflect065
        for (s,reference) in [
            (0.65,expected),
            (1.2,GeneratedOriginalMetalGrainReference.reflect120),
            (0.2,GeneratedOriginalMetalGrainReference.reflect020)
        ] {
            let command=device.makeCommandQueue()!.makeCommandBuffer()!
            let encoder=command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(a,index:0)
            encoder.setTexture(out,index:1)
            var settings=OriginalMetalGrain.BlurParameters(
                sigma:SIMD4<Float>(Float(s),Float(s),Float(s),0),
                width:UInt32(w),height:UInt32(h),axis:0
            )
            encoder.setBytes(&settings,
                             length:MemoryLayout<OriginalMetalGrain.BlurParameters>.stride,
                             index:0)
            encoder.dispatchThreads(
                MTLSize(width:w,height:h,depth:1),
                threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1)
            )
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed,
                         "Actual Metal reflect blur failed to run")
            var actual=[Float](repeating:0,count:w*h*4)
            actual.withUnsafeMutableBytes { bytes in
                out.getBytes(bytes.baseAddress!,bytesPerRow:w*4*4,
                    from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)
            }
            for x in 0..<w {
                for ch in 0..<3 {
                    near(Double(actual[(3*w+x)*4+ch]),reference[x],
                         tolerance:0.00012,
                         "source SciPy reflect FIR sigma=\(s) x=\(x)")
                }
            }
        }
        print("PASS: real Metal reflect Gaussian at 0.20 / 0.65 / 1.20 pixels vs original NumPy.")
    }

    static func main() throws {
        setbuf(stdout,nil)
        let vectors=GeneratedOriginalMetalGrainReference.samples
        precondition(vectors.count==12)
        for item in vectors {
            let data=try OriginalMetalGrain.physicalCoefficients(
                maxima:item.maxima,pixelUM:item.pixelUM
            )
            for l in 0..<3 {
                for c in 0..<3 {
                    let k=l*3+c
                    near(data.fraction[l][c],item.fractions[k],
                         tolerance:1e-12,"source measured emulsion fraction")
                    near(data.cloudSigmas[l][c],item.dyeSigmas[k],
                         tolerance:1e-10,"source dye cloud OD radius")
                }
            }
            near(data.microSigma,item.microSigma,tolerance:1e-12,
                 "source lognormal microstructure sigma")
            near(data.microBlur,item.microBlur,tolerance:1e-12,
                 "source microstructure spatial blur")
            precondition((data.microSigma>0.05) == (item.pixelUM==0.5))
        }
        print("PASS: 12 measured stock/pixel conditions, dye-cloud radii and lognormal microstructure thresholds.")

        guard let device=MTLCreateSystemDefaultDevice() else {
            fatalError("Metal GPU unavailable; do not falsely report source validation passed")
        }
        guard CommandLine.arguments.count>=2 else {
            fatalError("Pass the macOS .metallib path as first CLI argument")
        }
        let library=try device.makeLibrary(
            URL:URL(fileURLWithPath:CommandLine.arguments[1])
        )
        try gaussianReference(device,library:library)

        let source=CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4))
            .cropped(to:CGRect(x:0,y:0,width:31,height:27))
        let c=identityCube(9)
        let selected=vectors.first { $0.pixelUM==9 }!
        func output(seed:Double,amount:Double) throws -> CIImage {
            try OriginalMetalGrain.render(
                normalizedDensity:source,
                sublayerCubes:[c,c,c],
                rawLayerMaxima:selected.maxima,
                totalRanges:[2.8,2.8,2.8],
                cubeDimension:9,pixelUM:9,
                amount:amount,seed:seed,
                libraryURL:URL(fileURLWithPath:CommandLine.arguments[1])
            )
        }
        let base=try output(seed:8888,amount:0)
        let a=try output(seed:8888,amount:1)
        let b=try output(seed:8888,amount:1)
        let changed=try output(seed:7777,amount:1)
        let render=CIContext(options:[.useSoftwareRenderer:true])
        func data(_ ci:CIImage)->[Float] {
            var values=[Float](repeating:0,count:31*27*4)
            let space=CGColorSpace(name:CGColorSpace.sRGB)!
            values.withUnsafeMutableBytes { raw in
                render.render(ci,toBitmap:raw.baseAddress!,
                    rowBytes:31*4*4,bounds:CGRect(x:0,y:0,width:31,height:27),
                    format:.RGBAf,colorSpace:space)
            }
            return values
        }
        let v0=data(base),v1=data(a),v2=data(b),v3=data(changed)
        var mean=0.0, changedCount=0, seedChange=0, count=0
        for ix in stride(from:0,to:v0.count,by:4) {
            near(Double(v0[ix]),0.4,tolerance:0.001,
                 "source Metal zero-strength optical identity")
            near(Double(v1[ix]),Double(v2[ix]),tolerance:0.00002,
                 "source Metal deterministic tile sampling")
            precondition(v1[ix].isFinite && v1[ix]>=0 && v1[ix]<=1.001)
            mean += Double(v1[ix])
            count += 1
            if abs(v1[ix]-v0[ix]) > 0.0003 { changedCount+=1 }
            if abs(v1[ix]-v3[ix]) > 0.0003 { seedChange+=1 }
        }
        mean /= Double(count)
        precondition(mean > 0.20 && mean < 0.60,
                     "Metal measured emulsion mean differs unexpectedly")
        precondition(changedCount > count/10 && seedChange > count/10,
                     "Source Metal grain missing or random seed ineffective")
        precondition(a.extent.width==31 && a.extent.height==27,
                     "Metal tiling silently changed output dimensions")
        print("PASS: end-to-end actual Metal source density 3-layer Poisson draw, physical blur, seed and original dimensions.")
    }
}
