import Foundation
import CoreGraphics
import CoreImage

/// Native CoreImage source-law discrete particle renderer tests.
/// Deterministic GPU RNG is deliberately not expected to match SciPy RNG
/// seeds, but sampled optical-density moment/quantization must agree with
/// the original Poisson Binomial law (Poisson thinning).
@main
struct DiscreteGrainValidation {
    static func identityCube(_ size: Int) -> Data {
        var out = [Float]()
        let step = Float(1.0/Double(size-1))
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    out.append(contentsOf: [
                        Float(r)*step,Float(g)*step,Float(b)*step,1
                    ])
                }
            }
        }
        return out.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: $0.count*4)
        }
    }

    static func bitmap(_ image: CIImage, side: Int) -> [Float] {
        let ci = CIContext(options: [.useSoftwareRenderer: true])
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        var data = [Float](repeating: 0, count: side*side*4)
        data.withUnsafeMutableBytes { bytes in
            ci.render(
                image,toBitmap:bytes.baseAddress!,
                rowBytes:side*16,
                bounds:CGRect(x:0,y:0,width:side,height:side),
                format:.RGBAf,colorSpace:rgb
            )
        }
        return data
    }

    static func run(side: Int, pixelUM: Double) -> (mean: Double, variance: Double) {
        let c = CIImage(color:CIColor(red:0.4,green:0.4,blue:0.4))
            .cropped(to:CGRect(x:0,y:0,width:side,height:side))
        let peaks: [Double] = [
            0.7,0.7,0.7, 0.8,0.6,0.8, 0.7,0.9,0.8
        ]
        let total: [Double] = [2.2,2.2,2.3]
        let cube = identityCube(9)
        func output(amount: Double, seed: Double) -> CIImage? {
            OriginalDiscreteGrain.perturb(
                c,sublayerCubes:[cube,cube,cube],
                rawLayerMaxima:peaks,totalRanges:total,
                cubeDimension:9,pixelUM:pixelUM,
                amount:amount,seed:seed
            )
        }
        guard let base = output(amount:0,seed:8888),
              let img = output(amount:1,seed:8888),
              let repeatImage = output(amount:1,seed:8888),
              let changedImage = output(amount:1,seed:7777) else {
            fatalError("CoreImage discrete Poisson grain kernel unavailable")
        }
        let x0=bitmap(base,side:side), x1=bitmap(img,side:side),
            x2=bitmap(repeatImage,side:side), x3=bitmap(changedImage,side:side)
        var sum=0.0, squares=0.0, seedChanges=0, samples=0
        for index in stride(from:0,to:x0.count,by:4) {
            let d=Double(x1[index])
            precondition(d.isFinite && d >= 0 && d <= 1.001)
            precondition(abs(x1[index]-x2[index]) < 1e-5,
                         "fixed source-law random seed must repeat")
            precondition(abs(x0[index]-0.4) < 0.001,
                         "zero amount must be unperturbed original density")
            if abs(x1[index]-x3[index]) > 0.001 { seedChanges += 1 }
            sum += d
            squares += d*d
            samples += 1
        }
        precondition(seedChanges > samples/10,
                     "source-law Poisson particle seeds not independent")
        let mean=sum/Double(samples)
        let variance=squares/Double(samples)-mean*mean
        precondition(variance > 0.0000005,
                     "Poisson counts should produce nonzero optical-density noise")
        print("PASS: CoreImage discrete Poisson image pixelUM=\(pixelUM) mean=\(mean) variance=\(variance)")
        return (mean,variance)
    }

    static func main() {
        setbuf(stdout,nil)
        let sourceDensity=0.72
        let rawMaximum=2.25
        let layerMinimum=0.03
        let pixelUM=9.0
        let p=(sourceDensity+layerMinimum)/(rawMaximum+layerMinimum)
        let saturation=1-p*0.97*(1-1e-6)
        let n=pixelUM*pixelUM/(0.2*1.6)
        let lambda=OriginalDiscreteGrain.poissonRate(
            n:n,probability:p,saturation:saturation
        )
        let expectedMean=OriginalDiscreteGrain.opticalDensity(
            count:lambda,densityMaximum:rawMaximum,
            layerMinimum:layerMinimum,
            numberOfParticles:n,saturation:saturation
        )-layerMinimum
        precondition(abs(expectedMean-sourceDensity) < 1e-10,
                     "Source Poisson-thinning marginal mean incorrect")
        let expectedVariance=(rawMaximum+layerMinimum)*
            (rawMaximum+layerMinimum)*p*saturation/n
        let varianceFromThinning=pow(
            (rawMaximum+layerMinimum)*saturation/n,2
        )*lambda
        precondition(abs(expectedVariance-varianceFromThinning)<1e-12,
                     "Source Poisson/binomial thinning variance incorrect")
        print("PASS: source Poisson/Binomial thinning equivalence, exact analytical moments.")

        let sampled=run(side:160,pixelUM:9.0)
        precondition(sampled.mean > 0.2 && sampled.mean < 0.55,
                     "Discrete particle mean unreasonable")
        let lowCount=run(side:96,pixelUM:1.8)
        precondition(lowCount.variance > sampled.variance*0.4,
                     "Small-count exact Poisson sampling not responsive")
        print("PASS: source-law GPU discrete particle path, low/high-rate samplers and optical-density ordering.")
    }
}
