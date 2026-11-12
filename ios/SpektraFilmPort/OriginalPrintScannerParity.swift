import Foundation

/// Stage-specific original Python equivalence evidence for printing media.
/// The 8 media are exposed by a negative film configuration, but these
/// measurements start AFTER development at measured PAPER CMY densities.
/// They do not claim original negative->print H-D/RAW/grain/whole image.
enum OriginalPrintScannerParity {
    struct Metrics {
        let samples: Int
        let outsideTolerance: Int
        let mae: Double
        let rmse: Double
        let maximum: Double
        let stageReport: String

        var text: String {
            """
            Python 原版相纸/印片扫描 RGB 分段数值对照：\(samples) 通道
            范围：相纸 CMY 密度→扫描 XYZ→线性 sRGB→ACES RGC→sRGB CCTF。
            不含负片显影、放大机曝光、相纸 H-D、RAW、随机颗粒及整图。
            最终 MAE=\(mae)，RMSE=\(rmse)，max=\(maximum)，
            超过 0.002：\(outsideTolerance)/\(samples)
            \(stageReport)
            """
        }
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    static func evaluate() throws -> Metrics {
        let cases = GeneratedSourcePrintScannerReference.cases
        guard cases.count == 24,
              !GeneratedSourcePrintScannerReference.sourceScanningSHA256.isEmpty else {
            throw Failure.invalid("相纸扫描原版 Python 参考向量不完整")
        }
        var engines: [String: SpectralPhysics] = [:]
        var absolute = [Double](repeating: 0, count: 4)
        var squared = [Double](repeating: 0, count: 4)
        var maximum = [Double](repeating: 0, count: 4)
        var over = [Int](repeating: 0, count: 4)
        var worst = [String](repeating: "", count: 4)
        for (index, sample) in cases.enumerated() {
            let engine: SpectralPhysics
            if let existing = engines[sample.medium] {
                engine = existing
            } else {
                let created = try SpectralPhysics(
                    filmID: "kodak_portra_400",
                    paperID: sample.medium,
                    sourceScanner: true, scannerBlackWhite: false,
                    cam16Gamut: false
                )
                engines[sample.medium] = created
                engine = created
            }
            guard sample.density.count == 3,
                  sample.sourceXYZ.count == 3,
                  sample.sourceLinearRGB.count == 3,
                  sample.sourceCompressedRGB.count == 3,
                  sample.sourceEncodedRGB.count == 3 else {
                throw Failure.invalid("相纸扫描参考样本维度不正确")
            }
            let observed = try engine.directPrintScannerStages(sample.density)
            let stages = [observed.xyz, observed.linear,
                          observed.compressed, observed.encoded]
            let original = [sample.sourceXYZ, sample.sourceLinearRGB,
                            sample.sourceCompressedRGB, sample.sourceEncodedRGB]
            for stage in 0..<4 {
                for channel in 0..<3 {
                    let expected = original[stage][channel]
                    let actual = stages[stage][channel]
                    guard expected.isFinite && actual.isFinite else {
                        throw Failure.invalid("相纸扫描阶段数值非有限")
                    }
                    let difference = abs(actual - expected)
                    absolute[stage] += difference
                    squared[stage] += difference * difference
                    if difference > maximum[stage] {
                        maximum[stage] = difference
                        worst[stage] = "\(sample.medium) #\(index) ch=\(channel) " +
                            "Python=\(expected) Swift=\(actual)"
                    }
                    if difference > 0.002 { over[stage] += 1 }
                }
            }
        }
        let n = Double(cases.count * 3)
        let labels = ["密度→XYZ", "XYZ→线性 sRGB", "ACES RGC", "sRGB CCTF"]
        let report = (0..<4).map { i in
            "\(labels[i])：MAE=\(absolute[i]/n)，" +
            "RMSE=\(sqrt(squared[i]/n))，max=\(maximum[i])，" +
            "超限=\(over[i])/\(Int(n))，最差=\(worst[i])"
        }.joined(separator: "\n")
        return Metrics(
            samples: Int(n),
            outsideTolerance: over[3],
            mae: absolute[3] / n,
            rmse: sqrt(squared[3] / n),
            maximum: maximum[3],
            stageReport: report
        )
    }
}
