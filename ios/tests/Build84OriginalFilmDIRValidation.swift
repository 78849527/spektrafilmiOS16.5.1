import Foundation

/// Build84 independent oracle. Run with:
/// swiftc -O -parse-as-library Build84OriginalFilmDIR.swift
///   Build84OriginalFilmDIRValidation.swift -o /tmp/build84 &&
/// /tmp/build84 /tmp/build84-reference.json
@main
enum Build84OriginalFilmDIRValidation {
    enum TestError: Error {
        case invalid(String)
    }

    static func values(_ root: [String:Any], _ key: String) throws -> [Double] {
        guard let array = root[key] as? [NSNumber] else {
            throw TestError.invalid("Missing Python source reference: " + key)
        }
        return array.map { $0.doubleValue }
    }

    static func compare(
        _ name: String, _ actual: [Double], _ expected: [Double],
        tolerance: Double = 2e-12
    ) throws {
        guard actual.count == expected.count else {
            throw TestError.invalid("\(name) length mismatch")
        }
        var mae = 0.0
        var worst = 0.0
        for i in actual.indices {
            let delta = abs(actual[i] - expected[i])
            guard delta.isFinite else {
                throw TestError.invalid("\(name) contains NaN/Inf at \(i)")
            }
            worst = max(worst, delta)
            mae += delta
            guard delta <= tolerance else {
                throw TestError.invalid(
                    "\(name) #\(i) got \(actual[i]) expected \(expected[i]) Δ=\(delta)"
                )
            }
        }
        print("PASS \(name) n=\(actual.count) MAE=\(mae/Double(max(1,actual.count))) max=\(worst)")
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw TestError.invalid("Need genuine Python-source reference JSON")
        }
        let data = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard let root = try JSONSerialization.jsonObject(with:data)
                as? [String:Any] else {
            throw TestError.invalid("Invalid oracle JSON")
        }
        let axis = try values(root, "logAxis")
        let curves = try values(root, "densityCurves")
        let raw = try values(root, "raw")
        let gamma = try values(root, "gamma")
        let sourceMatrix = try values(root, "matrix")
        let matrix = try Build84OriginalFilmDIR.matrix()
        try compare("source DIR defaults 3x3 donor-receiver",matrix,sourceMatrix)
        try compare(
            "source H-D 3-channel gamma and endpoint interpolation",
            Build84OriginalFilmDIR.developDensity(
                logRaw:raw,logExposure:axis,
                densityCurves:curves,gammaRGB:gamma
            ),
            try values(root,"hd")
        )

        let maxima = (0..<3).map { ch in
            (0..<(curves.count/3)).reduce(-Double.infinity) {
                max($0,curves[$1*3+ch])
            }
        }
        let density = Array(curves[6..<9])
        for (positive,label) in [(false,"negative"),(true,"positive")] {
            try compare(
                "source pre-DIR H-D " + label,
                Build84OriginalFilmDIR.curvesBeforeDIR(
                    logExposure:axis,densityCurves:curves,
                    matrix:matrix,positive:positive
                ),
                try values(root,"beforeDIR_"+label)
            )
            try compare(
                "source nonspatial inhibitors " + label,
                Build84OriginalFilmDIR.inhibitors(
                    density:density,maximum:maxima,
                    matrix:matrix,positive:positive
                ),
                try values(root,"inhibitors_"+label)
            )
            try compare(
                "source high-exposure shift " + label,
                Build84OriginalFilmDIR.inhibitors(
                    density:density,maximum:maxima,
                    matrix:matrix,positive:positive,
                    highExposureShift:0.2
                ),
                try values(root,"inhibitors_"+label+"_highShift")
            )
        }

        // The source normalization is per-channel nanmin, not first-row
        // or a single global CMY minimum.
        let offset = [0.15,0.30,0.45]
        let shifted = curves.enumerated().map { i,v in v+offset[i%3] }
        try compare(
            "source per-channel density normalization",
            try Build84OriginalFilmDIR.normalize(shifted),
            try Build84OriginalFilmDIR.normalize(curves)
        )
        // Repeated knots are right-biased (source fast_interp).
        let repeated = try Build84OriginalFilmDIR.developDensity(
            logRaw:[0.0,0.0,0.0],
            logExposure:[-1,0,0,1],
            densityCurves:[0,0,0, 1,1,1, 2,2,2, 3,3,3]
        )
        try compare("right-biased repeated knots",repeated,[2,2,2])
        print("BUILD84 ORIGINAL FILM H-D / DIR: SOURCE NUMERIC ORACLE PASS")
    }
}
