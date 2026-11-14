import Foundation

// Standalone macOS/iOS Swift 5.9 numeric probe for the *production*
// camera UV/IR filter. CI checks every source wavelength and 4 cases
// against scipy.special.erf in upstream Python.
@main
struct SourceCameraBandpassNumericValidation {
    static func main() throws {
        let settings: [OriginalSourceCameraBandpass.Settings] = [
            .init(),
            .init(uv:.init(amount:1,centerNM:410,widthNM:8),
                  ir:.init(amount:0,centerNM:675,widthNM:15)),
            .init(uv:.init(amount:0,centerNM:410,widthNM:8),
                  ir:.init(amount:1,centerNM:675,widthNM:15)),
            .init(uv:.init(amount:0.75,centerNM:420,widthNM:12),
                  ir:.init(amount:0.4,centerNM:680,widthNM:17)),
        ]
        for (index, value) in settings.enumerated() {
            try value.validate()
            for wl in stride(from:380,through:780,by:5) {
                let actual=OriginalSourceCameraBandpass.transmission(
                    wavelengthNM:Double(wl),settings:value
                )
                guard actual.isFinite,actual>=0,actual<=1 else {
                    fatalError("Invalid source bandpass at \(wl) nm")
                }
                print("\(index),\(wl),\(String(format:"%.17g",actual))")
            }
        }
    }
}
