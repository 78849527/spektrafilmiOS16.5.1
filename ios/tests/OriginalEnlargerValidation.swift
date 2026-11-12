import Foundation
import Darwin

@main
struct OriginalEnlargerValidation {
    static func decode(_ s:String, count:Int)->[Double] {
        let raw=[UInt8](Data(base64Encoded:s)!)
        precondition(raw.count==count*4)
        return (0..<count).map { i in
            let k=i*4
            let bits=UInt32(raw[k]) | UInt32(raw[k+1]) << 8 |
                     UInt32(raw[k+2]) << 16 | UInt32(raw[k+3]) << 24
            return Double(Float(bitPattern:bits))
        }
    }
    static func near(_ value:Double,_ source:Double,
                     relative:Double=0.0007, absolute:Double=0.00001) -> Bool {
        value.isFinite && source.isFinite &&
        abs(value-source) <= max(absolute,abs(source)*relative)
    }
    static func main() {
        setbuf(stdout,nil)
        precondition(GeneratedOriginalOptics.printNeutralCCByPair.count==128)
        precondition(GeneratedEnlargerReference.pairs.count==128)
        let source=decode(GeneratedOriginalOptics.enlargerUnfiltered,count:81)
        let indexes=[0,16,34,49,80]
        let settings=OriginalEnlarger.Settings(
            enabled:true,normalizeExposure:true,
            mShift:12,yShift:-9,preflashExposure:0.15,
            preflashMShift:6,preflashYShift:-7
        )
        precondition(settings.valid)
        var checked=0
        for example in GeneratedEnlargerReference.pairs {
            let key=example.film+"|"+example.paper
            guard let cc=GeneratedOriginalOptics.printNeutralCCByPair[key],
                  let film=GeneratedSpectralData.profiles[example.film],
                  let paper=GeneratedSpectralData.profiles[example.paper]
            else { preconditionFailure("Missing profile \(key)") }
            for i in 0..<3 {
                precondition(near(cc[i],example.cc[i],relative:0,absolute:1e-10))
            }
            let spectrum=OriginalEnlarger.filteredSpectrum(
                source:source,cc:OriginalEnlarger.mainCC(
                    neutral:cc,settings:settings
                )
            )
            for (ix,i) in indexes.enumerated() {
                precondition(near(spectrum[i],example.mainSpectral[ix]),
                             "M/Y CC source \(key) wl \(i)")
            }
            let base=decode(film.baseDensity,count:81)
            let channel=decode(film.channelDensity,count:243)
            let sensitivity=decode(paper.logSensitivity,count:243)
            let paperResponse=(0..<81).map { i in
                (0..<3).map { ch in pow(10.0,sensitivity[i*3+ch]) }
            }
            let weights=OriginalEnlarger.weights(
                illuminant:spectrum,paperSensitivity:paperResponse
            )
            let density=[0.2,0.36,0.70]
            var raw=[0.0,0.0,0.0]
            for i in 0..<81 {
                var d=base[i]
                for c in 0..<3 {
                    d += channel[i*3+c]*density[c]
                }
                let transmitted=pow(10.0,-d)
                for c in 0..<3 { raw[c]+=transmitted*weights[i][c] }
            }
            let flash=OriginalEnlarger.preflashRaw(
                filmBaseDensity:base,source:source,
                neutral:cc,settings:settings,
                paperSensitivity:paperResponse
            )
            for c in 0..<3 {
                precondition(near(raw[c],example.mainRaw[c]),
                             "Source main enlarger raw \(key), channel \(c)")
                precondition(near(flash[c],example.preflashRaw[c]),
                             "Source preflash raw \(key), channel \(c)")
                precondition(flash[c]>0)
            }
            let combined=OriginalEnlarger.rawWithPreflash(
                sceneRaw:raw,reference:example.midgrayFactor,
                flashRaw:flash,normalize:true
            )
            for c in 0..<3 {
                precondition(near(combined[c],
                                  raw[c]/example.midgrayFactor+flash[c]))
            }
            checked += 1
        }
        precondition(checked==128)
        print("PASS: 128 measured film/print pairs' source CMY filtration and spectral raw exposure.")
        print("PASS: 128 source preflash spectra, independent flash CC, preflash intensity and geomean normalization.")
        let a=OriginalEnlarger.Settings(enabled:false)
        precondition(a.valid && a.preflashExposure==0)
        precondition(OriginalEnlarger.rawWithPreflash(
            sceneRaw:[2,4,6],reference:2,flashRaw:[0,0,0],
            normalize:true
        ) == [1,2,3])
        precondition(OriginalEnlarger.rawWithPreflash(
            sceneRaw:[2,4,6],reference:2,flashRaw:[0,0,0],
            normalize:false
        ) == [2,4,6])
        print("PASS: no-preflash legacy-path normalization identities.")
    }
}
