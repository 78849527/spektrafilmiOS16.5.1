# SpektraFilm Build104｜源颗粒分支与条件 RNG 原版行为

**基础提交**：Build103 `46f1bbc236906aad0c0906d4533f4788fed0c946`。
**工作项**：路线图 23–27（原版 grain.py 未覆盖分支）。
**原则**：固定原版源 `src/spektrafilm/model/grain.py`，不更改 Python 基线；保留现有全部胶片、相纸、RAW、扫描器和 UI 功能。

## Python 原版对照与更正

1. `grain.py::add_micro_structure` 在 `grain_micro_structure_sigma = micro_structure[1] * 0.001 / pixel_size_um <= 0.05` 时直接保留原密度，不调用 `fast_lognormal_from_mean_std`。旧 Swift `Settings.validate()` 无条件要求 3×3 路径具有 Numba seed，会错误拒绝合法的**微结构未激活 / SciPy 颗粒**配置。Build104 将种子检测放回真实触发抽样的位置：`apply()` 的 `microStd > 0.05` 分支。
2. `grain.py::apply_grain` 在 `sublayers_active=false` 时调用 `apply_grain_to_density`，**不传** `use_fast_stats`；该函数始终走 `scipy.stats.poisson.rvs` 与 `scipy.stats.binom.rvs`。旧 Swift 显式拒绝 `useFastStats=true` 的单层路径；Build104 按源分支忽略该标志、原样执行 SciPy，绝不偷偷改用 Numba。
3. 3×3 `useFastStats=true` 仍必须给显式受控种子，且 `fastStatsSeed == numbaSeed`；微结构实际启用但缺少种子仍显式抛错。原版默认无 seed 多线程 `prange` 仍未认证，不虚称该更正解决了随机等价。

## 新增回归覆盖

- 现有 36 个来自原版 Python `grain.py` 的单层及 N 层数值参考：`ios/tests/Build85OriginalSingleLayerGrainValidation.swift` 现在对每组同时测试 `useFastStats=false/true`，源阈值 `2e-8` 不变。
- 既有 3 幅源 `grain.py` 3×3 完整阶段参考：`ios/tests/SourcePhysicalGrainValidation.swift` 新增对两幅微结构阈值以下图像的无种子结果复核；阈值以上保持拒绝无种子。
- `ios/tests/SourcePhysicalGrainParity.swift` 将无种子失败案例改为真实进入 `microStd > 0.05` 的渲染路径，避免以前在不知像素间距时误拒绝。

## 实际状态与发布边界

这是一批**实际生产源算法分支修正及验收测试更新**，不是完整颗粒链新认证。尚未得到本批独立 CI/Xcode iPhoneOS 构建、iOS16.5.1 真机数字证据，不发布 IPA、不调整版本号。下一步合并更多源缺口后统一编译，并从用户上传的 Build103 真机 JSON 修第一个超过源门限的阶段。

原版 3×3 多线程无种子 `prange`、完整 13MP 内存与 RAW 全链路仍未认证。不得因本次条件分支修复将模块升级到“数值等价”。

## 追加批量验证（Build104 同批）

- 修复 `sublayers_active=true, use_fast_stats=true, microStd <= 0.05`：仅必须提供 `fastStatsSeed`，不应强制微结构 `numbaSeed`。当 `microStd > 0.05` 时，须在采样前验证两者同种子、连续流；禁止先抽样后发现种子错误。
- 原版 `grain.py` 的 3 个 SciPy 小图基准不变，新增 2 个调用未修改原版 `grain.py` + `fast_stats.py` 的 Numba 单线程受控源码基准（微结构关闭 / 启用）；对 4 个颗粒中间阶段分别进行 Float64 全元素对照。
- 新增 GitHub Actions Build104 独立 macOS Source Grain 5 图数值检测 + Linux 原版 36 张单层 SciPy 数值检测，及 Swift 解析检查。流程完成前仍不宣称本批 CI PASS、iPhoneOS 完整应用构建 PASS 或发新 IPA。
