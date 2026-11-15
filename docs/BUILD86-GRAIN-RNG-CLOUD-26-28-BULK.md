# Build86｜原版 Numba 并行随机、染料云、完整颗粒链｜批量阶段报告

基线：Build83 C-R1 → Build84 第一／第二组合批 → Build84–85 21–25。
当前开发分支：`port/build86-grain-rng-cloud-endtoend-bulk-26-28`。
源版本仍锁定 `andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`。**未重新定义原版基准。**

## 本次实际源码更改

1. `OriginalSourceNumbaFastCounts.nextMicrostructureNormal`：新增**同一原版单线程 MT19937 状态**继续抽样入口。
2. `OriginalSourcePhysicalGrain.apply`：启用 `useFastStats` 后，九亚层原版 Numba Poisson/Binomial 消耗完的 RNG，连续传给后续 `fast_lognormal_from_mean_std`，不再重新 `seed`；不启用 fastStats 时，保持原有独立受控 micro seed 行为。
3. `Settings.validate`：fastStats 与后续 micro 的线程种子若不同，显式抛错而不是生成“看似相近”的纹理。
4. `generate_source_faststats_grain_build86.py`：从固定上游未改写 `grain.py`、`fast_stats.py`、`fast_gaussian_filter.py` 生成 5 幅真实源 3×3 颗粒全幅。
5. `Build86SourceNumbaGrainValidation.swift`：编译并直接执行实际 Swift 源颗粒代码，对比 5 幅 × 4 tap（九亚层密度、染料云、微结构、末端显影）；检测原版 0.05 micro 激活阈值、两种卷积、无染料云、种子重放与缺失种子拒绝。
6. `Build86BulkProductionPathDiagnostic.swift`：真实 `OriginalSourcePhysicalImage.develop` 生产入口的整图自检，覆盖自定义 H-D/DIR、DIR inactive、DIR 零空间、单层／多层 SciPy 和九层受控 Numba 颗粒后再进入原版光学印相和扫描。它是**真机可执行诊断代码**，不等于本轮已实机执行。
7. `ContentView.swift`：将生产诊断接入原有 8/8 检测的**附录**；不虚构 9/9 或多一项科学认证。
8. `build86_original_unseeded_numba_audit.py`：针对上游**真实无种子**的 1／2／4 线程 Numba 原函数做多轮随机采样、统计矩和哈希独立性观测。它**不对 iOS 做数值等价宣称**，只是构建原版随机分布基准。
9. `build86-grain-rng-fullframe.yml`、`build86-numba-unseeded-source-audit.yml`、`build86-grain-rng-iphoneos-compile.yml`：分别进行源颗粒逐阶段数值、原版并行分布只读审计，以及合并 iPhoneOS arm64 无签名编译。

## 确认的数值验证

- [Build86 受控颗粒 CI run 43677118565](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43677118565)：**PASS**。
- 5 幅独立执行的源 Python 胶片全幅、20 组 tap，共 **6,930 个 Double 通道**：最大绝对误差 **`5.551115123125783e-15`**，验收门限 `1e-10`。
- 关键样本：源 FIR、YVV、空间染料云关／开、微结构阈值上下、随机数连续消耗、seed=8888 逐像素可复现。
- 前序 [Build84–85 合批 iPhoneOS build run 43676622579](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43676622579) 已通过，证明此前 21–25 合并编译无错误，但**不能替代本 Build86 编译与实机测量**。

## 待进一步认证

| 路线条目 | 当前状态 | 原因 |
|---|---|---|
| 26 原版无种子 Numba 多线程 prange | 近似实现／尚无等价证明 | 当前 Swift 受控单 worker 精确；源默认多线程默认流、调度与随机种子未移植 |
| 27 染料云 + 微结构 + 最终滤波 | 数值等价（5 幅受控样本） | 原版 SciPy/Numba 受控源样本已 PASS；不是全部原版参数与大图 |
| 28 四幅及以上独立完整胶片→相纸→RGB | 已有小图源对照，全面认证未完成 | Build86 新增颗粒内部阶段，不能自动声称 8／12MP 和 iOS 真机最终 RGB 已通过 |
| 真实 iOS 16.5.1 完整运行 | 尚未认证 | 本轮源 CI 在 macOS，模拟／真机均不等同于 Python 源全链路认证 |
| iOS 版本与 IPA | 保留 Build83 版本，未发行 Build86 IPA | 等待全组汇总后构建签名或注明未签名身份 |

## 进度解释

进入路线图第 **26–28 / 47** 项，按顺序推进位置约 60%，**不是已认证的功能完成百分比**。
未进行「完整移植 60%」的误导性声明；默认多线程 RNG、RAW 与精确色域、文件 I/O、真机全部仍需要实测和 source-stage evidence。

发布节奏：继续一次多项合并，仅统一构建和出 IPA；不因单项 CI PASS 发布。
