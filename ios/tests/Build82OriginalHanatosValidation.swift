import Foundation

/// Build82 native CPU Double against actual pinned Python AST source,
/// with original full 192×192×81 F16 irradiance spectra and film profiles.
/// Tests source polynomial, warped surface, Gaussian, UV/IR + filter-normalized
/// sensitivity and runtime original Hanatos TC rebuild. Not iPhone render proof.
enum Build82OriginalHanatosValidation {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let v)=self {return v}
            return nil
        }
    }
    private static func numeric(_ obj:Any?,_ name:String) throws->[Double] {
        guard let raw=obj as? [NSNumber] else {
            throw Failure.invalid("Build82 Python missing "+name)
        }
        return raw.map {$0.doubleValue}
    }
    private static func cells(_ obj:Any?) throws->[(Int,Int)] {
        guard let rows=obj as? [[NSNumber]] else {
            throw Failure.invalid("Build82 Python source cells malformed")
        }
        return try rows.map { row in
            guard row.count==2 else {
                throw Failure.invalid("Build82 Python source TC index malformed")
            }
            return (row[0].intValue,row[1].intValue)
        }
    }
    private static func check(
        actual:Double,expected:Double,
        absolute:Double=3e-8,relative:Double=3e-7,
        name:String
    ) throws {
        let err=abs(actual-expected)
        let maxAllowed=absolute+relative*abs(expected)
        guard actual.isFinite,expected.isFinite,err<=maxAllowed else {
            throw Failure.invalid(
                "Build82 Python Float64 mismatch \(name): "
                + "Swift=\(actual), source=\(expected), "
                + "error=\(err), limit=\(maxAllowed)"
            )
        }
    }

    static func evaluate() throws {
        guard let oraclePath=ProcessInfo.processInfo.environment[
                  "BUILD82_HANATOS_ORACLE"],
              let npyPath=ProcessInfo.processInfo.environment[
                  "BUILD82_SOURCE_SPECTRA_NPY"] else {
            if ProcessInfo.processInfo.environment[
                "BUILD82_ORACLE_REQUIRED"]=="1" {
                throw Failure.invalid("Build82 pinned source Hanatos Python oracle absent")
            }
            print("UNVERIFIED Build82 full source spectrum: oracle not supplied")
            return
        }
        let bytes=try Data(contentsOf:URL(fileURLWithPath:oraclePath))
        guard let root=try JSONSerialization.jsonObject(with:bytes)
                as? [String:Any],
              let source=root["pinned"] as? [String:String],
              source["spectral_upsampling.py"]==
                "bb75f8a00d00eb02ba571c6cfdbec88a8c0194cb",
              source["color_filters.py"]==
                "73849be82f7e32e21cd9bf3e116ba244a931188b",
              root["colour_version"] as? String=="0.4.6",
              root["source_npy_sha256"] as? String ==
                Build82GeneratedHanatosProfiles.sourceSHA256,
              Build82GeneratedHanatosProfiles.all.count==20,
              let cases=root["cases"] as? [[String:Any]],
              cases.count==3,
              let surface=root["surface"] as? [String:Any] else {
            throw Failure.invalid("Build82 pinned source fixture schema changed")
        }
        let grid=try Build82OriginalSpectralRuntime.loadOriginalNPY(
            URL(fileURLWithPath:npyPath)
        )
        guard grid.sourceSHA==Build82GeneratedHanatosProfiles.sourceSHA256 else {
            throw Failure.invalid("Build82 source data SHA256 drift")
        }

        guard let stock=surface["stock"] as? String,
              let profile=Build82GeneratedHanatosProfiles.all[stock],
              let sampleRaw=surface["poly4"] as? [[NSNumber]],
              let warpRaw=surface["warped"] as? [[NSNumber]],
              let alpha=(surface["warped_alpha"] as? NSNumber)?.doubleValue,
              let window=surface["window"] as? [NSNumber],
              let blur=(surface["gaussian_sigma"] as? NSNumber)?.doubleValue
        else {
            throw Failure.invalid("Build82 source poly4/warped/erf samples missing")
        }
        let surfaceCells=try cells(surface["cells"])
        let updatedSurface=profile.surface.map {$0+[alpha]}
        var surfaceSamples=0
        for k in surfaceCells.indices {
            let x=surfaceCells[k].0,y=surfaceCells[k].1
            let tc=Build82OriginalHanatosSurface.Point(
                x:Double(x)/191,y:Double(y)/191
            )
            for ch in 0..<3 {
                let p=try Build82OriginalHanatosSurface.correctionStops(
                    tc:tc,channel:ch,params:profile.surface,
                    referenceXY:profile.referenceXY,model:.poly4
                )
                let w=try Build82OriginalHanatosSurface.correctionStops(
                    tc:tc,channel:ch,params:updatedSurface,
                    referenceXY:profile.referenceXY,model:.poly4WarpXY
                )
                try check(actual:p,expected:sampleRaw[k][ch].doubleValue,
                          absolute:1e-10,relative:1e-9,
                          name:"source poly4 cell \(k) ch \(ch)")
                try check(actual:w,expected:warpRaw[k][ch].doubleValue,
                          absolute:1e-10,relative:1e-9,
                          name:"source poly4 warped cell \(k) ch \(ch)")
                surfaceSamples+=2
            }
        }
        let originalWindow=try Build82OriginalSpectralRuntime.originalERF4Window(
            profile.window
        )
        guard window.count==81 else {
            throw Failure.invalid("Build82 expected erf4 window length drift")
        }
        for i in 0..<81 {
            try check(
                actual:originalWindow[i],
                expected:window[i].doubleValue,
                absolute:1e-12,relative:1e-11,
                name:"erf4 window \(i)"
            )
        }
        let gaussianInput=try numeric(
            surface["gaussian_input"],"gaussian_input"
        )
        let expectedGaussian=try numeric(
            surface["gaussian_expected"],"gaussian_expected"
        )
        let filtered=try Build82OriginalSpectralRuntime.spectralGaussian(
            gaussianInput,sigma:blur
        )
        guard filtered.count==81,expectedGaussian.count==81 else {
            throw Failure.invalid("Build82 source Gaussian vector length drift")
        }
        for i in 0..<81 {
            try check(actual:filtered[i],expected:expectedGaussian[i],
                      absolute:1e-11,relative:1e-10,
                      name:"scipy reflect gaussian \(i)")
        }

        var fullSamples=0
        var maxError=0.0
        for (caseID,test) in cases.enumerated() {
            guard let stock=test["stock"] as? String,
                  let profile=Build82GeneratedHanatosProfiles.all[stock],
                  let refs=test["expected"] as? [[NSNumber]]
            else {
                throw Failure.invalid("Build82 TC case stock/vector missing")
            }
            let uv=try numeric(test["filter_uv"],"filter_uv")
            let ir=try numeric(test["filter_ir"],"filter_ir")
            guard uv.count==3,ir.count==3 else {
                throw Failure.invalid("Build82 original camera filter dimensions")
            }
            let filter=OriginalSourceCameraBandpass.Settings(
                uv:.init(amount:uv[0],centerNM:uv[1],widthNM:uv[2]),
                ir:.init(amount:ir[0],centerNM:ir[1],widthNM:ir[2])
            )
            let native=try Build82OriginalSpectralRuntime.make(
                profile:profile,grid:grid,filter:filter,
                spectralGaussianBlur:0,applyWindow:true,applySurface:true,
                compressInputXY:false
            )
            let coords=try cells(test["cells"])
            guard refs.count==coords.count,native.count==192*192*3 else {
                throw Failure.invalid("Build82 computed original TC LUT bad shape")
            }
            for k in coords.indices {
                let (x,y)=coords[k]
                for ch in 0..<3 {
                    let actual=native[(x*192+y)*3+ch]
                    let expected=refs[k][ch].doubleValue
                    try check(actual:actual,expected:expected,
                              name:"source Hanatos LUT #\(caseID) "
                                   +"cell \(x),\(y) ch \(ch)")
                    maxError=max(maxError,abs(actual-expected))
                    fullSamples+=1
                }
            }
        }
        // Unsupported format and incorrect stock data must not silently
        // switch to old stock LUT or mobile F16 approximation.
        var bad=profile
        bad=Build82OriginalSpectralRuntime.Profile(
            stock:bad.stock,reference:bad.reference,
            referenceXY:bad.referenceXY,illuminant:bad.illuminant,
            sensitivity:Array(bad.sensitivity.dropLast()),
            window:bad.window,surface:bad.surface
        )
        do {
            _=try Build82OriginalSpectralRuntime.make(
                profile:bad,grid:grid,compressInputXY:false
            )
            throw Failure.invalid("Build82 accepted malformed sensitivity")
        } catch Build82OriginalSpectralRuntime.Failure.invalid {
            // Expected fail-closed.
        }
        print("PASS Build82 source AST Hanatos "
            +"\(cases.count) full 192×192×81 TC recomputes "
            +"with original UV/IR, \(fullSamples) real source channels "
            +"maxAbs=\(maxError); poly4/warp \(surfaceSamples), "
            +"81 erf4, 81 SciPy reflect Gaussian samples. "
            +"Not certified full input-gamut remap, logiflex8, RAW or device.")
    }
}
