import Foundation

@main
struct ScannerMathValidation {
    static func near(_ actual: [Double], _ expected: [Double],
                     tolerance: Double = 5e-7, name: String) {
        precondition(actual.count == 3 && expected.count == 3)
        for i in 0..<3 {
            precondition(actual[i].isFinite)
            let error=abs(actual[i]-expected[i])
            precondition(error < tolerance,
                         "\(name) channel \(i): \(actual[i]) vs \(expected[i])")
        }
    }

    static func main() {
        let matrices: [(String,[Double],[Double])] = [
            (GeneratedScannerReference.xyzStock0,
             GeneratedScannerReference.xyzInput0,
             GeneratedScannerReference.xyzRGB0),
            (GeneratedScannerReference.xyzStock1,
             GeneratedScannerReference.xyzInput1,
             GeneratedScannerReference.xyzRGB1),
            (GeneratedScannerReference.xyzStock2,
             GeneratedScannerReference.xyzInput2,
             GeneratedScannerReference.xyzRGB2),
            (GeneratedScannerReference.xyzStock3,
             GeneratedScannerReference.xyzInput3,
             GeneratedScannerReference.xyzRGB3)
        ]
        for (stock,xyz,rgb) in matrices {
            near(OriginalScannerMath.linearSRGB(xyz: xyz,viewing: stock),
                 rgb, tolerance: 1e-9, name: stock)
        }
        print("PASS: upstream colour-science XYZ_to_RGB view adaptation 4 D50/K75P reference samples.")

        let acesSamples: [([Double],[Double])] = [
            (GeneratedScannerReference.gamutInput0,
             GeneratedScannerReference.gamutExpected0),
            (GeneratedScannerReference.gamutInput1,
             GeneratedScannerReference.gamutExpected1),
            (GeneratedScannerReference.gamutInput2,
             GeneratedScannerReference.gamutExpected2),
            (GeneratedScannerReference.gamutInput3,
             GeneratedScannerReference.gamutExpected3),
            (GeneratedScannerReference.gamutInput4,
             GeneratedScannerReference.gamutExpected4),
            (GeneratedScannerReference.gamutInput5,
             GeneratedScannerReference.gamutExpected5),
            (GeneratedScannerReference.gamutInput6,
             GeneratedScannerReference.gamutExpected6),
            (GeneratedScannerReference.gamutInput7,
             GeneratedScannerReference.gamutExpected7)
        ]
        for (i,sample) in acesSamples.enumerated() {
            near(OriginalScannerMath.compressACESRGC(sample.0),
                 sample.1,tolerance: 1e-12,name: "ACES \(i)")
        }
        print("PASS: 8 exact upstream Python ACES RGC v1.3 output gamut vectors.")

        let white=OriginalScannerMath.correctBlackWhiteXYZ(
            [0.8,0.7,0.3],yBlack: 0.1,yWhite: 0.7)
        let black=OriginalScannerMath.correctBlackWhiteXYZ(
            [0.12,0.1,0.08],yBlack: 0.1,yWhite: 0.7)
        precondition(abs(white[1]-OriginalScannerMath.decodeSRGB(0.98)) < 1e-9)
        precondition(abs(black[1]-OriginalScannerMath.decodeSRGB(0.01)) < 1e-9)
        precondition(white[0]/white[1] > 0.0)
        let noChange=OriginalScannerMath.correctBlackWhiteXYZ(
            [0.12,0.1,0.08],yBlack: 0.3,yWhite: 0.2)
        precondition(noChange == [0.12,0.1,0.08])
        print("PASS: source luminance black/white scaling with stable black and white endpoints.")
    }
}
