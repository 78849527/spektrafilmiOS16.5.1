import Foundation
@main
enum FinalSourceRawPreservationValidation {
    static func main() throws {
        try Build79RAWSignatureValidation.evaluate()
        print("PASS RAW signature and SHA256 preservation; camera demosaic/rawpy/iPhone16.5.1 NOT certified")
    }
}
