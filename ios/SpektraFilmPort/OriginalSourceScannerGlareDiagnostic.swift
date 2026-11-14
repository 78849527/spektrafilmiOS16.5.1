import Foundation

/// The *same* source glare.py algorithms called from the iPhone A15
/// diagnostics, with upstream Python fixture vectors generated before
/// the Release build. A successful result is a stage-scoped validation
/// for a controlled single Numba worker, NOT a full production image.
enum OriginalSourceScannerGlareDiagnostic {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    static func evaluate() throws -> String {
        let reference = GeneratedSourceScannerGlareReference.cases
        guard reference.count == 6,
              GeneratedSourceScannerGlareReference.glareBlob ==
                  "e8610f13430d45be749ae31a5284eef2c2b7a362",
              GeneratedSourceScannerGlareReference.statsBlob ==
                  "9e80d29ce6b9f7820ae70f5c09da15edfaa70a0d",
              GeneratedSourceScannerGlareReference.filterBlob ==
                  "8918c673ea0fb3f5d9ae820ca85bf6db4aba457a"
        else {
            throw Failure.invalid("扫描器眩光源代码哈希或原版参考向量缺失")
        }
        var totalField = 0, totalXYZ = 0
        var largestField = 0.0, largestXYZ = 0.0
        for fixture in reference {
            let settings = OriginalSourceScannerGlare.Settings(
                active: fixture.enabled, percent: fixture.percent,
                roughness: fixture.roughness, blur: fixture.blur
            )
            let got = try OriginalSourceScannerGlare.computeAmount(
                width: fixture.width, height: fixture.height,
                settings: settings, controlledSeed: fixture.seed
            )
            let gotXYZ = try OriginalSourceScannerGlare.addToXYZ(
                fixture.inputXYZ, illuminantXYZ: fixture.illuminantXYZ,
                width: fixture.width, height: fixture.height,
                settings: settings, controlledSeed: fixture.seed
            )
            guard got.count == fixture.amounts.count,
                  gotXYZ.count == fixture.outputXYZ.count else {
                throw Failure.invalid("扫描器眩光参考样本维度不一致")
            }
            for i in got.indices {
                let delta = abs(got[i] - fixture.amounts[i])
                largestField = max(largestField, delta)
                guard delta <= 1e-11 * (1 + abs(fixture.amounts[i])) else {
                    throw Failure.invalid(
                        "扫描器眩光：源 Numba/FIR-YVV 随机场未通过" +
                        " seed=\(fixture.seed) index=\(i) Δ=\(delta)"
                    )
                }
            }
            for i in gotXYZ.indices {
                let delta = abs(gotXYZ[i] - fixture.outputXYZ[i])
                largestXYZ = max(largestXYZ, delta)
                guard delta <= 1e-11 * (1 + abs(fixture.outputXYZ[i])) else {
                    throw Failure.invalid(
                        "扫描器眩光：源 XYZ 叠加未通过" +
                        " seed=\(fixture.seed) index=\(i) Δ=\(delta)"
                    )
                }
            }
            totalField += got.count
            totalXYZ += gotXYZ.count
        }
        // Reject implicit randomness. The default Python source uses
        // unseeded multiworker Numba; the controlled single-thread stage
        // must not quietly switch to a hash noise approximator.
        do {
            _ = try OriginalSourceScannerGlare.computeAmount(
                width: 2, height: 2,
                settings: .init()
            )
            throw Failure.invalid("原版眩光：未提供 RNG 却静默产生随机场")
        } catch OriginalSourceScannerGlare.Failure.invalid { }

        return "Python 原版 glare.py/fast_stats.py/fast_gaussian_filter.py" +
               " 实际数值对照：\(reference.count) 个二维场，" +
               "\(totalField) 个眩光 Float64 值 + \(totalXYZ) 个 XYZ 通道。" +
               "\n源对数正态→reflect FIR/YVV→/100→扫描光源 XYZ。" +
               "\n最大随机场误差=\(largestField)，" +
               "最大 XYZ 误差=\(largestXYZ)（阈值 1e-11）。" +
               "\n【范围限制】只认证显式固定种子单线程 Numba 算法；" +
               "未接入完整生产扫描 XYZ，未认证无固定种子的多线程 RNG、" +
               "整图 RGB、RAW 或真机显示一致性。"
    }
}
