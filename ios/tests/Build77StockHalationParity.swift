import Foundation

/// Real compiled Swift original-material table vs *independent* Python
/// digest_params output for ALL 20 filming stocks x 8 paper stocks.
/// This proves this one production stock-baseline binding only; it does NOT
/// certify whole-frame optical imaging or random halation.
@main
struct Build77StockHalationParity {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let s) = self { return s }
            return nil
        }
    }

    private static func floats(
        _ root:[String:Any], path:[String]
    ) throws -> [Double] {
        var value:Any = root
        for segment in path {
            guard let dict=value as? [String:Any],
                  let next=dict[segment] else {
                throw Failure.invalid("Missing original source field "
                                      + path.joined(separator:"."))
            }
            value=next
        }
        guard let numbers=value as? [NSNumber],numbers.count==3 else {
            throw Failure.invalid("Expected Python Float64 triplet "
                                  + path.joined(separator:"."))
        }
        return numbers.map(\.doubleValue)
    }

    static func main() throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Usage: native-stock-test python-digest.json")
        }
        let data=try Data(contentsOf:
            URL(fileURLWithPath:CommandLine.arguments[1]))
        let original=try Build77ExactJSONValue.decodeObject(from:data)
        guard let cases=original["cases"] as? [[String:Any]],
              cases.count==360,
              let sha=original["upstream_sha"] as? String,
              sha=="3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
        else {
            throw Failure.invalid("Original Python 360-case source contract absent")
        }
        guard GeneratedBuild77StockHalationSource.records.count==20 else {
            throw Failure.invalid("Not all 20 original filming stocks in iOS")
        }
        var compared=0
        var stockIDs=Set<String>()
        for item in cases {
            guard item["mode"] as? String=="base" else { continue }
            guard let info=item["film_info"] as? [String:Any],
                  let stock=info["stock"] as? String,
                  let use=info["use"] as? String,
                  let anti=info["antihalation"] as? String,
                  let expected=item["expected"] as? [String:Any] else {
                throw Failure.invalid("Invalid stock-specific Python case")
            }
            let record=try Build77StockHalation.originalPreset(filmID:stock)
            guard record.sourceUse==use,
                  record.sourceAntihalation==anti else {
                throw Failure.invalid("Real Swift stock metadata drift: "+stock)
            }
            let a=try floats(expected,path:[
                "film_render","halation","halation_first_sigma_um"
            ])
            let b=try floats(expected,path:[
                "film_render","halation","halation_strength"
            ])
            for index in 0..<3 {
                guard record.sigmaUM[index].bitPattern==a[index].bitPattern,
                      record.strength[index].bitPattern==b[index].bitPattern else {
                    throw Failure.invalid(
                        "Original Python/production Swift stock preset mismatch: "
                        + stock + " channel=\(index)"
                    )
                }
            }
            stockIDs.insert(stock)
            compared += 1
        }
        guard stockIDs.count==20,compared==160 else {
            throw Failure.invalid(
                "Original 20×8 base stock/paper comparisons incomplete"
            )
        }
        var unknownRejected=false
        do {
            _ = try Build77StockHalation.originalPreset(
                filmID:"not-an-upstream-film-stock"
            )
        } catch { unknownRejected=true }
        guard unknownRejected else {
            throw Failure.invalid("Unknown original stock must fail closed")
        }
        print("PASS 160/160 original Python digest stock/paper base pairs "
              + "vs actual generated production Swift halation: 20 distinct "
              + "film presets, 3x2 Float64 bitwise exact; unknown stock "
              + "rejected. Scope: HALATION PRESET VALUES ONLY.")
    }
}
