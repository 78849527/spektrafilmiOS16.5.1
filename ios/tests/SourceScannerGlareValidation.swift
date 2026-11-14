import Foundation

/// Actual Python source glare.py stage vs actual native Swift source port.
/// This is a controlled-seed one-worker diagnostic, not an original
/// unseeded multiworker production scanner certification.
@main
struct SourceScannerGlareValidation {
    static func main() throws {
        let fixtures = GeneratedSourceScannerGlareReference.cases
        guard fixtures.count == 6,
              GeneratedSourceScannerGlareReference.glareBlob ==
                  "e8610f13430d45be749ae31a5284eef2c2b7a362",
              GeneratedSourceScannerGlareReference.statsBlob ==
                  "9e80d29ce6b9f7820ae70f5c09da15edfaa70a0d",
              GeneratedSourceScannerGlareReference.filterBlob ==
                  "8918c673ea0fb3f5d9ae820ca85bf6db4aba457a"
        else { fatalError("Original source glare/fast_stats/filter identity changed") }

        var totalAmount = 0, totalXYZ = 0
        var maxAmountError = 0.0, maxXYZError = 0.0
        for fixture in fixtures {
            let pixels = fixture.width * fixture.height
            guard pixels == fixture.sourceNormals.count,
                  pixels == fixture.amounts.count,
                  fixture.inputXYZ.count == pixels * 3,
                  fixture.outputXYZ.count == pixels * 3 else {
                fatalError("Original source glare reference dimensions invalid")
            }
            let settings = OriginalSourceScannerGlare.Settings(
                active: fixture.enabled, percent: fixture.percent,
                roughness: fixture.roughness, blur: fixture.blur
            )
            let expected = fixture.amounts
            let seeded = try OriginalSourceScannerGlare.computeAmount(
                width: fixture.width, height: fixture.height,
                settings: settings, controlledSeed: fixture.seed
            )
            let injected: [Double]
            if fixture.enabled && fixture.percent > 0 {
                injected = try OriginalSourceScannerGlare.computeAmount(
                    width: fixture.width, height: fixture.height,
                    settings: settings, sourceNormals: fixture.sourceNormals
                )
            } else {
                injected = seeded
            }
            for i in 0..<pixels {
                let err = abs(seeded[i] - expected[i])
                let injectErr = abs(injected[i] - expected[i])
                maxAmountError = max(maxAmountError, max(err, injectErr))
                // Direct original Float64 filter/Numba exp, not
                // distributional similarity or a visual threshold.
                guard err <= 1e-11 * (1 + abs(expected[i])),
                      injectErr <= 1e-11 * (1 + abs(expected[i])) else {
                    fatalError(
                        "Original glare field mismatch seed=\(fixture.seed) " +
                        "sigma=\(fixture.blur) idx=\(i) " +
                        "src=\(expected[i]) Swift=\(seeded[i]) injected=\(injected[i])"
                    )
                }
            }

            let xyz = try OriginalSourceScannerGlare.addToXYZ(
                fixture.inputXYZ, illuminantXYZ: fixture.illuminantXYZ,
                width: fixture.width, height: fixture.height,
                settings: settings, controlledSeed: fixture.seed
            )
            for i in xyz.indices {
                let err = abs(xyz[i] - fixture.outputXYZ[i])
                maxXYZError = max(maxXYZError, err)
                guard err <= 1e-11 * (1 + abs(fixture.outputXYZ[i])) else {
                    fatalError(
                        "Source XYZ add_glare mismatch seed=\(fixture.seed) " +
                        "sigma=\(fixture.blur) chIndex=\(i) " +
                        "src=\(fixture.outputXYZ[i]) Swift=\(xyz[i])"
                    )
                }
            }
            totalAmount += pixels
            totalXYZ += xyz.count
            print(
                "PASS: original glare.py seed=\(fixture.seed) " +
                "\(fixture.width)x\(fixture.height) sigma=\(fixture.blur) " +
                "enabled=\(fixture.enabled), random field + XYZ matched"
            )
        }

        // Strict fail closed: a nonzero, active source model needs a
        // controlled source stream. It must never switch to hash noise.
        do {
            _ = try OriginalSourceScannerGlare.computeAmount(
                width: 3, height: 3,
                settings: OriginalSourceScannerGlare.Settings()
            )
            fatalError("Missing Numba source RNG was silently accepted")
        } catch OriginalSourceScannerGlare.Failure.invalid {}
        do {
            _ = try OriginalSourceScannerGlare.computeAmount(
                width: 3, height: 3,
                settings: OriginalSourceScannerGlare.Settings(blur: -1),
                controlledSeed: 8888
            )
            fatalError("Negative blur was silently accepted")
        } catch OriginalSourceScannerGlare.Failure.invalid {}
        do {
            _ = try OriginalSourceScannerGlare.addToXYZ(
                [0.1, 0.2, 0.3], illuminantXYZ: [1, 1],
                width: 1, height: 1,
                settings: OriginalSourceScannerGlare.Settings(),
                controlledSeed: 8888
            )
            fatalError("Invalid XYZ illuminant was silently accepted")
        } catch OriginalSourceScannerGlare.Failure.invalid {}

        print(
            "PASS: \(fixtures.count) true source scanner glare frames, " +
            "\(totalAmount) Float64 random/scalar field samples, " +
            "\(totalXYZ) Float64 XYZ channels. maxAmount=\(maxAmountError), " +
            "maxXYZ=\(maxXYZError)"
        )
        // Exercise the same method the iPhone Metal diagnostic report calls.
        let liveAppendix = try OriginalSourceScannerGlareDiagnostic.evaluate()
        guard liveAppendix.contains("141 个眩光 Float64 值"),
              liveAppendix.contains("423 个 XYZ 通道"),
              liveAppendix.contains("未接入完整生产扫描 XYZ") else {
            fatalError("On-device source glare diagnostic did not preserve limits")
        }
        print("PASS: actual on-device glare diagnostic evaluate() uses source Float64 fixtures")
        print(
            "NOT CERTIFIED: Python Numba unseeded multiworker RNG, " +
            "full production scanner XYZ integration, complete RGB, " +
            "real iPhone image parity."
        )
    }
}
