import Foundation

/// Build80/10: compare actual upstream Python colour-science 0.4.6
/// whitepoint + ACES CAT02 Von Kries with Swift CPU Double implementation.
/// Only validates deterministic post-rawpy stage; NOT camera RAW decoding.
enum Build80OriginalRAWWhiteBalanceValidation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message)=self { return message }
            return nil
        }
    }

    static func evaluate() throws {
        guard let filepath=ProcessInfo.processInfo.environment[
            "BUILD80_RAW_WB_ORACLE"
        ] else {
            print("UNVERIFIED Build80 WB scientific parity: original Python oracle absent")
            return
        }
        let bytes=try Data(contentsOf:URL(fileURLWithPath:filepath))
        guard let root=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              root["source_git_blob_sha"] as? String ==
                "97e34feb80fe47a6a3b36fcb93bef626d397135a",
              root["colour_science"] as? String == "0.4.6",
              let inputs=root["input_bits"] as? [NSNumber],
              inputs.count==18,
              let target=root["target_whitepoint_xyz"] as? [NSNumber],
              target.count==3,
              let cases=root["cases"] as? [[String:Any]],
              cases.count==8 else {
            throw Failure.invalid("Build80 source white balance oracle invalid")
        }
        let input=inputs.map {Float(bitPattern:$0.uint32Value)}
        let targetXYZ=target.map { $0.doubleValue }
        var total=0
        var maxError=0.0
        var sumAbs=0.0
        var sumSquares=0.0

        for (caseIndex,item) in cases.enumerated() {
            guard let temp=(item["temperature"] as? NSNumber)?.doubleValue,
                  let expectedXYZ=item["whitepoint_xyz"] as? [NSNumber],
                  expectedXYZ.count==3,
                  let expected=item["expected_bits"] as? [NSNumber],
                  expected.count==input.count else {
                throw Failure.invalid("RAW WB original case malformed")
            }
            let white=try Build80OriginalRAWWhiteBalance.whitepointXYZ(kelvin:temp)
            for c in 0..<3 {
                let error=abs(white[c]-expectedXYZ[c].doubleValue)
                guard error<=2e-10 else {
                    throw Failure.invalid(
                        "RAW whitepoint CIE D/Kang2002 mismatch at "
                        + "temp \(temp) XYZ \(c): error \(error)"
                    )
                }
            }
            let converted=try Build80OriginalRAWWhiteBalance.adapt(
                input,sourceWhiteXYZ:white,targetWhiteXYZ:targetXYZ
            )
            let direct=try Build80OriginalRAWWhiteBalance.adaptFromTemperature(
                input,kelvin:temp
            )
            for c in input.indices {
                let source=Float(bitPattern:expected[c].uint32Value)
                let got=converted[c]
                let error=abs(Double(got)-Double(source))
                let limit=2e-6 + 2e-6*abs(Double(source))
                guard error<=limit,got.isFinite else {
                    throw Failure.invalid(
                        "Original Python vs Swift ACES CAT02 mismatch: "
                        + "case \(caseIndex) \(temp)K channel \(c), "
                        + "Swift=\(got), source=\(source), "
                        + "abs=\(error), limit=\(limit)"
                    )
                }
                guard direct[c].bitPattern==got.bitPattern else {
                    throw Failure.invalid(
                        "Build80 RAW WB temperature-to-matrix route drift"
                    )
                }
                total+=1
                maxError=max(maxError,error)
                sumAbs+=error
                sumSquares+=error*error
            }
        }
        // Keep unsafe inputs outside the source exact mode; never silently
        // replace an invalid whitepoint with D65 or default sRGB.
        for t in [Double.nan,Double.infinity,0,-1] {
            do {
                _=try Build80OriginalRAWWhiteBalance.whitepointXYZ(kelvin:t)
                throw Failure.invalid("Invalid RAW temperature accepted")
            } catch Build80OriginalRAWWhiteBalance.Failure.invalid {
                // Expected explicit rejection.
            }
        }
        print("PASS Build80 original Python CIE D/Kang2002 + CAT02 "
              + "ACES Float32 source \(total)/\(total) channels; "
              + "MAE=\(sumAbs/Double(total)), "
              + "RMSE=\(sqrt(sumSquares/Double(total))), "
              + "max=\(maxError), limit=2e-6+2e-6*abs(source). "
              + "NOT rawpy/LibRaw/demosaic, not iPhone whole-frame.")
    }
}
