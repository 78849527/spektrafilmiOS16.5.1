# Build91｜CPU Double FFT 缓冲复用、Metal YVV pipeline 缓存与 1–13MP 原版内存预检｜42–44

**基线**：已通过 iPhoneOS arm64 Release 编译的 Build90 `20cb39daf08f3f117820a98231720adba8c875d9`。当前分支 `port/build91-double-fft-scratch-metal-memory-42-44`。原版 Python 上游源仍唯一算法基准，不自动改基线、默认参数或输出算法。未发布 IPA。

## 42. CPU Float64、源反射 FFT 内存复用

1. `OriginalSourceDiffusion.fft2` 继续调用原始 `fft1` 并完全保持蝶形运算顺序：横向全部行，纵向全部列，原版 NumPy reflect padding 与 FFT 对应端点不变。原实现**每条行/每条列**重新分配两个 Float64 数组，现改为**每次 2D FFT 仅两组行列缓冲**；同尺寸每个 row/column 覆写后复用。
2. `OriginalSourceDiffusion.apply` 在三个 RGB 通道之间复用四个完整 FFT Double planes（原来每个通道各新分配四块）；通道间使用字节级 IEEE754 +0.0 清零，保证零填充及相同 butterfly 输入，无碰撞和 Float32 替代。
3. 源径向 PSF、4 optical families（Glimmerglass / Black Pro-Mist / Pro-Mist / Cinebloom）、source scatter fraction、三通道 halo warmth、reflection FFT 卷积、合成先后均原样保留。
4. `Build91DoubleFFTBenchmark.swift` 由 GitHub Actions 分别从**旧 Build90 生产源**与**Build91 生产源**独立 `swiftc -O`，在 113×87 和 320×224 真实完整浮点 RGB 两帧对照，比较所有像素后再记录墙钟时间与 OS RSS。数学误差 **0**。性能不是硬保证，应以真实 iPhone 12MP 性能评估为准。
5. **数值认证**：[Build91 108 原版 Python 2D FFT frames](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43690710183) **PASS**；[Build90 vs Build91 全画幅逐值及真实性能基准](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43690710168) **PASS**，113×87 的 1.07×，320×224 的 0.986×（一次 runner 样本，不能据此宣称稳定加速）；峰值 RSS 66056KiB vs 66220KiB。优化**减少分配次数**已完成，但**尚未证实稳定性能/RSS 提升**，保留为 42 项部分完成；CPU SIMD/Accelerate 分支尚未认证。

## 43. Metal IIR full-frame Float32 仅优化独立快速路径

6. `OriginalMetalIIR.swift` 对四个源 YVV 横纵递归 pass 及生产原地 pass 增加容量 12 的 Metal pipeline-state cache。设备、动态 library **对象身份**、kernel 名称共同决定 key；变更 GPU 或 library 必须重新编译 shader，不缓存相片数据或随机序列。并发构建有锁与二次命中检查，最多保留 12 个强引用 entries。
7. Python source 系数仍 CPU Double 计算后按原路径转 GPU Float32，四次 encoder 顺序、线程每行/每列归属、reflect endpoint/原地 3 通道不变。绝不把 Float32 YVV 结果替换精确模式的 CPU Double。
8. `OriginalMetalIIR.hardwareDiagnostic()` 现会校验至少 8 个 pipeline 被创建且第二组 fixture 命中至少 8 次，仍继续原来 NumPy→GPU 的完整图像误差阈值 `≤0.0005`。**未在实际 iPhone16.5.1 上调用，不表示新增 GPU 认证已通过**。空间 FIR 和光谱积分仍保留原版 Double CPU，尚未实现 Metal 等价/已验证 GPU 加速。

## 44. 从解码前就拒绝超内存的大图

9. `Build91PhysicalMemory.swift` 以完整 UInt64 几何建立不分配大图的计划。六档：1MP 1000×1000、2MP 1600×1250、4MP 2000×2000、7.2MP 3000×2400、12MP 4000×3000、13MP 5000×2600；另外验证 >13MP 的严拒。
10. 相机与相纸扩散使用源本身 `OriginalSourceDiffusion.radius` 计算完整 reflect-pad PSF 和 `powerOfTwo(width+4r)` × `powerOfTwo(height+4r)` Double FFT 网格。精确沿用源 512,000,000 字节 FFT 硬门槛；即使设备物理内存有富余也不得缩小原 PSF、做窗口 FFT 或偷换 GPU 浮点。
11. 精确统计 Double FFT 四个复数 FFT planes、行列 scratch 和三通道 PSF，和基于主帧/film grain/halation/scanner glare/lens 的 BPP 内存开销合成最大峰值。两个 source FFT 是不同阶段依序执行，不能把两套完整工作区错误地相加。
12. 13MP 元数据尺寸上限仍独立于实际能否分配；8GB 模拟物理容量下 13MP 的基础 1560MB 超过原版 1500MB 进程硬门槛而拒绝；受限进程 headroom 要求 80% 余量，7.2MP 启用全部原版颗粒 + halation + XYZ glare 必须提前拒绝。
13. 生产 `OriginalSourcePhysicalImage.validateMemoryBudget` 已改用同一 planner，在 `developInPlace` 与 `exportPhysicalJPEG`／`exportPhysicalOriginalFile` 解码前均传入真正启用的摄影 RAW 和相纸 RAW 扩散参数。不静默缩图、禁用颗粒或回退快速 LUT；已有用户明确选取安全尺寸机制保留。
14. `Build91MemoryProductionDiagnostic.swift` 与 `ContentView` 附录：实时 iPhone 可分配内存、六档无分配预检、YVV GPU cache hits/compilations 均**分开显示，不增加原8/8认证数**。该代码编译不等于已在实机执行。
15. [1–13MP 六档原版内存测试](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43690710141)：**PASS**。纯数字预算，不是 13MP 真正执行，不能用估计数代替 iPhone 实际内存高水位。

## 已验证与未验证状态

| 模块 | 证据 | 状态 |
|---|---|---|
| CPU Double 2D PSF/FFT scratch | 108 原版完整小幅图 + 2 幅旧新版逐值比对 | **数值等价**，分配复用已接生产 |
| CPU Double SIMD/Accelerate | 尚未开发实际数值等价的统一 vectorized pipeline | **尚未移植** |
| Metal IIR pipeline-state cache | 源码合并、iPhoneOS 编译／设备诊断待实机运行 | **优化已实现，未做实测 GPU 性能认证** |
| GPU Float32 相对原版 Double | 已有历史 GPU 基线，不等于本轮新加速科学证明 | **待独立真实设备验证** |
| 1/2/4/7.2/12/13MP 大图内存 | 六档 UInt64 dry-run + 源 FFT 约束 | **预检等价**，非实机 RSS |
| 12/13MP 真正原版颗粒/光晕/FFTs | 未执行 iOS16.5.1 全幅连续链 | **未认证** |

工程路线推进到了 44/47 的工作位置并不表示 42–44 三项全部验收。**45–47（Build92）必须有 Python 分阶段 full-frame source tapes、真实 iPhoneOS GUI 回归和同 SHA Release，不能以此 CI 推导科学认证或发布 IPA。**
