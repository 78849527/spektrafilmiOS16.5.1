import Foundation

/// CPU-only source-precision gate (also runs on iOS16). This intentionally
/// has no fallback to hash RNG and requires exact Float64 bit equality.
@main
struct OriginalSourceMT19937Validation {
    static func main() throws {
        print(try OriginalSourceMT19937.validateReference())
        print("PASS: original NumPy MT19937 uniform generator core matches")
        print("NOT CERTIFIED: SciPy sampler sequencing and Numba RNG not ported")
    }
}
