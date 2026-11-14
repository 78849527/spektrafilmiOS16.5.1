import Foundation

/// Independent native caller of actual Swift Build77OriginalParameterDigest.
/// It emits computed results, never copies the oracle's expected values.
@main
struct Build77OriginalParameterDigestValidation {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw Build77OriginalParameterDigest.DigestError.invalid(
                "Usage: audit SOURCE_REFERENCE.json SWIFT_RESULTS.json"
            )
        }
        let numericProbe = try Build77ExactJSONValue.decodeObject(
            from: Data("{\"probe\":100.12236156288677}".utf8)
        )
        guard let decoded = numericProbe["probe"] as? Double,
              decoded.bitPattern == (100.12236156288677 as Double).bitPattern else {
            throw Build77OriginalParameterDigest.DigestError.invalid(
                "Original Python Float64 1-ULP decimal decoder regression"
            )
        }
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let raw = try Data(contentsOf: inputURL)
        let envelope = try Build77ExactJSONValue.decodeObject(from: raw)
        guard let cases = envelope["cases"] as? [[String: Any]],
              let neutral = envelope["neutral_database"] as? [String: Any],
              cases.count == 360 else {
            throw Build77OriginalParameterDigest.DigestError.invalid(
                "Original Python digest matrix missing or malformed"
            )
        }
        var observed: [[String: Any]] = []
        for entry in cases {
            guard let id = entry["id"] as? String,
                  let before = entry["before"] as? [String: Any],
                  let film = entry["film_info"] as? [String: Any],
                  let paper = entry["paper_info"] as? [String: Any],
                  let specifics = entry["apply_stock_specifics"] as? Bool else {
                throw Build77OriginalParameterDigest.DigestError.invalid(
                    "Original source fixture case metadata invalid"
                )
            }
            let after = try Build77OriginalParameterDigest.digest(
                before, filmInfo: film, paperInfo: paper,
                neutralDatabase: neutral, applyStockSpecifics: specifics
            )
            observed.append(["id": id, "actual": after])
        }
        let report: [String: Any] = [
            "status": "SWIFT_DIGEST_SUBTREE_NOT_IOS_RENDER_PIPELINE_PARITY",
            "observed": observed
        ]
        guard JSONSerialization.isValidJSONObject(report) else {
            throw Build77OriginalParameterDigest.DigestError.invalid(
                "Swift output not JSON-serializable"
            )
        }
        let bytes = try JSONSerialization.data(
            withJSONObject: report, options: [.sortedKeys]
        )
        try bytes.write(to: outputURL, options: .atomic)
        print("SWIFT PARAM DIGEST:", observed.count,
              "real source-derived cases emitted for independent Python audit")
    }
}
