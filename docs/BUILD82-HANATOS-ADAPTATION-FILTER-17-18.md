# Build82（17–18）：Hanatos 2025 原版感光度适应、UV/IR 与重算 TC LUT

**版本候选：v1.8.57 (82)** · iOS 最低 16.5 / iOS 16.5.1 兼容目标。
**唯一 Python 源基准：** `andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`。

## 真实代码变更

1. `Build82OriginalHanatosSurface.swift`：完整原版四阶多项式 `poly2d_deg4`（c0 不参与计算），Hanika sigmoid/最大 ±2 EV，`_quad2tri`/`_tri2quad`，`_radial_mobius_warp_xy`，原版未变形/扭曲曲面两条计算路径。
2. `Build82OriginalSpectralRuntime.swift`：原始 192×192×81 × Float16 `irradiance_xy_tc.npy` SHA256 校验后，按 Python `np.double(np.load())` 转成 Double；81nm/3 感光通道，通过原版高斯滤波、erf4 截止窗、UV/IR 镜头截止和白点归一化、完整源曝光表面生成新 TC LUT。另含 Build81 所提供的输入默认 xy Reinhard 色域重映射。
3. `build82_generate_profiles.py`：从原版 20 个实际胶片 JSON 中提取 81×3 感光度、4 元窗口、3×15 曲面、参考光源、参考色品；不得用不同胶片数据代替，任何缺项都失败。
4. `SpectralPhysics.swift` + `OriginalHanatosResponse.swift`：新 LUT 仅注入相应计算结果，原本按 stock 缓存的**无滤镜** 192² LUT 不会被用于 UV/IR 或新增曲面结果。
5. `OriginalSourcePhysicalImage.swift` + 编辑器：Hanatos 模式下允许 UV/IR；新增「原版 Hanatos 适应曲面与 TC 全重算」独立开关。兼容原有 Mallett 2019，旧的无滤镜默认渲染暂不改变。iPhone 编译通过不等于已在真机完整验证。
6. Xcode 项目仅附加上游原始 `irradiance_xy_tc.npy` 资源，不重新生成/截断源光谱表；元数据与图像都是 Double 算法路径。

## 源函数和数值对照

`build82_original_hanatos_oracle.py` 对三个原版 `compute_hanatos2025_tc_lut` **原函数 AST** 执行完整 192²×81 光谱积分，包括原版实际 `kodak_portra_400`（无镜头滤镜 / UV0.85 + IR0.65）和 `kodak_vision3_500t`（UV1 + IR1）。按相机镜头带通原版 `model/color_filters.py` 实际 sigmoid erf，使用每胶片真实原始敏感度和原版窗/曝光曲面；另覆盖 source poly4、warp poly4、erf4 波段窗及 SciPy reflect Gaussian。

`Build82OriginalHanatosValidation.swift` 读取**实际源 NumPy 数据文件**和原版 Python 参考，测试三组动态 192²×3 LUT 的多个 TC 位置、原版曲面、镜像 Gaussian 与硬失败边界。容差采用 `3e-8 + 3e-7×abs(Python)` 并报告最大误差；这不是原版完全按位等价标准。

## 未完成或不能冒充完成

- 该 Python 三组 TC 数值参考使用 **gamut_compress=None** 来独立测试 Hanatos 积分；完整色域重映射源函数和 Python 组合参考仍须单独交叉测试。Swift 默认完整重映射已实现但未获得整套 Python 对照，**不能称全链路数值等价**。
- 20 个原版胶片的所有镜头参数组合、非默认 `logiflex8` 光谱窗、非零 spectral Gaussian 的**整幅** LUT 仍需扩增基准。SciPy Gaussian 已有单波长向量校验。
- Mallett 2019 的其他光谱输入、全部 RAW 实机测试、GPU Float32 与 Python Float64 整图对照、iOS 16.5.1 真机完整一致性**不在本批已完成范围**。
- 原版 `gamut_compress.algorithm="oklch"` 仍未移植，严禁静默切换。
- **没有新 IPA 发布**；Build80 的历史未签名实验包单独保留。

[Build82 实际 GitHub Actions 验证](https://github.com/78849527/spektrafilmiOS16.5.1/actions?query=branch%3Aport%2Fbuild82-hanatos-surface-filter-17-18)
