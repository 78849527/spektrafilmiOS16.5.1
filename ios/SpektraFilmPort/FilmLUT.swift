import Foundation

enum LUTReadError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let description) = self { return description }
        return nil
    }
}

/// Adobe .cube, R fastest then G then B. This does not run the spectral model.
struct FilmLUT {
    let title: String
    let dimension: Int
    let rgbaFloatData: Data

    static func read(text: String, filename: String) throws -> FilmLUT {
        var title = filename
        var size: Int?
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values = [Float]()

        for raw in text.components(separatedBy: .newlines) {
            let withoutComment = raw.components(separatedBy: "#").first ?? ""
            let line = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let key = fields.first else { continue }

            switch key.uppercased() {
            case "TITLE":
                title = line.dropFirst(key.count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard size == nil, fields.count == 2,
                      let n = Int(fields[1]), (2...65).contains(n) else {
                    throw LUTReadError.invalid("仅支持 2 至 65 级的 3D .cube LUT")
                }
                size = n
                values.reserveCapacity(n * n * n * 4)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard fields.count == 4,
                      let x = Float(fields[1]), let y = Float(fields[2]),
                      let z = Float(fields[3]) else {
                    throw LUTReadError.invalid("LUT DOMAIN 格式无效")
                }
                if key.uppercased() == "DOMAIN_MIN" {
                    domainMin = [x, y, z]
                } else {
                    domainMax = [x, y, z]
                }
            case "LUT_1D_SIZE":
                throw LUTReadError.invalid("暂不支持包含 1D shaper 的 .cube 文件")
            default:
                guard let n = size, fields.count == 3,
                      let r = Float(fields[0]), let g = Float(fields[1]),
                      let b = Float(fields[2]), r.isFinite, g.isFinite, b.isFinite,
                      values.count < n * n * n * 4 else {
                    throw LUTReadError.invalid("LUT 数值或排列不符合规范")
                }
                values.append(contentsOf: [r, g, b, 1])
            }
        }

        guard let n = size, values.count == n * n * n * 4 else {
            throw LUTReadError.invalid("LUT 数据量与 LUT_3D_SIZE 不一致")
        }
        guard domainMin.allSatisfy({ abs($0) < 0.00001 }),
              domainMax.allSatisfy({ abs($0 - 1) < 0.00001 }) else {
            throw LUTReadError.invalid("当前仅支持 0 到 1 的输入 Domain")
        }
        let bytes = values.withUnsafeBufferPointer {
            Data(bytes: $0.baseAddress!, count: $0.count * MemoryLayout<Float>.size)
        }
        return FilmLUT(title: title.isEmpty ? filename : title,
                       dimension: n, rgbaFloatData: bytes)
    }
}
