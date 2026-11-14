import Foundation

/// Linux test compiles the REAL Swift source optical algorithm extracted
/// without Core Image wrappers and the REAL application halation module,
/// and compares them to fixture data from original upstream Python.
@main
enum SourceFilmHalationLinuxParity {
    enum Failure: Error { case mismatch(String) }

    static func photon(_ width:Int,_ height:Int) -> [Double] {
        (0..<(width*height*3)).map {Double(($0*17+3)%397)/71.0}
    }

    static func expected(_ payload:String,count:Int) throws -> [Double] {
        guard let data=Data(base64Encoded:payload),data.count==count*8 else {
            throw Failure.mismatch("Original Python Float64 frame invalid")
        }
        return data.withUnsafeBytes { raw in
            (0..<count).map {i in
                Double(bitPattern:UInt64(littleEndian:raw.loadUnaligned(
                    fromByteOffset:i*8,as:UInt64.self
                )))
            }
        }
    }

    static func main() throws {
        let records=GeneratedSourceCameraReference.filmHalation
        guard records.count==5 else {
            throw Failure.mismatch("Expected five independent original Python frames")
        }
        for rec in records {
            var actual=photon(rec.width,rec.height)
            let source=try expected(rec.output,count:actual.count)
            let settings=OriginalSourceFilmHalation.Settings(
                active:true,
                scatterAmount:rec.scatter,
                scatterSpatialScale:rec.scatterScale,
                halationAmount:rec.halation,
                halationSpatialScale:rec.halationScale,
                filmFormatMM:rec.pixelUM*Double(max(rec.width,rec.height))/1000.0
            )
            try OriginalSourceFilmHalation.applyInPlace(
                &actual,width:rec.width,height:rec.height,
                settings:settings
            )
            let errors=zip(actual,source).map {abs($0-$1)}
            let maxError=errors.max() ?? .infinity
            let meanError=errors.reduce(0,+)/Double(errors.count)
            let label="\(rec.width)x\(rec.height) scatter=\(rec.scatter) bounce=\(rec.halation)"
            print("SOURCE_PARITY \(label) max=\(maxError) mae=\(meanError)")
            guard maxError.isFinite,maxError < 3e-8 else {
                throw Failure.mismatch("Python vs Swift numerical mismatch: \(label), max=\(maxError)")
            }
        }
        // Identity path must keep full RGB values without resorting to LUT.
        var ident=photon(7,5)
        let original=ident
        try OriginalSourceFilmHalation.applyInPlace(
            &ident,width:7,height:5,
            settings:.init(active:false)
        )
        guard ident==original else {
            throw Failure.mismatch("Disabled source halation changed original photons")
        }
        print("PASS: 5 original Python full-image tests and disabled identity (Double)")
    }
}
