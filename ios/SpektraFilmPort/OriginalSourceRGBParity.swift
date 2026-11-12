import Foundation

/// Stage-scoped source RGB numerical evidence:
/// POSITIVE film, source 81-wavelength scanner, ACES-RGC option, sRGB CCTF.
/// Does not include input RAW/negative film emulsion/printing/grain, glare,
/// unsharp, final JPEG or per-pixel 3D color-cube interpolation.
///
/// The report is intentionally NOT a PASS certificate when numerical
/// deviations exist; every actual error remains visible for investigation.
enum OriginalSourceRGBParity {
    struct Metrics {
        let mae: Double
        let rmse: Double
        let maximum: Double
        let worstCase: String
        let samples: Int
        let outsideTolerance: Int
        let stageEvidence: String

        var text: String {
            let verdict = outsideTolerance == 0
                ? "样本误差在 0.002 sRGB 范围内（不代表整图认证）"
                : "存在 \(outsideTolerance) 个通道绝对误差超过 0.002，尚未数值等价"
            return """
            Python 正片直扫 RGB 对照：\(samples) 个通道
            源扫描→XYZ→ACES RGC→sRGB；Swift 走同一独立扫描分支。
            MAE=\(mae)，RMSE=\(rmse)，max=\(maximum)
            最大误差样本：\(worstCase)
            分段证据（同一 24 组样本 / 72 通道）：
            \(stageEvidence)
            \(verdict)。
            注意：不含相纸、RAW、完整 RGB 图像、Numba 随机颗粒或 JPEG。
            """
        }
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }

    static func evaluate() throws -> Metrics {
        let cases = GeneratedSourceRGBReference.cases
        guard cases.count >= 24,
              GeneratedSourceRGBReference.sourceSHA.count >= 4 else {
            throw Failure.invalid("原版正片扫描 RGB：Python 参考数据不完整")
        }
        var engines: [String: SpectralPhysics] = [:]
        var absSum = 0.0
        var squareSum = 0.0
        var maximum = 0.0
        var worst = ""
        var samples = 0
        var deviations = 0
        var stageAbs = [Double](repeating: 0, count: 4)
        var stageSquares = [Double](repeating: 0, count: 4)
        var stageMax = [Double](repeating: 0, count: 4)
        var stageWorst = [String](repeating: "", count: 4)
        var stageOver = [Int](repeating: 0, count: 4)
        for (index,sample) in cases.enumerated() {
            let engine: SpectralPhysics
            if let cached = engines[sample.stock] {
                engine = cached
            } else {
                let built = try SpectralPhysics(
                    filmID: sample.stock,
                    paperID: "kodak_portra_endura",
                    sourceScanner: true, scannerBlackWhite: false,
                    cam16Gamut: false
                )
                guard SpectralPhysics.isPositiveFilm(sample.stock) else {
                    throw Failure.invalid("源 RGB 参考混入负片；负片必须经过原版相纸链路")
                }
                engines[sample.stock] = built
                engine = built
            }
            guard sample.density.count == 3,
                  sample.sourceEncodedRGB.count == 3,
                  sample.sourceLinearRGB.count == 3,
                  sample.sourceXYZ.count == 3,
                  sample.sourceCompressedRGB.count == 3 else {
                throw Failure.invalid("原版 RGB 输入/参考通道数错误")
            }
            let native = engine.scanFilmDensity(
                sample.density, paperEV: 0
            )
            let stages = try engine.directPositiveScannerStages(sample.density)
            guard native.count == 3,
                  zip(native, stages.encoded).allSatisfy({
                      abs($0.0 - $0.1) < 1e-12
                  }) else {
                throw Failure.invalid("原版 RGB Swift 扫描结果通道数错误")
            }
            for channel in 0..<3 {
                let expected = sample.sourceEncodedRGB[channel]
                let actual = native[channel]
                guard actual.isFinite && expected.isFinite else {
                    throw Failure.invalid(
                        "原版扫描 RGB 非有限值：样本 \(index) 通道 \(channel)"
                    )
                }
                let err = abs(actual-expected)
                absSum += err
                squareSum += err*err
                samples += 1
                if err > 0.002 { deviations += 1 }
                if err > maximum {
                    maximum = err
                    worst = "\(sample.stock) case=\(index), channel=\(channel)," +
                        " Python=\(expected), Swift=\(actual)"
                }
            }
            let reference = [
                sample.sourceXYZ, sample.sourceLinearRGB,
                sample.sourceCompressedRGB, sample.sourceEncodedRGB
            ]
            let observed = [
                stages.xyz, stages.linear, stages.compressed, stages.encoded
            ]
            for stage in 0..<4 {
                guard reference[stage].count == 3,
                      observed[stage].count == 3 else {
                    throw Failure.invalid("原版扫描 RGB 分段参考通道数错误")
                }
                for channel in 0..<3 {
                    let expected = reference[stage][channel]
                    let actual = observed[stage][channel]
                    guard actual.isFinite && expected.isFinite else {
                        throw Failure.invalid("原版扫描分段产生非有限值")
                    }
                    let err = abs(actual - expected)
                    stageAbs[stage] += err
                    stageSquares[stage] += err * err
                    if err > 0.002 { stageOver[stage] += 1 }
                    if err > stageMax[stage] {
                        stageMax[stage] = err
                        stageWorst[stage] = "\(sample.stock) case=\(index)" +
                            " channel=\(channel) 原版=\(expected) iOS=\(actual)"
                    }
                }
            }
        }
        let n = Double(samples)
        let names = ["密度→XYZ", "XYZ→线性sRGB", "ACES RGC", "sRGB CCTF"]
        let firstDivergent = stageOver.firstIndex(where: { $0 > 0 })
        let stageEvidence = (0..<4).map { i in
            "\(names[i]): MAE=\(stageAbs[i]/n), " +
            "RMSE=\(sqrt(stageSquares[i]/n)), max=\(stageMax[i]), " +
            "超限=\(stageOver[i])/\(samples), 最大项：\(stageWorst[i])"
        }.joined(separator: "\n") +
        "\n最早超限阶段：" +
        (firstDivergent.map { names[$0] } ?? "本组 0.002 门限下无超限")
        return Metrics(
            mae: absSum/n, rmse: sqrt(squareSum/n),
            maximum: maximum, worstCase: worst,
            samples: samples, outsideTolerance: deviations,
            stageEvidence: stageEvidence
        )
    }

    static func report() throws -> String {
        try evaluate().text
    }
}
