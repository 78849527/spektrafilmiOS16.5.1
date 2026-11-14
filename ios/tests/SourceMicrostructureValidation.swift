import Foundation

/// Source-pinned Numba analytical lognormal transform tests. The injected
/// standard normals make this deterministic, but they are NOT Numba's
/// unseeded parallel random stream.
@main
struct SourceMicrostructureValidation {
    static func main() throws {
        print(try OriginalSourceMicrostructure.validateSourceMath())
        for pixel in [9.0,0.6,0.4,0.2] {
            let params = try OriginalSourceMicrostructure.physical(
                pixelUM: pixel
            )
            print("PASS: microstructure pixelUM=\(pixel) sigma=\(params.microStd) blur=\(params.blur) active=\(params.enabled)")
        }
        // Source grain.py takes micro_structure=(blur_um, strength_nm).
        // Defaults cannot stand in for caller-supplied emulsion settings.
        for fixture in GeneratedSourceMicrostructureReference.parameterCases {
            let got = try OriginalSourceMicrostructure.physical(
                pixelUM: fixture.pixelUM,
                microBlurUM: fixture.microBlurUM,
                microStructureNM: fixture.microStructureNM
            )
            guard abs(got.microStd - fixture.microStd) < 1e-14,
                  abs(got.blur - fixture.blur) < 1e-14,
                  got.enabled == fixture.enabled else {
                throw NSError(
                    domain: "OriginalSourceMicrostructure",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "μm/nm source parameter mismatch at pixelUM=\\(fixture.pixelUM)"]
                )
            }
        }
        print("PASS: 7 non-default/default source microstructure parameter and activation cases")
        for bad in [
            (Double.nan, 0.2, 30.0),
            (1.0, Double.nan, 30.0),
            (1.0, -0.2, 30.0),
            (1.0, 0.2, -30.0),
        ] {
            do {
                _ = try OriginalSourceMicrostructure.physical(
                    pixelUM: bad.0, microBlurUM: bad.1,
                    microStructureNM: bad.2
                )
                throw NSError(domain: "OriginalSourceMicrostructure",
                              code: 2, userInfo: [
                                NSLocalizedDescriptionKey:
                                "Invalid source μm/nm accepted"])
            } catch OriginalSourceMicrostructure.Failure.invalid {
                // Explicit failure; source mode must never silently fallback.
            }
        }
        print("PASS: nonfinite/negative source parameters fail closed")
        print("NOT CERTIFIED: independent Numba prange RNG bitstream and Float64→Metal end-to-end RGB")
    }
}
