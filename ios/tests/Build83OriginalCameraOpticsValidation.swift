import Foundation

/// Build83 actual CPU Double stages vs pinned original Python source.
/// Runs source production photon-log stage & photographic PSF + reflect FFT,
/// not a screenshot or visual equivalence test.
enum Build83OriginalCameraOpticsValidation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let why) = self {return why}
            return nil
        }
    }
    private static func numbers(_ value:Any?,label:String) throws -> [Double] {
        guard let list=value as? [NSNumber] else {
            throw Failure.invalid("Build83 original Python missing "+label)
        }
        return list.map {$0.doubleValue}
    }
    private static func value(_ row:[String:Any],_ name:String) throws -> Double {
        guard let v=row[name] as? NSNumber else {
            throw Failure.invalid("Build83 Python missing "+name)
        }
        return v.doubleValue
    }
    private static func validate(
        _ actual:[Double],_ source:[Double],
        absolute:Double,relative:Double,context:String
    ) throws -> (Double,Double) {
        guard actual.count==source.count else {
            throw Failure.invalid("Build83 original vector shape drift: "+context)
        }
        var maxAbs=0.0,sumAbs=0.0
        for i in actual.indices {
            let d=abs(actual[i]-source[i])
            let limit=absolute+relative*abs(source[i])
            guard actual[i].isFinite,source[i].isFinite,d<=limit else {
                throw Failure.invalid(
                    "Build83 Python source numerical drift in \(context) channel \(i): "
                    +"Swift=\(actual[i]), Python=\(source[i]), "
                    +"error=\(d), limit=\(limit)"
                )
            }
            maxAbs=max(maxAbs,d)
            sumAbs+=d
        }
        return (maxAbs,sumAbs)
    }
    static func evaluate() throws {
        guard let path=ProcessInfo.processInfo.environment[
            "BUILD83_SOURCE_ORACLE"] else {
            if ProcessInfo.processInfo.environment[
                "BUILD83_ORACLE_REQUIRED"]=="1" {
                throw Failure.invalid("Build83 pinned Python source oracle missing")
            }
            print("UNVERIFIED Build83 original photon/2D optics not supplied")
            return
        }
        let raw=try Data(contentsOf:URL(fileURLWithPath:path))
        guard let root=try JSONSerialization.jsonObject(with:raw)
                as? [String:Any],
              root["source_sha"] as? String=="3bb2c2d2801ff68b92019cf1dbcbb133d60832bc",
              let pins=root["source_blobs"] as? [String:String],
              pins["src/spektrafilm/runtime/stages/filming.py"] ==
                  "b58759160dfa9dd45b5528b09b24ffafb5493b66",
              pins["src/spektrafilm/utils/numba_boost_hightlights.py"] ==
                  "61cb5ca89163762335674279a9743801e13e0e8f",
              pins["src/spektrafilm/model/diffusion.py"] ==
                  "cb22136f9d6a65e32ab54fc6f46f64f308e1a4f7",
              let exposure=root["exposure"] as? [[String:Any]],
              let diffusion=root["diffusion"] as? [[String:Any]],
              exposure.count==6,diffusion.count==4 else {
            throw Failure.invalid("Build83 source oracle pin/schema mismatch")
        }
        var expMax=0.0
        var rawSamples=0
        for (id,row) in exposure.enumerated() {
            let input=try numbers(row["input"],label:"raw")
            let actualExposed=try Build83OriginalCameraPhoton
                .exposureCompensated(input,ev:value(row,"ev"))
            let expectedExposed=try numbers(row["exposed"],label:"exposed")
            let e=try validate(actualExposed,expectedExposed,
                               absolute:2e-13,relative:3e-13,
                               context:"original RAW EV #\(id)")
            expMax=max(expMax,e.0)
            var boosted=actualExposed
            try OriginalSourceCameraOptics.boostHighlightsInPlace(
                &boosted,boostEV:value(row,"boost_ev"),
                boostRange:value(row,"boost_range"),
                protectEV:value(row,"protect_ev")
            )
            let expectedBoosted=try numbers(row["boosted"],label:"boosted")
            let b=try validate(boosted,expectedBoosted,
                               absolute:2e-10,relative:2e-9,
                               context:"original Numba RAW highlight boost #\(id)")
            expMax=max(expMax,b.0)
            let log=try Build83OriginalCameraPhoton.logExposure(
                photons:boosted,
                filmingReferenceScale:value(row,"reference_scale")
            )
            let expectedLog=try numbers(row["log"],label:"log")
            let l=try validate(log,expectedLog,
                               absolute:2e-12,relative:2e-12,
                               context:"source post-optics photon log10 #\(id)")
            expMax=max(expMax,l.0)
            rawSamples+=input.count*3
        }

        var psfMax=0.0
        var imageMax=0.0
        var psfSamples=0
        var imageSamples=0
        for row in diffusion {
            guard let name=row["family"] as? String,
                  let family=OriginalSourceDiffusion.Family(rawValue:name),
                  let width=(row["width"] as? NSNumber)?.intValue,
                  let height=(row["height"] as? NSNumber)?.intValue,
                  let radius=(row["radius"] as? NSNumber)?.intValue else {
                throw Failure.invalid("Build83 Python original family/shape invalid")
            }
            var settings=OriginalSourceDiffusion.Settings()
            settings.active=true
            settings.family=family
            settings.strength=try value(row,"strength")
            settings.spatialScale=try value(row,"spatial_scale")
            settings.haloWarmth=try value(row,"halo_warmth")
            let pixelUM=try value(row,"pixel_um")
            let psf=try OriginalSourceDiffusion.psf(
                width:width,height:height,pixelUM:pixelUM,settings:settings
            )
            guard psf.radius==radius else {
                throw Failure.invalid(
                    "Build83 original photographic PSF radius drift \(name): "
                    +"Swift=\(psf.radius), Python=\(radius)"
                )
            }
            let referencePSF=try numbers(row["psf"],label:"PSF "+name)
            let pe=try validate(psf.data,referencePSF,
                                absolute:1e-10,relative:1e-8,
                                context:"original photographic PSF "+name)
            psfMax=max(psfMax,pe.0)
            psfSamples+=referencePSF.count
            let input=try numbers(row["source_rgb"],label:"image "+name)
            let source=try numbers(row["output_rgb"],label:"output "+name)
            let result=try OriginalSourceDiffusion.apply(
                input,width:width,height:height,
                pixelUM:pixelUM,settings:settings
            )
            let re=try validate(result,source,
                                absolute:2e-8,relative:2e-7,
                                context:"original full reflect FFT "+name)
            imageMax=max(imageMax,re.0)
            imageSamples+=source.count
        }
        let noChange=try Build83OriginalCameraPhoton.logExposure(
            photons:[-100,-1,-0.0,0,1e-10,1.0,1.2],
            filmingReferenceScale:1.0
        )
        guard noChange.count==7,
              noChange[0]==-10,
              noChange[1]==-10,
              noChange[3]==-10 else {
            throw Failure.invalid("Build83 source negative/zero photon log10 floor drift")
        }
        let report="PASS Build83 source camera 6 RAW photon vectors / \(rawSamples) checks max=\(expMax); 4 original diffusion families / \(psfSamples) PSF taps max=\(psfMax); \(imageSamples) FFT output channels max=\(imageMax). Not device certified."
        print(report)
    }
}
