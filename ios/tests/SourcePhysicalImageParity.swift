import Foundation
import CryptoKit

/// v1.8.22 continuous REAL SOURCE Python physical whole-image evidence.
/// Every reference buffer comes from the imported Python original modules;
/// Swift runs the same product ImageIO ingress, nonlinear film/H-D/scan
/// functions, and original two-dimensional spatial DIR filter.
enum SourcePhysicalImageParity {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }
    private struct Manifest: Decodable {
        let scope: String
        let cases: [Case]
    }
    private struct Case: Decodable {
        let name: String
        let film: String
        let paper: String
        let morph: String
        let width: Int
        let height: Int
        let pixelUM: Double
        let cameraEV: Double
        let paperEV: Double
        let flash: Double
        let flashM: Double
        let flashY: Double
        let shift: [Double]
        let sha256: [String: String]
    }

    static let stages = [
        "logRaw","initial","inhibitors","diffused",
        "correctedLog","density","printed"
    ]
    private static func read(_ path: URL, sha: String) throws -> Data {
        let data = try Data(contentsOf:path)
        let digest = SHA256.hash(data:data).map {
            String(format:"%02x",$0)
        }.joined()
        guard digest == sha else {
            throw Failure.invalid(
                "Python original image stage SHA256 mismatch " +
                path.lastPathComponent
            )
        }
        return data
    }
    private static func original(
        fixtures: URL, name: String, stage: String,
        checksum: String, width: Int, height: Int
    ) throws -> [Double] {
        let bytes=try read(
            fixtures.appendingPathComponent(
                name + "." + stage + ".f64le"
            ),sha:checksum
        )
        let n=width*height*3
        guard bytes.count == n*8 else {
            throw Failure.invalid(
                "Original Python \(name)/\(stage) not Float64 RGB"
            )
        }
        return bytes.withUnsafeBytes { raw in
            (0..<n).map { k in
                let u=raw.loadUnaligned(
                    fromByteOffset:k*8,as:UInt64.self
                )
                return Double(bitPattern:UInt64(littleEndian:u))
            }
        }
    }

    private struct Metrics {
        let mae: Double
        let rmse: Double
        let maximum: Double
        let worst: Int
        let over: Int
    }
    private static func compare(
        observed: [Double], expected: [Double],
        maxTolerance: Double, maeTolerance: Double, label: String
    ) throws -> Metrics {
        guard observed.count == expected.count,
              !expected.isEmpty else {
            throw Failure.invalid(label + ": pixel buffer length differs")
        }
        var error=0.0, squared=0.0, maximum=0.0
        var worst=0,over=0
        for i in expected.indices {
            guard observed[i].isFinite && expected[i].isFinite else {
                throw Failure.invalid(label + ": NaN/Inf at \(i)")
            }
            let d=abs(observed[i]-expected[i])
            error+=d;squared+=d*d
            if d>maximum { maximum=d;worst=i }
            if d>maxTolerance {over+=1}
        }
        let n=Double(expected.count)
        let metrics=Metrics(
            mae:error/n,rmse:sqrt(squared/n),
            maximum:maximum,worst:worst,over:over
        )
        print(
            "\(label) n=\(expected.count) MAE=\(metrics.mae) " +
            "RMSE=\(metrics.rmse) max=\(metrics.maximum) " +
            "worstPixel=\(worst/3) channel=\(worst%3) over=\(over)"
        )
        guard over==0,metrics.mae <= maeTolerance else {
            throw Failure.invalid(
                "FAIL original nonlinear Python entire image \(label): " +
                "MAE=\(metrics.mae) RMSE=\(metrics.rmse) " +
                "max=\(metrics.maximum) pixel=\(worst/3) ch=\(worst%3). " +
                "Do not promote source image precision."
            )
        }
        return metrics
    }

    static func evaluate(fixtures: URL) throws {
        let doc=try Data(
            contentsOf:fixtures.appendingPathComponent("manifest.json")
        )
        let manifest=try JSONDecoder().decode(Manifest.self,from:doc)
        guard manifest.scope ==
              "original-source-nonlinear-hanatos-spatial-dir-paper-aces-8bit",
              manifest.cases.count==3 else {
            throw Failure.invalid("Wrong Python original physical fixture scope")
        }
        var total=0
        for fixture in manifest.cases {
            guard fixture.width>0 && fixture.height>0,
                  fixture.width<=8192,fixture.height<=8192,
                  fixture.width<=OriginalSourcePhysicalImage.maximumPixels /
                      fixture.height,
                  fixture.shift.count==3,
                  let pngSHA=fixture.sha256["png"] else {
                throw Failure.invalid("Invalid source Python image manifest")
            }
            let png=try read(
                fixtures.appendingPathComponent(fixture.name+".png"),
                sha:pngSHA
            )
            let frame=try OriginalSourcePixelIO.decode(
                png,
                maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
            )
            guard frame.width==fixture.width,
                  frame.height==fixture.height else {
                throw Failure.invalid(
                    "ImageIO source orientation mismatch " + fixture.name
                )
            }
            var print=OriginalPrintOptics.Settings(enabled:true)
            print.normalizePrintExposure=false
            print.printExposureCompensation=false
            print.cyanShift=fixture.shift[0]
            print.magentaShift=fixture.shift[1]
            print.yellowShift=fixture.shift[2]
            print.preflashExposure=fixture.flash
            print.preflashMagentaShift=fixture.flashM
            print.preflashYellowShift=fixture.flashY
            var morph=OriginalPrintMorph.Settings()
            switch fixture.morph {
            case "neutral": break
            case "gamma_082": morph.gamma=0.82
            case "exhaustion_04": morph.developerExhaustion=0.4
            default:throw Failure.invalid("Unknown source paper curve morph")
            }
            var dir=SpatialDIRSettings(enabled:true)
            dir.diffusionRadiusScale=1.0
            dir.tailWeight=0.06
            dir.referencePixelSizeUM=fixture.pixelUM
            dir.sourceConvolutionEnabled=true
            let params=OriginalSourcePhysicalImage.Parameters(
                filmID:fixture.film,paperID:fixture.paper,
                cameraEV:fixture.cameraEV,paperEV:fixture.paperEV,
                dir:dir,print:print,morph:morph
            )
            var traces=[String:[Double]]()
            let actual=try OriginalSourcePhysicalImage.develop(
                frame,parameters:params,
                stageDoubleObserver: { stage,pixels in
                    traces[stage]=pixels
                }
            )
            for stage in stages {
                guard let expectedSHA=fixture.sha256[stage],
                      let observed=traces[stage] else {
                    throw Failure.invalid(
                        "Missing Python or production stage " +
                        fixture.name + " " + stage
                    )
                }
                let originalData=try original(
                    fixtures:fixtures,name:fixture.name,stage:stage,
                    checksum:expectedSHA,width:fixture.width,
                    height:fixture.height
                )
                let outputTolerance:Double=stage=="printed" ? 0.002 : 0.002
                let meanTolerance:Double=stage=="printed" ? 0.0005 : 0.0003
                _ = try compare(
                    observed:observed,expected:originalData,
                    maxTolerance:outputTolerance,
                    maeTolerance:meanTolerance,
                    label:fixture.name + "/" + stage
                )
                if stage=="printed" {
                    guard actual.rgb == observed else {
                        throw Failure.invalid(
                            "Diagnostic output differs from production pixel output"
                        )
                    }
                }
            }
            total+=fixture.width*fixture.height*3
            print("PASS original nonlinear whole-frame stock " +
                  fixture.film + " → " + fixture.paper)
        }
        // Explicit memory guard: cannot silently scale the image, nor
        // downgrade to a Float32 optical 3D LUT when original is requested.
        let tooLarge=OriginalSourcePixelIO.Frame(
            width:2048,height:1024,rgb:[]
        )
        var rejected=false
        do {
            let fixture=manifest.cases[0]
            var dir=SpatialDIRSettings(enabled:true)
            dir.sourceConvolutionEnabled=true
            let p=OriginalSourcePhysicalImage.Parameters(
                filmID:fixture.film,paperID:fixture.paper,
                cameraEV:0,paperEV:0,dir:dir,
                print:OriginalPrintOptics.Settings(enabled:true),
                morph:OriginalPrintMorph.Settings()
            )
            _ = try OriginalSourcePhysicalImage.develop(
                tooLarge,parameters:p
            )
        } catch OriginalSourcePhysicalImage.Failure.invalid(let message) {
            rejected=message.contains("200 万像素")
        }
        guard rejected else {
            throw Failure.invalid("Oversize physical image failed to reject")
        }
        print("PASS: original Python nonlinear full image → Swift " +
              "Hanatos/H-D/spatial DIR/s023 paper/scan: " +
              "\(total) RGB channels across seven stages for 3 frames." +
              " 2MP strict memory limit. NOT grain/RAW/CAM16/whole-device certification.")
    }
}
