import Foundation

/// Cross-language evidence for original single-thread Numba normal samples.
/// Uses the actual unmodified upstream fast_stats.py result as the expected
/// lognormal field (not a synthetic Swift-only reference).
@main
struct SourceNumbaSingleThreadValidation {
    static func main() throws {
        let cases = GeneratedSourceNumbaSingleThreadReference.cases
        guard cases.count == 3 else {
            fatalError("Source Numba one-thread fixture count missing")
        }
        var total = 0
        var maxNormalError = 0.0
        var maxLognormalError = 0.0
        for fixture in cases {
            guard fixture.std.count == 64,
                  fixture.normal.count == fixture.std.count,
                  fixture.lognormal.count == fixture.std.count else {
                fatalError("Source Numba fixture shape mismatch")
            }
            var generator = OriginalSourceNumbaSingleThreadNormal(
                seed: fixture.seed
            )
            for i in fixture.std.indices {
                let actualNormal = try generator.nextNormal()
                let expectedNormal = fixture.normal[i]
                let normalError = abs(actualNormal - expectedNormal)
                guard normalError <= 2e-14 * (1 + abs(expectedNormal))
                else {
                    fatalError(
                        "Numba one-thread normal mismatch seed=\(fixture.seed), idx=\(i), " +
                        "source=\(expectedNormal), Swift=\(actualNormal)"
                    )
                }
                let actualLognormal = try OriginalSourceMicrostructure.lognormal(
                    microStd: fixture.std[i], z: actualNormal
                )
                let expectedLognormal = fixture.lognormal[i]
                let lognormalError = abs(actualLognormal - expectedLognormal)
                guard lognormalError <= 1e-12 * (1 + abs(expectedLognormal))
                else {
                    fatalError(
                        "Numba one-thread lognormal mismatch seed=\(fixture.seed), idx=\(i), " +
                        "source=\(expectedLognormal), Swift=\(actualLognormal)"
                    )
                }
                maxNormalError = max(maxNormalError, normalError)
                maxLognormalError = max(maxLognormalError, lognormalError)
                total += 1
            }
            print("PASS: upstream single-thread Numba seed=\(fixture.seed), " +
                  "64 normal samples and source lognormal outputs")
        }
        print("PASS: \(total) original seeded single-thread Numba / " +
              "Swift MT19937 Gaussian samples; max normal error=\(maxNormalError), " +
              "max lognormal error=\(maxLognormalError)")
        print("NOT CERTIFIED: parallel Numba worker scheduling, unseeded " +
              "production stream, real iPhone GPU, full-frame RGB.")
    }
}
