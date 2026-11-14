import Foundation
import CryptoKit

/// Build77 data-plane audit: compare generated Swift records independently
/// against the pinned original Python JSON manifest. NOT a stage/RGB parity
/// certificate. Compile with only GeneratedSpectralData.swift on macOS.
@main
struct Build77MeasuredProfileAudit {
    struct Manifest: Decodable {
        let source_sha: String
        let profile_tree_sha: String
        let profiles: [ExpectedStock]
    }

    struct ExpectedStock: Decodable {
        let stock: String
        let stage: String
        let support: String
        let polarity: String
        let reference_illuminant: String
        let viewing_illuminant: String
        let json_sha256: String
        let source_payload_sha256: String
        let fields: [String: String]
        let masks: [String: String]
    }

    enum AuditError: Error, CustomStringConvertible {
        case failed(String)
        var description: String {
            switch self {
            case .failed(let reason): return reason
            }
        }
    }

    static func demand(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw AuditError.failed(detail) }
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func check(
        name: String, encoded: String, expected: String?,
        count: Int, stride: Int
    ) throws -> Data? {
        if expected == nil {
            try demand(encoded.isEmpty, "Unexpected iOS stock field " + name)
            return nil
        }
        guard let raw = Data(base64Encoded: encoded) else {
            throw AuditError.failed("Malformed base64 for " + name)
        }
        try demand(raw.count == count * stride,
                   "Invalid byte count in " + name)
        try demand(digest(raw) == expected, "SOURCE BYTE DRIFT: " + name)
        return raw
    }

    static func verify(_ expected: ExpectedStock,
                       _ record: GeneratedSpectralData.Record) throws {
        let label = expected.stock
        try demand(record.stage == expected.stage, label + ": stage changed")
        try demand(record.support == expected.support, label + ": media changed")
        try demand(record.polarity == expected.polarity, label + ": polarity changed")
        try demand(record.referenceIlluminant == expected.reference_illuminant,
                   label + ": reference illuminant changed")
        try demand(record.viewingIlluminant == expected.viewing_illuminant,
                   label + ": viewing illuminant changed")
        try demand(record.sourceSHA256 == expected.json_sha256,
                   label + ": source JSON identity changed")

        // Fixed layout follows source JSON field order. Do not allow a
        // generated f32 array to masquerade as the independent f64 field.
        let fields: [(String, String, Int, Int)] = [
            ("logSensitivity", record.logSensitivity, 243, 4),
            ("channelDensity", record.channelDensity, 243, 4),
            ("baseDensity", record.baseDensity, 81, 4),
            ("logExposure", record.logExposure, 256, 4),
            ("densityCurves", record.densityCurves, 768, 4),
            ("densityCurvesLayers", record.densityCurvesLayers, 2304, 4),
            ("sourceLogSensitivityF64", record.sourceLogSensitivityF64, 243, 8),
            ("sourceChannelDensityF64", record.sourceChannelDensityF64, 243, 8),
            ("sourceBaseDensityF64", record.sourceBaseDensityF64, 81, 8),
            ("sourceLogExposureF64", record.sourceLogExposureF64, 256, 8),
            ("sourceDensityCurvesF64", record.sourceDensityCurvesF64, 768, 8),
            ("sourceDensityCurvesLayersF64", record.sourceDensityCurvesLayersF64, 2304, 8)
        ]
        var seen = Set<String>()
        var exactChunks: [String: Data] = [:]
        for (name, encoded, count, stride) in fields {
            seen.insert(name)
            let bytes = try check(
                name: label + "/" + name,
                encoded: encoded, expected: expected.fields[name],
                count: count, stride: stride
            )
            if stride == 8, let bytes { exactChunks[name] = bytes }
        }
        try demand(Set(expected.fields.keys) == seen.subtracting(
            fields.filter { expected.fields[$0.0] == nil }.map { $0.0 }
        ), label + ": unexpected/missing measured source fields")
        try demand((expected.stage == "filming") ==
                   (exactChunks["sourceDensityCurvesLayersF64"] != nil),
                   label + ": original nine-layer presence changed")
        let sourceOrder = [
            "sourceLogSensitivityF64", "sourceChannelDensityF64",
            "sourceBaseDensityF64", "sourceLogExposureF64",
            "sourceDensityCurvesF64", "sourceDensityCurvesLayersF64"
        ]
        var payload = Data()
        for field in sourceOrder {
            if let chunk = exactChunks[field] { payload.append(chunk) }
        }
        try demand(digest(payload) == expected.source_payload_sha256,
                   label + ": original Float64 payload differs")
        try demand(record.sourceFloat64SHA256 == expected.source_payload_sha256,
                   label + ": generated SHA does not match original JSON")

        let masks: [(String, String, Int)] = [
            ("baseValidWavelengths", record.baseValidWavelengths, 81),
            ("sensitivityValidSamples", record.sensitivityValidSamples, 243),
            ("scannerValidWavelengths", record.scannerValidWavelengths, 81)
        ]
        try demand(expected.masks.count == 3,
                   label + ": expected null-mask set changed")
        for (name, encoded, count) in masks {
            let raw = try check(
                name: label + "/" + name,
                encoded: encoded, expected: expected.masks[name],
                count: count, stride: 1
            )
            guard let raw else {
                throw AuditError.failed(label + ": missing " + name)
            }
            try demand(raw.allSatisfy({ $0 == 0 || $0 == 1 }),
                       label + ": invalid null-mask byte")
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw AuditError.failed("Usage: Build77MeasuredProfileAudit manifest.json")
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        try demand(manifest.source_sha ==
                   "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc",
                   "Unpinned Python source")
        try demand(manifest.profile_tree_sha ==
                   "fa9262d2440903262dd302b52739162c939e153e",
                   "Unpinned source profiles")
        let records = GeneratedSpectralData.profiles
        try demand(records.count == 28 && manifest.profiles.count == 28,
                   "Missing 28 source materials")
        try demand(Set(records.keys) == Set(manifest.profiles.map(\.stock)),
                   "Swift and source stock IDs differ")
        for original in manifest.profiles {
            guard let swift = records[original.stock] else {
                throw AuditError.failed("Missing Swift material " + original.stock)
            }
            try verify(original, swift)
        }
        print("PASS Build77: Swift generated 28 material identities, all source "
              + "Float64 bytes, unchanged mobile Float32, null masks and "
              + "nine-sublayer presence match independent original JSON SHA256; "
              + "this does NOT certify iOS optical stage equality.")
    }
}
