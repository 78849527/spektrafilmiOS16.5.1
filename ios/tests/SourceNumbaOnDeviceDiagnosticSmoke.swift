import Foundation

/// Run the *actual same* diagnostic evaluate() used from the iPhone's
/// eight-item Metal hardware report, not a duplicate test implementation.
/// CPU source parity only. No physical iPhone or production GPU assertion.
@main
struct SourceNumbaOnDeviceDiagnosticSmoke {
    static func main() throws {
        let first = try OriginalSourceNumbaFastCountsDiagnostic.evaluate()
        let second = try OriginalSourceNumbaFastCountsDiagnostic.evaluate()
        guard first == second else {
            throw NSError(domain: "SourceNumbaOnDeviceDiagnosticSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                          "Original source diagnostic repeated runs disagree"])
        }
        for text in [
            "Numba 0.64",
            "NumPy 2.4",
            "0、8888、123456",
            "180 Poisson + 360 Binomial",
            "Float64 位级一致",
            "尚未认证",
            "生产 Metal",
            "真实 iPhone",
        ] {
            guard first.contains(text) else {
                throw NSError(domain: "SourceNumbaOnDeviceDiagnosticSmoke",
                              code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                              "Original diagnostic report missing: \(text)"])
            }
        }
        guard !first.contains("8/8 项全部通过") else {
            throw NSError(domain: "SourceNumbaOnDeviceDiagnosticSmoke",
                          code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                          "Diagnostic appendix incorrectly claims complete Metal parity"])
        }
        var invalid = OriginalSourceNumbaFastCounts(seed: 8888)
        do {
            _ = try invalid.fastPoisson(.nan)
            throw NSError(domain: "SourceNumbaOnDeviceDiagnosticSmoke",
                          code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                          "Non-finite source Poisson parameter not rejected"])
        } catch OriginalSourceNumbaFastCounts.Failure.invalid {}
        do {
            _ = try invalid.fastBinomial(-1, probability: 0.5)
            throw NSError(domain: "SourceNumbaOnDeviceDiagnosticSmoke",
                          code: 5,
                          userInfo: [NSLocalizedDescriptionKey:
                          "Negative source Binomial count not rejected"])
        } catch OriginalSourceNumbaFastCounts.Failure.invalid {}
        do {
            _ = try invalid.runOriginalTwoPhase(
                rates: [1.0], probabilities: []
            )
            throw NSError(domain: "SourceNumbaOnDeviceDiagnosticSmoke",
                          code: 6,
                          userInfo: [NSLocalizedDescriptionKey:
                          "Shape mismatch failed to stop original source mode"])
        } catch OriginalSourceNumbaFastCounts.Failure.invalid {}
        print("PASS: production iPhone report function evaluate() invoked twice with repeatable source counts")
        print("PASS: 180 original Poisson / 360 original Binomial, 3 seeds, bit-exact RNG")
        print("PASS: source limitations displayed; invalid parameters fail closed")
        print("NOT CERTIFIED: real iPhone UI, Numba unseeded prange workers or whole-image Metal/Float64 RGB")
    }
}
