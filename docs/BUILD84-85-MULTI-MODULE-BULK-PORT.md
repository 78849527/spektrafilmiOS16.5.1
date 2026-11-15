# Build84–85 合批移植｜21–25 工作项｜动态 DIR + 原版 SciPy 颗粒

**基线**：Build83 C-R1 → Build84 第一／第二组合批 → 本分支。
**分支**：`port/build84-85-chemistry-grain-bulk-21-25`。
**iOS 兼容**：最低 16.5，严格按 iOS 16.5.1 目标设计。保留 v1.8.58 (83) 软件版本号，防止未经认证冒充正式 Build85。
**提交**：当前改动没有覆盖旧版主分支和 Build83 已发布的 IPA。

## 本轮合并的生产级能力

| # | 项目 | 实际生产入口 | 支持边界 |
|---|---|---|---|
| 1 | 20 款胶片专属 DIR 基准矩阵 | `Build84OriginalFilmDIR.stockMatrix` | 包含 Provia、Velvia、正负片 |
| 2 | DIR 同层与层间独立抑制 | `RuntimeSettings` → `prepare` | `amount`、same/interlayer |
| 3 | 256 节点 Float64 原版 H-D | `SpectralPhysics.sourceSpatialMeasuredHDCurves` | 非 Float32 胶片数据 |
| 4 | 自定义 DIR 修正前曲线重新计算 | `Build84OriginalFilmDIR.Prepared` | 一次处理前生成；保留原插值次序 |
| 5 | 每通道 Gamma+边界语义 | `Prepared.develop` | Right-biased、源原始 knots |
| 6 | 正负片显影+高曝光 inhibitor shift | `Prepared.inhibitor` | 原版低层 shift 默认 0 |
| 7 | DIR active=false 真正绕过化学 | `OriginalSourcePhysicalImage.developInPlace` | 不调用修正前曲线 |
| 8 | DIR 空间关闭但化学保留 | 同上 | 原版 0 μm 短路语义 |
| 9 | DIR 核尺寸、指数尾 μm/权重 | `SourceSpatialDIRConvolution.diffuseMemoryBounded` | 原版 FIR/YVV 全帧 |
| 10 | 颗粒单层与 n_sub_layers SciPy 分支 | `OriginalSourcePhysicalGrain.applySingleLayer` | 原版固定 channel+10×layer 种子 |
| 11 | 颗粒单层 0.4 px 模糊边界 | 同上 | >0.4 才应用 FIR/YVV |
| 12 | 颗粒三亚层 fast_stats 可选分支 | `OriginalSourcePhysicalGrain.apply` | **显式种子、受控单线程**，不冒充原版多线程 RNG |
| 13 | 胶片 H-D 最大密度用于单层颗粒 | `SpectralPhysics.sourceSpatialGrainSingleLayerMaximum` | 原版三通道测量 |
| 14 | 原版处理顺序回归 | `OriginalSourcePhysicalImage` | 颗粒始终在胶片显影后、印相前 |

**设计开关**：`OriginalSourcePhysicalImage.Parameters.sourceDIR` 默认为 `nil`；既有已验证路径保持原样。自定义 DIR 运行时源数据、原版校正曲线、Gamma 与扩散全部进入同一整图处理链；不偷偷替换为 RGB 3D LUT。新颗粒参数由 `sourceGrain.sublayersActive`、`nSubLayers`、`useFastStats` 明确选择。UI 尚未增加配置控件。

## 当前科学验收

- [Build84–85 Python / Swift CI](https://github.com/78849527/spektrafilmiOS16.5.1/actions/workflows/build84-85-bulk-source-parity.yml)。
- 80 组真实胶片原版 Python 动态 DIR 用例（20 胶片 × 4 参数），Linux Swift CPU Float64：**PASS**。矩阵最大误差 `1.11e-16`；修正前 256 节点最大 `5.329e-15`；初始/抑制/最终最大 `2.22e-15`。绝对门限 `5e-11`。
- 36 组真实胶片 SciPy 颗粒整幅测试（4 胶片 × 3 子层数 × 3 模糊边界），Linux Swift CPU Float64：**PASS**。最大误差 `8.882e-16`，绝对门限 `2e-8`。
- 粒子 Poisson→Binomial 顺序、按胶片通道和层次重置的 MT19937 种子以及 FIR/YVV 使用原生产代码，没有使用近似随机噪声替身。
- Numba fast_stats 支路只新增真实处理路径入口，**尚无与 Python 多线程完整颗粒的等价证据**。状态为「近似实现」，差异是确定的单线程随机流，不得宣称完整原版认证。
- 同时建立 [一次合批 iPhoneOS 编译工作流](https://github.com/78849527/spektrafilmiOS16.5.1/actions/workflows/build84-85-bulk-iphoneos-compile.yml)：生成原版数据，Xcode 16.4 下 `CODE_SIGNING_ALLOWED=NO` 只验证 arm64 app / Metal / iOS target；**不签名、不制作 IPA、不发布 Release**。

## 尚待正式验收

1. 新增动态 DIR 与单层颗粒在 **真实 iPhone iOS 16.5.1** 的完整像素阶段、输出尺寸、随机状态和内存测试。Linux 数值证据不能替代实机认证。
2. 原版并行 Numba fast_stats 的线程工作流与默认随机种子仍需独立设备一致性证明，不应以受控一线程等价代替。
3. 源 `gamma_beta` 仅出现在 `layer_particle_model` 低层未默认走的分支，本批未移植；`fixed_seed` 异常源行为也未假装完整。
4. 参数 UI 尚未正式接线，也未新发布任何 IPA。
5. Build85 工作项 23–25 不因为 36 个数值样本通过就宣称全部完成。

**发布规则**：后续再继续合批，直到 iPhoneOS、真实全图、内存、随机统计与 UI 验收足够，再打一次批量 IPA。
