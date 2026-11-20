# Build137｜RAW 原片直通精细冲印：无损数值优化

日期：2026-11-20。沿用 `work/build129-raw-float32-srgb-icc-admission-ios1651`；不修改 main，不新开功能分支。本批只优化 RAW 原片直通的执行速度，**不改变已验证观感**。

## 不变契约

- 原始 DNG、LibRaw 线性 ACES16、源 Float64、Portra 400 / Portra Endura 原版测量数据、H-D/DIR、光学相纸、扫描数学顺序、随机种子与颗粒消费顺序均不变。
- 不降低分辨率、不关闭任何效果、不替换 LUT/近似算子、不改变精度或参数默认值。
- 源文件异常仍显式报错，无 8-bit / Float32 / Apple RAW 静默降级。

## 生产代码优化

1. `SpectralPhysics.Profile` 每种材料只在初始化时解析一次 81 波长片基值、243 个染料吸光值与有效波长索引。源 Float64 保留原 bitPattern；移动 Float32 仅执行原有 Double(Float) 转换。扫描／印相仍以相同的**原始有效波长升序**、相同的 `+=` 和 `pow(10,-density)` 运算。
2. 源曝光参考 `log2(sourceFilmingExposureFactor)` 在准备参考时计算一次；原数值表达式和运算顺序保持不变。
3. 对未启用独立相机预处理的 RAW 物理链，恒定曝光倍率 `pow(2,cameraEV+reference)` 在整帧开始时计算一次，逐像素复用。启用相机前级光学时保持原有相机光子路径，完全不改。
4. 未更动内存保护、全帧 FFT、九亚层颗粒或随机路径。

## 验证

- `SpectralPhysics.verifyPreparedScannerSamples()`：28 份材料 × 2 精度 × 81 波长、RGB 三染料的逐 Double.bitPattern 验证，并比较原波长顺序。
- `SpectralPhysics.verifyPreparedCameraMultiplier()`：Portra 400 / Endura 的原 sourceSpatialInput 与预计算输入在 5 组 RGB × 3 档 EV 上对比 `rawLog` 和 `initialDensity` 的 Double.bitPattern。
- 两个检查接入现有 `SourcePhysicalImageParity.evaluate`，仅在诊断／源参考测试时执行，生产 RAW 热路径不运行测试。
- 独立 Linux Swift -O **合成 18 万像素光谱内核**局部基准：Float64 旧 0.213s、新 0.204s；Float32 旧 0.226s、新 0.203s；两种模式逐位 PASS。它只验证光谱准备方向，**不代表真实 1219 万 RAW 的耗时、A15 性能或端到端像素等价**。

## 待认证事实

iPhoneOS Release 编译、原版 Python 全流程数值回归、同机同 RAW 的完整耗时和峰值 RSS，须以本 SHA 的 GitHub CI 和真实 iOS 16.5.1 设备报告为准。未通过前不得将本批标记为实机 PASS，也不得声称特定整帧提速百分比。
