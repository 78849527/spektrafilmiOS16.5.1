# Build106｜原版 Float64 大图内存生命周期专项（批量开发第一批）

**源码基线**：Build105-HF `cef0f7c87a2d17fdcde1b67a58c943692715ecd7`；iOS 16.5.1 已报告 28/28 原版核心阶段与 20/20 原版颗粒阶段 PASS。

## 生产代码修改

1. 新增 `Build106SourceMemoryLedger`：共享导出前 ImageIO 预检与 `developInPlace` 的所有功能开关字节预算，不再分叉维护 40/96/272/40/120/40 B/px。默认无阶段观察器时沿用 Build91 基线，避免未经 iPhone 实测就错误提高 13MP 内存准入。
2. 修正阶段观察器保守预算：旧代码以 24（另加相纸 48）B/px 估算，但回调可保留多份 Float64 全图；改为 960（另加相纸 48）B/px，按源阶段的多张快照预留，不关闭任何阶段，预算不足时显式拒绝而非 Jetsam/缩图/静默 Float32。
3. `OriginalSourcePhysicalGrain.apply` 九路 SciPy/fast_stats 采样结束后、Numba 微结构及末端 FIR/YVV 分配之前，立即释放不再读取的 9 通道输入插值、3 个颗粒采样 Double 1 通道工作区、染料云 RGB 工作区，使用原有 `removeAll(keepingCapacity:false)`。避免耗尽内存时过期缓冲与后期高斯同时驻留。不调整任何 NumPy/SciPy RNG 状态、原版计算公式/顺序/反射边界/浮点精度。
4. 增加 1/2/4/7.2/12/13MP 的 6 档纯预算测试及四种开关场景，检查源 13MP 上限、FFT 额外 40MB、诊断快照开销、1.9MP 粒子工作区释放约 228MB 的**理论可释放**数据，明确这并非 iOS RSS 测量。

## 认证范围

- 需重新跑未改原版 Python `grain.py/fast_stats.py` 的 5×4 阶段测试和 36 个 SciPy 单层胶片测试。
- 本批不主动构建 IPA。无真机 13MP 物理渲染 / Jetsam / 峰值 RSS 就不能声称已消除 OOM。
- 11–13MP 胶片颗粒依然会被真实设备内存预算拒绝时就显式告知，绝不自动切换算法。
