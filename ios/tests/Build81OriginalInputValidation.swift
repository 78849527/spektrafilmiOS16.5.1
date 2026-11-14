import Foundation

/// Build81/13-16: test actual Swift CPU stage against independently
/// executed and git-blob-pinned Python AST plus skimage 0.25.2.
/// No device nor end-to-end image parity is implied by this suite.
enum Build81OriginalInputValidation {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let m)=self {return m}
            return nil
        }
    }

    private static func readBits(_ row:[String]) throws -> [Double] {
        try row.map { text in
            guard let bit=UInt64(text,radix:16) else {
                throw Failure.invalid("Build81 Python oracle invalid binary64 hex")
            }
            return Double(bitPattern:bit)
        }
    }
    private static func size(_ raw:Any?) throws -> (Int,Int) {
        guard let values=raw as? [NSNumber],values.count==2 else {
            throw Failure.invalid("Build81 missing expected width/height")
        }
        return (values[0].intValue,values[1].intValue)
    }
    private static func pair(_ raw:Any?) throws -> (Double,Double) {
        guard let values=raw as? [NSNumber],values.count==2 else {
            throw Failure.invalid("Build81 missing source pair")
        }
        return (values[0].doubleValue,values[1].doubleValue)
    }
    private static func point(_ p:Any?) throws
        -> Build81OriginalInputGamut.Point {
        let (x,y)=try pair(p)
        return .init(x:x,y:y)
    }

    static func evaluate() throws {
        guard let path=ProcessInfo.processInfo.environment[
            "BUILD81_ORIGINAL_INPUT_ORACLE"
        ] else {
            if ProcessInfo.processInfo.environment["BUILD81_ORACLE_REQUIRED"]=="1" {
                throw Failure.invalid("Build81 Python original source oracle absent")
            }
            print("UNVERIFIED Build81 geometry/preview/gamut: missing original oracle")
            return
        }
        let raw=try Data(contentsOf:URL(fileURLWithPath:path))
        guard let root=try JSONSerialization.jsonObject(with:raw) as? [String:Any],
              let pins=root["pinned_blobs"] as? [String:String],
              pins["crop_resize.py"]=="4737b922c34f5cf77f66f8bb022b0625e4e37dd1",
              pins["preview.py"]=="985c4099c775c6b3fc6fe660a0b467175d62f91f",
              pins["gamut_compression.py"]=="9783e7fcfc2909c4acdf2da53595c5404645dde9",
              root["skimage_version"] as? String=="0.25.2",
              let crops=root["crop"] as? [[String:Any]],
              let previews=root["preview"] as? [[String:Any]],
              let gamut=root["gamut"] as? [String:Any] else {
            throw Failure.invalid("Build81 Python reference blob/schema mismatch")
        }
        var croppedPixels=0
        for (caseID,item) in crops.enumerated() {
            guard let w=(item["width"] as? NSNumber)?.intValue,
                  let h=(item["height"] as? NSNumber)?.intValue,
                  let inputHex=item["input_bits"] as? [String],
                  let expectedHex=item["expected_bits"] as? [String] else {
                throw Failure.invalid("Build81 crop case malformed")
            }
            let (cx,cy)=try pair(item["center"])
            let (sx,sy)=try pair(item["size"])
            let (expectedW,expectedH)=try size(item["output_size"])
            let actual=try Build81OriginalCrop.crop(
                .init(width:w,height:h,rgb:readBits(inputHex)),
                centerX:cx,centerY:cy,sizeX:sx,sizeY:sy
            )
            guard actual.width==expectedW,actual.height==expectedH,
                  actual.rgb.count==expectedHex.count else {
                throw Failure.invalid("Build81 crop source geometry mismatch #\(caseID): "
                    + "Swift \(actual.width)x\(actual.height) vs "
                    + "Python \(expectedW)x\(expectedH)")
            }
            let expected=try readBits(expectedHex)
            for k in actual.rgb.indices {
                if actual.rgb[k].bitPattern != expected[k].bitPattern {
                    throw Failure.invalid(
                        "Build81 source crop bit drift #\(caseID) channel \(k)"
                    )
                }
            }
            let bridged=try OriginalSourcePixelIO.cropOriginal81(
                .init(width:w,height:h,rgb:try readBits(inputHex)),
                centerX:cx,centerY:cy,sizeX:sx,sizeY:sy
            )
            guard bridged.width==actual.width,bridged.height==actual.height,
                  bridged.rgb.elementsEqual(actual.rgb,by:{
                      $0.bitPattern==$1.bitPattern
                  }) else {
                throw Failure.invalid(
                    "Build81 actual OriginalSourcePixelIO crop bridge changed bits"
                )
            }
            croppedPixels+=actual.rgb.count
        }

        var previewSamples=0
        var maxError=0.0
        var sumAbs=0.0
        var sumSquare=0.0
        for (caseID,item) in previews.enumerated() {
            guard let w=(item["width"] as? NSNumber)?.intValue,
                  let h=(item["height"] as? NSNumber)?.intValue,
                  let maxSide=(item["max_size"] as? NSNumber)?.intValue,
                  let inputHex=item["input_bits"] as? [String],
                  let expected=item["expected"] as? [NSNumber] else {
                throw Failure.invalid("Build81 preview case malformed")
            }
            let (expW,expH)=try size(item["output_size"])
            let input=Build81OriginalCrop.Image(
                width:w,height:h,rgb:try readBits(inputHex)
            )
            let output=try Build81OriginalPreview.resizeForPreview(
                input,maxSide:maxSide
            )
            guard output.width==expW,output.height==expH,
                  output.rgb.count==expected.count else {
                throw Failure.invalid(
                    "Build81 Python preview geometry mismatch #\(caseID)")
            }
            let production=try OriginalSourcePixelIO.previewOriginal81(
                .init(width:w,height:h,rgb:input.rgb),maxSide:maxSide
            )
            guard production.width==output.width,
                  production.height==output.height,
                  production.rgb.elementsEqual(output.rgb,by:{
                      $0.bitPattern==$1.bitPattern
                  }) else {
                throw Failure.invalid(
                    "Build81 actual OriginalSourcePixelIO preview bridge changed bits"
                )
            }
            for k in output.rgb.indices {
                let ref=expected[k].doubleValue
                let error=abs(output.rgb[k]-ref)
                // Accept error bound pending scipy exact numerical kernel
                // verification. This bound is not bit-identical certification.
                let limit=3e-6+2e-6*abs(ref)
                if !output.rgb[k].isFinite || error>limit {
                    throw Failure.invalid(
                        "Build81 source preview difference #\(caseID) "
                        + "channel \(k) Swift=\(output.rgb[k]) "
                        + "Python=\(ref) abs=\(error) limit=\(limit)"
                    )
                }
                if item["zero_copy"] as? Bool==true &&
                   output.rgb[k].bitPattern != input.rgb[k].bitPattern {
                    throw Failure.invalid(
                        "Build81 original no-resize must preserve Float64 bits"
                    )
                }
                maxError=max(maxError,error)
                sumAbs+=error
                sumSquare+=error*error
                previewSamples+=1
            }
        }

        let white=try point(gamut["white"])
        guard let locusRaw=gamut["locus"] as? [[NSNumber]],
              let cases=gamut["cases"] as? [[String:Any]],
              let inactive=gamut["inactive"] as? [[NSNumber]] else {
            throw Failure.invalid("Build81 gamut test vectors malformed")
        }
        let locus=try locusRaw.map {try point($0)}
        var gamutChannels=0
        for (caseID,item) in cases.enumerated() {
            guard let rawKnee=item["knee"] as? [NSNumber],
                  rawKnee.count==3,
                  let inputRaw=item["input"] as? [[NSNumber]],
                  let expectedRaw=item["output"] as? [[NSNumber]],
                  let dRaw=item["knee_input"] as? [NSNumber],
                  let kneeRaw=item["knee_expected"] as? [NSNumber] else {
                throw Failure.invalid("Build81 gamut case malformed")
            }
            let knee=Build81OriginalInputGamut.Knee(
                threshold:rawKnee[0].doubleValue,
                limit:rawKnee[1].doubleValue,
                power:rawKnee[2].doubleValue
            )
            let xy=try inputRaw.map {try point($0)}
            let ref=try expectedRaw.map {try point($0)}
            let result=try Build81OriginalInputGamut.compress(
                xy,white:white,knee:knee,locus:locus
            )
            guard result.count==ref.count else {
                throw Failure.invalid("Build81 gamut sample count drift")
            }
            for k in result.indices {
                for (actual,expected) in [
                    (result[k].x,ref[k].x),(result[k].y,ref[k].y)
                ] {
                    guard actual.isFinite,
                          abs(actual-expected)<=1e-9 else {
                        throw Failure.invalid(
                            "Build81 source gamut xy mismatch #\(caseID) sample \(k)"
                        )
                    }
                    gamutChannels+=1
                }
            }
            for k in dRaw.indices {
                let actual=try Build81OriginalInputGamut.reinhardKnee(
                    dRaw[k].doubleValue,knee:knee
                )
                guard abs(actual-kneeRaw[k].doubleValue)<=1e-12 else {
                    throw Failure.invalid(
                        "Build81 Python source Reinhard knee mismatch #\(caseID)"
                    )
                }
                gamutChannels+=1
            }
            let identity=try Build81OriginalInputGamut.compress(
                xy,white:white,knee:knee,active:false,locus:locus
            )
            for k in identity.indices {
                let q=try point(inactive[k])
                if identity[k].x.bitPattern != q.x.bitPattern ||
                    identity[k].y.bitPattern != q.y.bitPattern {
                    throw Failure.invalid("Build81 input gamut off must be identity")
                }
            }
        }
        do {
            _=try Build81OriginalInputGamut.compress(
                [white],white:white,algorithm:.oklch,locus:locus
            )
            throw Failure.invalid("Unported Oklch mode silently succeeded")
        } catch Build81OriginalInputGamut.Failure.invalid {
            // Expected unsupported mode.
        }
        print("PASS Build81 Python crop \(crops.count) fixtures / "
              + "\(croppedPixels) Float64 exact bits; "
              + "preview \(previews.count) fixtures / \(previewSamples) "
              + "Double channels: MAE=\(sumAbs/Double(previewSamples)) "
              + "RMSE=\(sqrt(sumSquare/Double(previewSamples))) "
              + "max=\(maxError); gamut "
              + "\(cases.count) knee + \(gamutChannels) xy/knee channels. "
              + "Not full original GPU/RAW/image certification.")
    }
}
