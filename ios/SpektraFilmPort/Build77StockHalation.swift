import Foundation

/// Source-physical production binding for the ORIGINAL Python
/// params_builder._apply_halation_preset per-stock material metadata.
/// The values are generated from locked upstream Python source+JSON, not
/// inferred from UI stock names or approximate photographic categories.
/// Does NOT claim source-default full halation/scatter equivalence.
enum Build77StockHalation {
    enum Error: LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    struct Record {
        let sigmaUM:[Double]
        let strength:[Double]
        let sourceUse:String
        let sourceAntihalation:String
        let hasStockPreset:Bool

        func validate(stock:String) throws {
            guard sigmaUM.count == 3, strength.count == 3,
                  sigmaUM.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  strength.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  !sourceUse.isEmpty, !sourceAntihalation.isEmpty else {
                throw Error.invalid(
                    "原版胶片低层光晕预设损坏：" + stock
                )
            }
        }
    }

    /// Call from real ContentView.sourcePhysicalParameters() only after the
    /// user selected source-physical processing. A missing material is a hard
    /// error, not the old same-sigma-for-all-stock or arbitrary fallback.
    static func originalPreset(filmID:String) throws -> Record {
        guard let record = GeneratedBuild77StockHalationSource.records[filmID]
        else {
            throw Error.invalid(
                "原版胶片光晕元数据未打包：" + filmID
                + "。禁止套用任意胶片的反射参数"
            )
        }
        try record.validate(stock:filmID)
        return record
    }
}
