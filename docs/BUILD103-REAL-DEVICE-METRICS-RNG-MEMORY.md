# SpektraFilm Build103｜真实 iPhone 阶段误差、受控颗粒与内存证据

**原版源码基线**：Build102（`74be48183f8ebef5176a57146911a5f252e9fad3`）已获真实 iOS 16.5.1 设备内置 Python/Swift 受控参考数值 PASS。
**本轮版本**：v1.8.70 / Build103；最低系统 iOS 16.5；保留胶片、相纸、原版算法和已验收 UI。

## 原版 Float64 扩展测试——真实逐阶段误差，不只是 PASS 字串

- 重用 Build92 `SourcePhysicalImageParity.evaluate(fixtures:)` 的已打包**4 组独立 Python 原版图像及 SHA-256 核验后的 Float64 源结果**，调用现有 Swift 生产 `OriginalSourcePhysicalImage.develop`。
- 新增 `onBuild103StageMetric` 观察者，仅在实际源比对并通过 `compare` 后记录对应阶段：每个 stock/case 的 7 个核心阶段 `logRaw / initial / inhibitors / diffused / correctedLog / density / printed`。
- **成功时应有 4×7=28 条** `coreStageMetrics`；包含 `mae`、`rmse`、`maximumAbsoluteError`、`worstPixel`、`worstChannel`、`overMaximumTolerance`、`maximumTolerance`、`maeTolerance`、实际对应 Python 源 `expectedPythonStageSHA256`。
- 保留源旧门限 `max=0.002`、原版 `mae=0.0003`（printed = 0.0005），不调整精度要求，也不省略原来的附加扫描眩光、受控 Numba 和相纸阶段自检。
- 失败时**保留已完成的前序阶段指标**和 `coreStageFirstFailure`，不能把剩余未经执行的阶段补为通过。28 条不全、重复阶段、非有限误差、超出原阈值、一条源 SHA 不符都不得标记为通过。

## 原版随机和内存的准确边界

- `sampleSeededNumba` 真正调用移植的 `OriginalSourceNumbaSingleThreadNormal(seed:8888)`，默认 8192 个正态样本，记录均值、总体方差、滞后 1 相关系数、最大绝对值以及是否有限，并执行宽松统计合理性门禁。**这不是独立 Python 无 seed/prange 多线程数值对照。** `unseededMultiworkerCertified=false` 固定为 false。
- `sampleBoundedMemory` 在设备上真实申请并按页写入 **8 MiB** 物理进程内存，记录 `ProcessInfo.processInfo.physicalMemory` 与 `os_proc_available_memory()` 前／中／后的预算读数。此值不是驻留峰值（RSS），也不是 13MP 整图光学工作量。
- `full13MPOperationMeasured=false` 与 `fullPythonOriginalCertified=false` 恒为 false。真实 13MP 图像及大图 Jetsam／热压力测试**尚未执行**，需专用真机性能批次；不能因本批内存探针运行就填写完成。

## 手机实际执行

在 Build103 签名安装的 App 内打开：

**高级 → 验证状态与诊断 → Build103：28 阶段误差、受控颗粒与实际内存报告**

执行后通过系统分享生成的 `Build103-device-metrics-*.json`，包含当前 `SFSourceCommit`（CI 真正嵌入的 40 位源码 SHA）、真实 iOS 版本、设备标记、Python 原版 manifest SHA、28 个数值指标或首错、随机统计和内存样本。

构建成功、macOS 运行源数据和模拟测试**不能替代**真实 iPhone 16.5.1 报告。源 SHA 无效或不在实体 iOS 16.5.1 环境时，`controlledCoreStagesPassedOnTarget=false`。

## 自动化

- 继承 Build102～97 所有 GitHub Actions 静态／源参考、真实 Core Image 故障注入、RGB48/TIFF16、旧 UI/交互和 SHA 身份门禁。
- `ios/tests/Build103DeviceMetricsValidation.swift` 在 CI macOS 上执行真实 8192 Numba 种子序列、8 MiB 触页、实际 JSON 写入回读、缺 1 阶段、超阈值、源清单缺失、首错保留、缺 SHA 和非目标 iOS 负例。**生成的 28 条输入数据仅用于 schema 负例测试，绝不是外部原版数值等价证据**。
- iPhoneOS arm64 Release 编译、Info.plist 中 `SFSourceCommit == GITHUB_SHA`、最终 IPA 与 Release SHA 完整核对，依然保持 `UNSIGNED-UNVERIFIED`。

## 下一步

拿到用户设备的 Build103 JSON 后根据实测阶段 MAE 和首错排序，先修超阈值的第一个光学阶段，再处理不带固定 seed 的多线程 Numba/高分辨率占用；这些模块目前仍标记未认证。富士 RAW 专项保持暂停，已移植的 LibRaw 等原功能完整保留。
