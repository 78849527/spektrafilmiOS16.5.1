import Foundation

/// An exact-number JSON decoder for original Python source-fixture Float64.
/// Foundation JSONSerialization's NSNumber parser can round decimal text one
/// ULP differently from Python (e.g. 100.12236156288677 -> ...675).
/// Decode Double with Swift Codable's numeric parser instead; never relax
/// an original-source comparison tolerance to hide a parser defect.
///
/// This is a reusable source-contract input adapter. It does not modify
/// the image-processing algorithm, image pixels, or default UI settings.
indirect enum Build77ExactJSONValue: Decodable {
    case object([String: Build77ExactJSONValue])
    case array([Build77ExactJSONValue])
    case string(String)
    case boolean(Bool)
    case integer(Int)
    case double(Double)
    case null

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? single.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? single.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: single, debugDescription: "Nonfinite Python JSON number"
                )
            }
            self = .double(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([Build77ExactJSONValue].self) {
            self = .array(value)
        } else if let value = try? single.decode([String: Build77ExactJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single, debugDescription: "Unsupported original JSON type"
            )
        }
    }

    var foundationValue: Any {
        switch self {
        case .object(let values):
            return values.mapValues { $0.foundationValue }
        case .array(let values):
            return values.map { $0.foundationValue }
        case .string(let value):
            return value
        case .boolean(let value):
            return value
        case .integer(let value):
            return value
        case .double(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    static func decodeObject(from data: Data) throws -> [String: Any] {
        let decoded = try JSONDecoder().decode(Build77ExactJSONValue.self, from: data)
        guard let object = decoded.foundationValue as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "Expected original JSON object"
            ))
        }
        return object
    }
}
