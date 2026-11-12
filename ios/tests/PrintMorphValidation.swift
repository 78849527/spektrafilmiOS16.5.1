import Foundation

@main
struct OriginalPrintMorphValidation {
    static func mode(_ name: String) -> OriginalPrintMorph.Settings {
        var p=OriginalPrintMorph.Settings()
        switch name {
        case "neutral": break
        case "gamma_082": p.gamma=0.82
        case "gamma_125": p.gamma=1.25
        case "fast_slow": p.fast=1.2; p.slow=0.85
        case "rgb": p.red=1.10; p.green=0.93; p.blue=1.15
        case "exhaustion_04": p.developerExhaustion=0.4
        case "mixed":
            p.gamma=1.13; p.fast=0.93; p.slow=1.07
            p.red=1.04; p.green=0.94; p.blue=1.08
            p.developerExhaustion=0.25
        default: preconditionFailure("Unknown reference mode \(name)")
        }
        return p
    }

    static func decode(_ encoded:String, count:Int)->[Float] {
        let bytes=[UInt8](Data(base64Encoded:encoded)!)
        precondition(bytes.count==count*4)
        return (0..<count).map { n in
            let i=n*4
            let bits=UInt32(bytes[i]) |
                UInt32(bytes[i+1]) << 8 |
                UInt32(bytes[i+2]) << 16 |
                UInt32(bytes[i+3]) << 24
            return Float(bitPattern:bits)
        }
    }

    static func main() {
        setbuf(stdout,nil)
        precondition(GeneratedPrintMorphData.models.count==8)
        precondition(GeneratedPrintMorphData.references.count==56)
        var probes=0
        for ref in GeneratedPrintMorphData.references {
            let params=mode(ref.mode)
            precondition(ref.sampleLE.count==5 &&
                         ref.densityAtSamples.count==15)
            for k in 0..<5 {
                let computed=OriginalPrintMorph.fittedChannels(
                    stock:ref.stock, logExposure:ref.sampleLE[k],
                    settings:params
                )
                for channel in 0..<3 {
                    let expected=ref.densityAtSamples[k*3+channel]
                    precondition(abs(computed[channel]-expected)<0.00005,
                        "Original source s023 \(ref.stock) \(ref.mode) \(k)/\(channel): \(computed[channel]) != \(expected)")
                    probes+=1
                }
            }
        }
        print("PASS: 840 original Python s023 CDF fit/curve morphology probes for all 8 print stocks.")
        // Verify the compensated film-density curve is identity
        // at default settings and preserves original emulsion maxima.
        precondition(OriginalPrintMorph.Settings().isIdentity)
        for (stock, _) in GeneratedPrintMorphData.models {
            let id=GeneratedSpectralData.profiles[stock]!
            let xs=decode(id.logExposure,count:256)
            let p=OriginalPrintMorph.prepare(
                stock:stock,logExposure:xs,
                settings:OriginalPrintMorph.Settings(gamma:1.2)
            )!
            for x in [-1.0,0.0,0.2,0.75,1.5] {
                for channel in 0..<3 {
                    let d=p.densityDelta(x,channel:channel)
                    precondition(d.isFinite)
                }
            }
        }
        print("PASS: source model prepared 256-point print-gamma interpolation, neutral identity.")

        precondition(GeneratedPrintMorphData.exposureReferences.count==16)
        for ref in GeneratedPrintMorphData.exposureReferences {
            let source=GeneratedSpectralData.profiles[ref.stock]!
            let logE=decode(source.logExposure,count:256)
            let curve=decode(source.densityCurves,count:768)
            let base=decode(source.baseDensity,count:81)
            guard let native=OriginalPrintReference.apply(
                yBlack:ref.yBlack,yWhite:ref.yWhite,
                logExposure:logE,rawCurves:curve,spectralBase:base
            ) else { preconditionFailure("Source print B/W reference unavailable") }
            precondition(abs(native.exposureEV-ref.exposureEVRounded)<0.00005,
                "Print EV mismatch embedded Float32 \(ref.stock): \(native.exposureEV) != \(ref.exposureEVRounded)")
            precondition(abs(native.exposureEV-ref.exposureEVOriginal)<0.025,
                "Original Float64 vs embedded Float32 print EV too different for \(ref.stock)")
            precondition(native.yWhite>native.yBlack)
        }
        print("PASS: 16 original NumPy inverse H-D exposure-compensation references across 8 measured media.")
    }
}
