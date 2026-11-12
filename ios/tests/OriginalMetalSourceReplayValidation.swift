import Foundation
import Metal

/// Executes production Metal FIR/YVV/composition on original seeded
/// SciPy particle textures; compares whole optical density vs upstream
/// grain.py Float64 reference. Not a test of SciPy/Numba PRNG equality.
@main
struct OriginalMetalSourceReplayValidation {
    static func main() throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else {
            fatalError("Pass compiled grain .metallib as first argument")
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Actual Metal GPU is required; cannot certify CPU fallback")
        }
        let library = try device.makeLibrary(
            URL: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        let details = try OriginalMetalSourceReplay.validate(
            device: device, queue: queue, library: library
        )
        print("PASS: original Python SciPy particle-field source replay on production Metal path")
        print(details)
        print("NOT CERTIFIED: original MT19937/SciPy and Numba RNG bitstream or full RGB still pending")
    }
}
