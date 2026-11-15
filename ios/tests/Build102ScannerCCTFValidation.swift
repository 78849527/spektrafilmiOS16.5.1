import Foundation

func assertTrue(_ value: @autoclosure () -> Bool,_ why:String) {
    if !value() { fatalError("Build102 scanner-CCTF regression: "+why) }
}
let matrix=GeneratedScannerReference.sourceLinearIdentityRGBMatrix
assertTrue(matrix.count==9,"Python original source colour RGB_to_RGB 3x3 missing")
let identity:[Double]=[1,0,0,0,1,0,0,0,1]
let offIdentity=zip(matrix,identity).map { abs($0.0-$0.1) }.max() ?? 0.0
assertTrue(offIdentity>1e-12,
           "Original colour-science same-space matrix unexpectedly identity; recheck source generator")
let vectors:[[Double]]=[
    [0.03,0.31,0.81], [0.73,0.002,0.14],
    [0.23,0.46,0.68], [-0.00021,0.04,1.32],
]
var maxOldScalarDifference=0.0
var maxCorrectDifference=0.0
for rgb in vectors {
    // Independent explicit original colour-science matrix calculation.
    let converted=(0..<3).map { output in
        (0..<3).reduce(0.0) { sum,input in
            sum + rgb[input]*matrix[input*3+output]
        }
    }
    let sourceExpected=converted.map(OriginalScannerMath.encodeSRGB)
    // This is the actual production CCTF which Build102's physical iPhone
    // parity diagnostic must now call as its expected value.
    let production=OriginalScannerMath.sourceCCTFEncoding(rgb)
    let formerlyIncorrect=rgb.map(OriginalScannerMath.encodeSRGB)
    for channel in 0..<3 {
        assertTrue(production[channel].isFinite,"finite source RGB output")
        let corrected=abs(sourceExpected[channel]-production[channel])
        let previous=abs(formerlyIncorrect[channel]-production[channel])
        maxCorrectDifference=max(maxCorrectDifference,corrected)
        maxOldScalarDifference=max(maxOldScalarDifference,previous)
        assertTrue(corrected<=2e-15,
                   "Three-channel colour.RGB_to_RGB must precede sRGB transfer")
    }
}
assertTrue(maxOldScalarDifference>1e-11,
           "Former single-channel encoding did not exhibit measured matrix mismatch")
print("PASS Build102 source 3x3+CCTF, corrected=\(maxCorrectDifference), priorScalarError=\(maxOldScalarDifference); NOT physical iPhone")
