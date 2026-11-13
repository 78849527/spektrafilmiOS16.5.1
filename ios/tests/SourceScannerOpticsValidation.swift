import Foundation
import CryptoKit

/// Tests real production scanner lens and unsharp against the untouched
/// Python source fast_gaussian_filter: exact full-frame reflect FIR/YVV,
/// and source order ACES-linear -> lens blur -> unsharp -> later CCTF.
enum SourceScannerOpticsValidation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let message)=self{return message}
            return nil
        }
    }
    private struct Manifest:Decodable {
        let scope:String
        let cases:[Case]
    }
    private struct Case:Decodable {
        let name:String
        let width:Int
        let height:Int
        let lens:Double
        let sigma:Double
        let amount:Double
        let sha256:[String:String]
    }

    private static func read(
        _ base:URL,record:Case,stage:String
    ) throws -> [Double] {
        guard let expected=record.sha256[stage] else {
            throw Failure.invalid("Python scanner stage missing: " +
                record.name+"/"+stage)
        }
        let path=base.appendingPathComponent(
            record.name+"."+stage+".f64le"
        )
        let bytes=try Data(contentsOf:path)
        let sum=SHA256.hash(data:bytes).map {
            String(format:"%02x",$0)
        }.joined()
        guard sum==expected,
              bytes.count==record.width*record.height*3*8 else {
            throw Failure.invalid("Source scanner SHA/size mismatch " +
                record.name+"/"+stage)
        }
        return bytes.withUnsafeBytes { raw in
            (0..<(record.width*record.height*3)).map { i in
                let bits=raw.loadUnaligned(
                    fromByteOffset:i*8,as:UInt64.self
                )
                return Double(bitPattern:UInt64(littleEndian:bits))
            }
        }
    }

    static func evaluate(directory:URL) throws {
        let meta=try Data(
            contentsOf:directory.appendingPathComponent("manifest.json")
        )
        let manifest=try JSONDecoder().decode(Manifest.self,from:meta)
        guard manifest.scope ==
            "original-source-scanning-linear-RGB-lens-FIR-YVV-unsharp",
              manifest.cases.count==8 else {
            throw Failure.invalid("Scanner original Python scope changed")
        }
        var maxError=0.0
        var count=0
        for record in manifest.cases {
            let source=try read(
                directory,record:record,stage:"input"
            )
            let settings=OriginalSourceScannerOptics.Settings(
                lensBlurSigma:record.lens,
                unsharpSigma:record.sigma,
                unsharpAmount:record.amount
            )
            var observed=[String:[Double]]()
            var linear=source
            try OriginalSourceScannerOptics.applyInPlace(
                &linear,width:record.width,height:record.height,
                settings:settings,
                stageDoubleObserver: {stage,values in
                    observed[stage]=values
                }
            )
            if settings.active {
                guard observed["scannerLinear"] != nil else {
                    throw Failure.invalid("Source scanner did not emit linear result")
                }
            } else if !observed.isEmpty {
                throw Failure.invalid("Disabled scanner altered pipeline")
            }
            let expectedStages=record.sha256.keys.filter{$0 != "input"}
            for stage in expectedStages {
                let expected=try read(
                    directory,record:record,stage:stage
                )
                let actual=stage=="scannerLinear"
                    ? linear : observed[stage]
                guard let actual,actual.count==expected.count else {
                    throw Failure.invalid("Scanner stage not computed "+stage)
                }
                var total=0.0, maximum=0.0, worst=0
                for i in expected.indices {
                    let delta=abs(expected[i]-actual[i])
                    guard delta.isFinite else {
                        throw Failure.invalid("NaN/Inf scanner stage "+stage)
                    }
                    total+=delta
                    if delta>maximum {maximum=delta;worst=i}
                }
                let mae=total/Double(expected.count)
                maxError=max(maxError,maximum)
                count+=expected.count
                print("Original scanner \(record.name)/\(stage): " +
                      "channels=\(expected.count) MAE=\(mae) " +
                      "max=\(maximum) pixel=\(worst/3) channel=\(worst%3)")
                guard maximum<=3e-10 && mae<=1e-11 else {
                    throw Failure.invalid(
                        "FAIL real Python source scanner \(record.name)/\(stage) " +
                        "MAE=\(mae) max=\(maximum); " +
                        "never silently substitute Core Image Gaussian"
                    )
                }
            }
        }
        // Existing full-resolution 12MP image remains independently
        // supported with source scanner effects disabled. Enabling these
        // effects reserves additional memory; insufficient RAM MUST fail.
        var rejected=false
        do {
            try OriginalSourcePhysicalImage.validateMemoryBudget(
                width:3888,height:2592,
                additionalBytesPerPixel:
                    OriginalSourcePhysicalImage.scannerFinishExtraBytesPerPixel,
                physicalMemory:4_500_000_000,
                processAvailableMemory:3_140_000_000
            )
        } catch OriginalSourcePhysicalImage.Failure.invalid(let text) {
            rejected=text.contains("内存预算不足")
        }
        guard rejected else {
            throw Failure.invalid(
                "Optional scanner Gaussian 10MP extra memory gate was lost"
            )
        }
        // Old already user-verified 10MP source image without finishing
        // must still be admitted under the same simulated budget.
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:3888,height:2592,
            physicalMemory:4_500_000_000,
            processAvailableMemory:3_140_000_000
        )
        print("PASS: real original Python scanner lens FIR/YVV and " +
              "pre-CCTF Unsharp 8 frames, \(count) channels, " +
              "maxError=\(maxError), no default change; " +
              "additional scanner memory gate fails closed.")
    }
}
