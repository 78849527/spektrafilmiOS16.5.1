import Foundation

/// Build80/10. Source-only CPU Double port of Python RAW chromatic adaptation:
/// raw_file_processor._whitepoint_xyz_from_temperature and
/// _apply_white_balance_adaptation. Math is in linear ACES2065-1 (AP0).
///
/// The original source: colour-science 0.4.6, CIE D/Kang 2002
/// chromaticity, XYZ -> CAT02 Von Kries -> XYZ, then float32 conversion.
/// Not connected to Apple's linear-sRGB RAW probe: Apple is NOT rawpy ACES.
enum Build80OriginalRAWWhiteBalance {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message)=self { return message }
            return nil
        }
    }

    typealias Matrix = [[Double]]

    // colour-science v0.4.6, ACES2065-1 AP0 matrices (Academy standard).
    private static let rgbToXYZ: Matrix = [
        [0.9525523959, 0.0, 0.0000936786],
        [0.3439664498, 0.7281660966, -0.0721325464],
        [0.0, 0.0, 1.0088251844]
    ]
    private static let xyzToRGB: Matrix = [
        [1.0498110175, 0.0, -0.0000974845],
        [-0.4959030231, 1.3733130458, 0.0982400361],
        [0.0, 0.0, 0.9912520182]
    ]

    // colour.adaptation.chromatic_adaptation method="Von Kries" uses
    // colour.adaptation.CAT_CAT02 by default, *not* CAT_BRADFORD.
    private static let cat02: Matrix = [
        [0.7328, 0.4296, -0.1624],
        [-0.7036, 1.6975, 0.0061],
        [0.0030, 0.0136, 0.9834]
    ]

    private static func multiply(_ a: Matrix, _ b: Matrix) -> Matrix {
        (0..<3).map { i in (0..<3).map { j in
            (0..<3).reduce(0.0) { $0 + a[i][$1] * b[$1][j] }
        } }
    }
    private static func multiply(_ m: Matrix, _ v: [Double]) -> [Double] {
        (0..<3).map { i in
            m[i][0]*v[0] + m[i][1]*v[1] + m[i][2]*v[2]
        }
    }

    private static func inverse(_ m: Matrix) throws -> Matrix {
        let a=m[0][0], b=m[0][1], c=m[0][2]
        let d=m[1][0], e=m[1][1], f=m[1][2]
        let g=m[2][0], h=m[2][1], i=m[2][2]
        let A=e*i-f*h, B=c*h-b*i, C=b*f-c*e
        let D=f*g-d*i, E=a*i-c*g, F=c*d-a*f
        let G=d*h-e*g, H=b*g-a*h, I=a*e-b*d
        let determinant=a*A+b*D+c*G
        guard determinant.isFinite, abs(determinant)>1e-15 else {
            throw Failure.invalid("CAT02 adaptation matrix singular")
        }
        return [
            [A,B,C].map { $0/determinant },
            [D,E,F].map { $0/determinant },
            [G,H,I].map { $0/determinant }
        ]
    }

    /// Compute original Python xy -> XYZ, Y=1; T>=4000 is CIE Illuminant D.
    /// T<4000 is Kang2002 Planckian. No rounding or sRGB conversion.
    static func whitepointXYZ(kelvin t: Double) throws -> [Double] {
        guard t.isFinite, t>0 else {
            throw Failure.invalid("RAW color temperature must be finite and positive")
        }
        let t2=t*t, t3=t2*t
        let x:Double
        let y:Double
        if t>=4000 {
            if t<=7000 {
                x=(-4.607*1e9)/t3+(2.9678*1e6)/t2+(0.09911*1e3)/t+0.244063
            } else {
                x=(-2.0064*1e9)/t3+(1.9018*1e6)/t2+(0.24748*1e3)/t+0.23704
            }
            y=-3.000*x*x+2.870*x-0.275
        } else {
            x=(-0.2661239*1e9)/t3-(0.2343589*1e6)/t2+
                (0.8776956*1e3)/t+0.179910
            if t<=2222 {
                y=-1.1063814*x*x*x-1.34811020*x*x+
                    2.18555832*x-0.20219683
            } else {
                y=-0.9549476*x*x*x-1.37418593*x*x+
                    2.09137015*x-0.16748867
            }
        }
        guard y.isFinite, abs(y)>1e-15 else {
            throw Failure.invalid("RAW whitepoint xy/XYZ is nonfinite")
        }
        let white=[x/y,1.0,(1.0-x-y)/y]
        guard white.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("RAW whitepoint XYZ is nonfinite")
        }
        return white
    }

    /// Original Python _apply_white_balance_adaptation(rgb, sourceXYZ,
    /// targetXYZ). CAT02 and ACES/AP0 are used even for negative/superwhite
    /// finite channels; only the final result is narrowed to np.float32.
    static func adapt(_ rgb: [Float], sourceWhiteXYZ: [Double],
                      targetWhiteXYZ: [Double]) throws -> [Float] {
        guard rgb.count.isMultiple(of:3),
              sourceWhiteXYZ.count==3,targetWhiteXYZ.count==3,
              sourceWhiteXYZ.allSatisfy({$0.isFinite}),
              targetWhiteXYZ.allSatisfy({$0.isFinite}),
              sourceWhiteXYZ[1] != 0, targetWhiteXYZ[1] != 0 else {
            throw Failure.invalid("Invalid ACES RGB or source/target whitepoint")
        }
        let source=sourceWhiteXYZ.map {$0/sourceWhiteXYZ[1]}
        let target=targetWhiteXYZ.map {$0/targetWhiteXYZ[1]}
        let from=multiply(cat02,source), to=multiply(cat02,target)
        guard (0..<3).allSatisfy({from[$0].isFinite &&
                                abs(from[$0])>1e-15 && to[$0].isFinite}) else {
            throw Failure.invalid("CAT02 LMS source/target nonfinite or zero")
        }
        let diagonal:Matrix=[
            [to[0]/from[0],0,0],
            [0,to[1]/from[1],0],
            [0,0,to[2]/from[2]]
        ]
        let xyzAdapt=try multiply(multiply(inverse(cat02),diagonal),cat02)
        let linearRGBMatrix=multiply(multiply(xyzToRGB,xyzAdapt),rgbToXYZ)
        var output=[Float]()
        output.reserveCapacity(rgb.count)
        for k in stride(from:0,to:rgb.count,by:3) {
            let v=[Double(rgb[k]), Double(rgb[k+1]), Double(rgb[k+2])]
            let adapted=multiply(linearRGBMatrix,v)
            output.append(contentsOf:adapted.map {Float($0)})
        }
        return output
    }

    /// Original Python source adapts from the chosen source white to
    /// 6504K daylight reference. A real rawpy ACES image is required.
    static func adaptFromTemperature(
        _ rgb: [Float], kelvin: Double, referenceKelvin: Double=6504
    ) throws -> [Float] {
        try adapt(rgb,sourceWhiteXYZ:whitepointXYZ(kelvin:kelvin),
                  targetWhiteXYZ:whitepointXYZ(kelvin:referenceKelvin))
    }
}
