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
        print("NOT CERTIFIED: independent Numba prange RNG bitstream and Float64→Metal end-to-end RGB")
    }
}
