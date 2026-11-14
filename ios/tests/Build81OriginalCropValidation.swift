import Foundation

/// Independent original Python AST -> Swift production crop regression.
/// This verifies exact Float64 copied RGB bits and pixel ordering.
/// It does not certify skimage preview interpolation or input gamut.
enum Build81OriginalCropValidation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason)=self { return reason }
            return nil
        }
    }

    static func evaluate() throws {
        guard let file=ProcessInfo.processInfo.environment[
            "BUILD81_CROP_ORACLE"
        ] else {
            print("UNVERIFIED Build81 source crop: Python oracle unavailable")
            return
        }
        let json=try Data(contentsOf:URL(fileURLWithPath:file))
        guard let root=try JSONSerialization.jsonObject(with:json) as? [String:Any],
              root["source_git_blob_sha"] as? String ==
                "4737b922c34f5cf77f66f8bb022b0625e4e37dd1",
              let cases=root["cases"] as? [[String:Any]],
              cases.count==13 else {
            throw Failure.invalid("Build81 pinned original Python crop JSON invalid")
        }
        var pixels=0,empty=0
        for caseData in cases {
            guard let name=caseData["name"] as? String,
                  let width=(caseData["width"] as? NSNumber)?.intValue,
                  let height=(caseData["height"] as? NSNumber)?.intValue,
                  let cx=caseData["center"] as? [NSNumber],cx.count==2,
                  let sx=caseData["size"] as? [NSNumber],sx.count==2,
                  let w=(caseData["expected_width"] as? NSNumber)?.intValue,
                  let h=(caseData["expected_height"] as? NSNumber)?.intValue,
                  let expected=caseData["expected_rgb"] as? [NSNumber],
                  expected.count==w*h*3 else {
                throw Failure.invalid("Python crop fixture malformed")
            }
            let data=(1...(width*height*3)).map { Double($0)/8.0 }
            let source=OriginalSourcePixelIO.Frame(
                width:width,height:height,rgb:data
            )
            if w==0 || h==0 {
                do {
                    _=try Build81OriginalCrop.crop(
                        source,center:(cx[0].doubleValue,cx[1].doubleValue),
                        size:(sx[0].doubleValue,sx[1].doubleValue)
                    )
                    throw Failure.invalid(
                        "Swift crop returned nonempty for original Python empty: " + name
                    )
                } catch Build81OriginalCrop.Failure.invalid {
                    empty+=1
                }
                continue
            }
            let frame=try Build81OriginalCrop.crop(
                source,center:(cx[0].doubleValue,cx[1].doubleValue),
                size:(sx[0].doubleValue,sx[1].doubleValue)
            )
            guard frame.width==w,frame.height==h,
                  frame.rgb.count==expected.count else {
                throw Failure.invalid("Build81 original crop shape mismatch: " + name)
            }
            for i in expected.indices {
                let target=expected[i].doubleValue
                guard target.bitPattern==frame.rgb[i].bitPattern else {
                    throw Failure.invalid(
                        "Source Python crop pixel bit mismatch in " + name
                        + " channel \(i): \(target) vs \(frame.rgb[i])"
                    )
                }
                pixels+=1
            }
        }
        print("PASS Build81 original Python NumPy crop source "
              + "\(cases.count) fixtures, \(pixels) Float64 RGB channel bits, "
              + "\(empty) empty source slice rejected; "
              + "not skimage preview, gamut or full RAW parity")
    }
}
