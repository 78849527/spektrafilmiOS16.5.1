import Foundation

@main
struct CAM16GamutValidation {
    static func validatePair(_ rgb: [Double], _ expected: [Double],
                             index: Int) {
        let native=OriginalCAM16Gamut.compress(rgb)
        precondition(native.count==3 && native.allSatisfy({ $0.isFinite }))
        let errors=zip(native,expected).map { abs($0-$1) }
        let worst=errors.max() ?? 0
        // 33^3 table with trilinear reconstruction is an approximation:
        // exact source nodes have float32 error; intermediate colors
        // checked against a toleranced original-Python reference.
        let aligned=rgb.allSatisfy { v in
            let x=(v-OriginalCAM16Gamut.minimum) /
                  (OriginalCAM16Gamut.maximum-OriginalCAM16Gamut.minimum) *
                  Double(OriginalCAM16Gamut.dimension-1)
            return abs(x-x.rounded()) < 1e-7
        }
        let tolerance=aligned ? 0.00015 : 0.065
        precondition(worst < tolerance,
                     "Source CAM16 gamut index \(index) mismatch \(native) != \(expected) worst=\(worst)")
    }

    static func main() {
        setbuf(stdout,nil)
        precondition(OriginalCAM16Gamut.dimension==33)
        precondition(OriginalCAM16Gamut.invalidSourceNodes < 33*33*33/4)

        let probes:[([Double],[Double])]=[
            (GeneratedCAM16Gamut.input0,GeneratedCAM16Gamut.output0),
            (GeneratedCAM16Gamut.input1,GeneratedCAM16Gamut.output1),
            (GeneratedCAM16Gamut.input2,GeneratedCAM16Gamut.output2),
            (GeneratedCAM16Gamut.input3,GeneratedCAM16Gamut.output3),
            (GeneratedCAM16Gamut.input4,GeneratedCAM16Gamut.output4),
            (GeneratedCAM16Gamut.input5,GeneratedCAM16Gamut.output5),
            (GeneratedCAM16Gamut.input6,GeneratedCAM16Gamut.output6),
            (GeneratedCAM16Gamut.input7,GeneratedCAM16Gamut.output7),
            (GeneratedCAM16Gamut.input8,GeneratedCAM16Gamut.output8),
            (GeneratedCAM16Gamut.input9,GeneratedCAM16Gamut.output9),
            (GeneratedCAM16Gamut.input10,GeneratedCAM16Gamut.output10),
            (GeneratedCAM16Gamut.input11,GeneratedCAM16Gamut.output11),
            (GeneratedCAM16Gamut.input12,GeneratedCAM16Gamut.output12),
            (GeneratedCAM16Gamut.input13,GeneratedCAM16Gamut.output13),
            (GeneratedCAM16Gamut.input14,GeneratedCAM16Gamut.output14)
        ]
        for (i,item) in probes.enumerated() {
            validatePair(item.0,item.1,index:i)
        }
        print("PASS: 15 CAM16 source default original Python reference inputs incl. grid nodes/off-grid samples.")

        let black=OriginalCAM16Gamut.compress([0,0,0])
        let white=OriginalCAM16Gamut.compress([1,1,1])
        precondition(black.allSatisfy({ abs($0)<0.02 }),
                     "CAM16 gamut must anchor near-black")
        precondition(white.allSatisfy({ $0>0.9 && $0<=1.04 }),
                     "CAM16 gamut must maintain neutral display white")
        let fallback=OriginalCAM16Gamut.compress([3.0,-0.2,0.5])
        let alternative=OriginalScannerMath.compressACESRGC([3.0,-0.2,0.5])
        for i in 0..<3 {
            precondition(abs(fallback[i]-alternative[i]) < 1e-12,
                         "Out-of-table fallback should be source ACES")
        }
        print("PASS: CAM16 table neutral endpoints and out-of-range ACES fallback.")
    }
}
