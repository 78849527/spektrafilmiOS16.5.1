# Build105-HF｜Build104 真机报告反馈：源颗粒验证断言修复（无算法变更）

## 真机报告（Build104 v1.8.71，编译 SHA 989d42cf16e1cb2c140a03880fc888972417caa9）

- iOS 16.5.1 真机，Build104 `20/20` 独立 Python 原版颗粒阶段实测 PASS，最大绝对误差 `4.3298697960381105e-15`，单层 SciPy `use_fast_stats` 忽略分支 PASS。
- 同一 IPA 的旧 Build103 诊断只记录首幅 `kodak_neutral_fir` 的 7 核心阶段、各指标数值 PASS，随即因 `Source physical grain accepted implicit unseeded Numba` 中断；`7/28` 不等于 28 全部失败，也不表示原版数值越界。
- 用户报告首错的真实原因：`SourcePhysicalImageParity.swift` v1.8.50 旧负面断言无条件要求 `numbaSeed`。原版 `grain.py::add_micro_structure` 仅当 `microNM * 0.001 / pixelUM > 0.05` 才消耗该 RNG；首幅 12.0 μm，实际 sigma=0.0025，不需该 seed。Build104 源行为正确，旧断言过期。

## 仅修验证，保持原版算法

- 四幅固定 Python 原版：`kodak_neutral_fir` 12 μm、`fujifilm_2383_iir` 4 μm、`kodak_endura_morph` 9 μm 均为非激活微结构：删掉微结构 seed 后，同一生产源 `OriginalSourcePhysicalImage.develop` 全 RGB 位级相等，否则明确 FAIL。
- `kodak_grain_micro_yvv` 0.35 μm、sigma≈0.085714 >0.05：未传 seed 必须原生产源报错，否则明确 FAIL。
- 最后验证固定计数 3 个 inactive 与 1 个 active，严防无条件放行或完全关闭验证。
- 颗粒数学、SciPy/Numba 状态、Python 固定源码、阈值 0.05 和所有真实光学输出均不改动。
- Build103 28 核心数值入口和 Build104 20 颗粒数值入口均保留，再次真机执行两个 JSON 报告以确认恢复 28/28。

## 发布与声明

- Build105 / v1.8.72 是 Build104 的**验证热修复**，不是计划中的 Build105 大图内存模块移植。
- 完整 iPhoneOS arm64、iOS 最低 16.5、`SFSourceCommit` 与 IPA SHA 必须在 CI 真实验证后才上传独立实验版 Release。
- Build104 原版颗粒实测通过 ≠ 全 Python 原版认证：未播种 Numba 多线程 prange、13MP Jetsam、RAW/ICC/元数据端到端仍未认证。
