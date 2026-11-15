import Foundation

@main
enum Build87PrintDiffusion108Parity {
    enum Failure:Error {case invalid(String)}
    static func nums(_ item:[String:Any],_ key:String) throws -> [Double] {
        guard let a=item[key] as? [NSNumber] else {
            throw Failure.invalid("Missing original diffusion source "+key)
        }
        return a.map{$0.doubleValue}
    }
    static func value(_ item:[String:Any],_ key:String) throws -> Double {
        guard let v=item[key] as? NSNumber else {
            throw Failure.invalid("Missing source "+key)
        }
        return v.doubleValue
    }
    static func number(_ item:[String:Any],_ key:String) throws -> Int {
        guard let v=item[key] as? NSNumber else {
            throw Failure.invalid("Missing source "+key)
        }
        return v.intValue
    }
    static func assertClose(
        _ actual:[Double],_ reference:[Double],
        _ label:String,tol:Double=3e-8
    ) throws -> Double {
        guard actual.count==reference.count else {
            throw Failure.invalid(label+" shape mismatch")
        }
        var worst=0.0
        for i in actual.indices {
            let delta=abs(actual[i]-reference[i])
            guard delta.isFinite,delta<=tol else {
                throw Failure.invalid(
                    "\(label) #\(i): Swift \(actual[i]), " +
                    "source \(reference[i]), Δ\(delta)"
                )
            }
            worst=max(worst,delta)
        }
        return worst
    }
    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need source Python diffusion FFT oracle")
        }
        let raw=try Data(contentsOf:URL(
            fileURLWithPath:CommandLine.arguments[1]))
        guard let obj=try JSONSerialization.jsonObject(with:raw)
                as? [String:Any],
              let cases=obj["cases"] as? [[String:Any]],
              cases.count==108 else {
            throw Failure.invalid("Missing 108 original source diffusion frames")
        }
        var psfWorst=0.0,fftWorst=0.0,fractionWorst=0.0
        var narrow=0,allzero=0,tiny=0
        for (index,item) in cases.enumerated() {
            guard let stock=item["family"] as? String,
                  let family=OriginalSourceDiffusion.Family(rawValue:stock),
                  let params=item["settings"] as? [String:Any] else {
                throw Failure.invalid("Missing source diffusion family")
            }
            var s=OriginalSourceDiffusion.Settings()
            s.active=true
            s.family=family
            s.strength=try value(params,"strength")
            s.spatialScale=try value(params,"spatial_scale")
            s.haloWarmth=try value(params,"halo_warmth")
            s.coreIntensity=try value(params,"core_intensity")
            s.haloIntensity=try value(params,"halo_intensity")
            s.bloomIntensity=try value(params,"bloom_intensity")
            s.coreSize=try value(params,"core_size")
            s.haloSize=try value(params,"halo_size")
            s.bloomSize=try value(params,"bloom_size")
            let width=try number(item,"width")
            let height=try number(item,"height")
            let pixelUM=try value(item,"pixelUM")
            let input=try nums(item,"input")
            if width<3 || height<3 {narrow+=1}
            if s.coreIntensity==0 && s.haloIntensity==0 &&
               s.bloomIntensity==0 {allzero+=1}
            if s.spatialScale<1e-6 {tiny+=1}
            let referenceRadius=try number(item,"radius")
            let actualRadius=try OriginalSourceDiffusion.radius(
                width:width,height:height,pixelUM:pixelUM,settings:s
            )
            guard actualRadius==referenceRadius else {
                throw Failure.invalid(
                    "Source reflect FFT radius #\(index), " +
                    "Swift \(actualRadius), Python \(referenceRadius)"
                )
            }
            let sourcePSF=try nums(item,"sourcePSF")
            let actualPSF=try OriginalSourceDiffusion.psf(
                width:width,height:height,pixelUM:pixelUM,settings:s
            )
            guard actualPSF.radius==referenceRadius else {
                throw Failure.invalid("Source PSF radius disagreement")
            }
            psfWorst=max(psfWorst,try assertClose(
                actualPSF.data,sourcePSF,
                "source 2D three-channel PSF \(stock) #\(index)"
            ))
            fractionWorst=max(fractionWorst,try assertClose(
                [OriginalSourceDiffusion.scatterFraction(s)],
                [try value(item,"sourceFraction")],
                "source scatter fraction \(stock) #\(index)"
            ))
            let real=try OriginalSourceDiffusion.apply(
                input,width:width,height:height,
                pixelUM:pixelUM,settings:s
            )
            fftWorst=max(fftWorst,try assertClose(
                real,try nums(item,"output"),
                "source 2D FIR/FFT print-photon diffused \(stock) #\(index)"
            ))
        }
        guard narrow>0,allzero==36,tiny==36 else {
            throw Failure.invalid("Original narrow/fallback/scale cases missing")
        }
        print("BUILD87 ORIGINAL 2D PRINT DIFFUSION PASSED: " +
              "108 full RGB source FFT frames; four PSF families, " +
              "reflect 1x1/1xN/2xN; source all-zero intensity fallback " +
              "and 1e-7 spatial scale; PSF max=\(psfWorst), " +
              "scatter fraction max=\(fractionWorst), " +
              "final RGB photons max=\(fftWorst) with abs tol=3e-8.")
    }
}
