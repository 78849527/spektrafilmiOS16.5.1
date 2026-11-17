# Build116 | 原版 Float64 三亚层颗粒：内存生命周期优化与真实 RSS

基线：Build115 v1.8.81，已完成 Apple Silicon macOS 15 的 IPA 编译、Numba 统计真机验证与 13MP **无颗粒** Float64 真机测试。

## 目标

在不改变 Python 源码公式、SciPy/Numba 随机数消耗顺序、FIR/YVV 边界、色彩精度与默认设置的条件下，减少三亚层颗粒峰值内存。不得为达到 13MP 目标擅自降低分辨率、禁用颗粒、转为 GPU Float32 或降低原版数值精度。

## 已实现的第一批（Build116，v1.8.82）

1. `SourceGrainScalarGaussian.swift`：染料云原来每次只使用三通道中的一个通道，却仍分配全 RGB 输入、RGB 输出和两张中间标量场。现在单层只存一张标量输入、一张标量中间场，保持全图 reflect FIR、YVV 双向递推及 Double 计算。
2. `OriginalSourcePhysicalGrain.apply`：染料云阶段接入上面的标量滤波。严格保留九亚层逐层 Poisson → Binomial → 染料云次序，不修改 `OriginalSourceSciPySampler` 或 `OriginalSourceNumbaParallelWorkers`。
3. `OriginalSourcePhysicalImage.developInPlace`：全部像素完成 DIR 修正并得到膜片密度之后、调用三亚层颗粒前，显式释放不再使用的全图三通道 DIR 扩散场；不改变任何像素运算。
4. `Build108SourceOpticalDeviceStress`：把所有尺寸放到一次触发的 **8 尺寸 × 双颗粒路线＝16 项矩阵**：1、2、3、4、6、8、10、13MP；每个尺寸分别覆盖原版 SciPy 三亚层及 Numba 四工作线程 fast_stats。每项先过真实生产内存门槛，允许的才执行完整 Float64 光学链路并每 25ms 采样 RSS；拒绝的明确写入原因，不自动缩图或降低精度。每一项运行前后原子更新检查点，避免中途崩溃时完全失去定位信息。

## 预算与认证边界

- 单通道染料云阶段：原局部缓冲 64 B/像素；新局部缓冲 16 B/像素；按数组分配模型减少 **48 B/像素**，13MP 相当于约 624MB 暂存分配差额。
- 消费完成的 DIR 三通道场：释放 24 B/像素，13MP 相当于约 312MB 的不必要保留。
- **不能简单将两项相加等同于整机 RSS 的实际下降**。Swift CoW、系统缓存、不同阶段的峰值时间和临时数值数组会影响真实峰值。以上均为结构性内存分析，不是 13MP 含颗粒实测。
- `Build91PhysicalMemory` 原保守预算和 1.5 GB / 物理内存三分之一 / 当前余量 80% 安全门槛 **未下调**。
- 13MP + 3×3 颗粒 + 4-worker fast_stats 的保守预算仍为 440 B/px × 13M = 5.72GB。现行预算下预检会拒绝；**拒绝执行不等于该尺寸实测通过**。同一次报告记录这个结果，后续优化时可继续用同一入口重新验证。
- 仍不认证无固定种子随机流逐位同一、RAW 与 Python 大图全流程精确一致。

## CI 验证

- Apple Silicon macOS 15 + Swift Float64。
- 旧三通道 `SourceSpatialDIRConvolution.diffuseMemoryBounded` 与新单通道函数必须在 6 种宽高、10 种 sigma（含 FIR/YVV 分界与单像素边界）共 **60 组**中逐像素 `bitPattern` 相同。
- 源码级检查确保新通道被正式生产调用，老的 `272 + 56 B/px` 预检仍保留，`diffused` 在真实颗粒前释放；测试矩阵必须完整包含 8 个尺寸、两种颗粒随机路线，不允许把拒绝执行当作 PASS。
- 只有真实 Xcode iPhoneOS arm64 编译、IPA SHA 验证和 Release 资源核验通过后才发布实验版 IPA。

## 真机验收（等新 IPA）

1. iOS 16.5.1 真机安装签名后的 Build116，核对版本 `1.8.82 / 116`、源码 SHA。
2. `高级 → 验证状态与诊断`，**只点一次 Build116：一次测试 1–13MP 全尺寸 × 双颗粒路线**。测试会按尺寸由小到大逐项执行，无需每档重新安装。运行前保存工作，仍可能发生 Jetsam。
3. 导出 `Build116-grain-memory-*.json` 和 `.log`；若闪退，提供文件目录中的 `Build116-last-grain-memory-checkpoint.txt`。
4. 核对 `plannedCaseCount=16`，每项明确记录 `real_source_float64_render_pass`、`refused_by_production_memory_gate`、`real_source_render_failed_or_unmeasured` 或 `not_run`；真实执行项包含 RSS、耗时、SHA 和输出校验。报告中的 `allAdmittedCasesPassed` 只代表获准执行项全部通过，不代表全部 16 项都实际跑过。
5. 所有尺寸与两条颗粒路线的结果在 **同一份 JSON＋LOG** 中展示；内存预检被拒绝的尺寸需要后续优化才能真正执行。任何 `refused`、`not_run` 都不能被当作实际运行成功；不以 13MP 无颗粒报告代替含颗粒实测。
