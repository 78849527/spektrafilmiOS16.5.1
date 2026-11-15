# Build84 / 21–22 第一组合批：胶片 H-D 与 DIR 化学／空间开关

- 基点：Build83 C-R1，`8b47a5fef639787e473c91fc51a47263f5a3423c`。
- 工作分支：`port/build84-hd-dir-chemistry-spatial-21-22-batch1`。
- iOS 最低版本保持 16.5；本批**不修改**营销版本号或 Build83 IPA。
- 上游 Python 合同：`src/spektrafilm/model/{couplers,density_curves}.py`、
  `src/spektrafilm/runtime/params_schema.py`、
  `src/spektrafilm/utils/fast_interp.py`；全部 Git blob 在 oracle 内锁定。

## 本批实际改码

1. 新增 `Build84OriginalFilmDIR.swift`：
   - DIR 3×3 同层／层间参数矩阵，原版 donor 行 → receiver 列，支持 `amount` 和单独两种 inhibition 权重。
   - `normalized_density_curves = curves - channel_min` 的有限 Float64 子集。
   - 正片银密度 = `D_max - D`，负片银密度 = `D`，可复现原版 high-exposure shift 分支。
   - `compute_density_curves_before_dir_couplers` 的逆向横坐标与正片变号、逐通道 `np.interp`。
   - `fast_interp` 逐通道 gamma、越界端点延伸、重复节点 right-biased 查找。
2. `OriginalSourcePhysicalImage.swift` 生产路径已接入真实 `Build84OriginalFilmDIR.inhibitors`；**默认开关为原路径**，不改变已有启用源 DIR 的用户行为。
   - `sourceCouplersActive=false`：DIR 完全关闭，显影直接使用未经 DIR 修正的原版胶片 H-D。
   - `sourceSpatialDiffusionEnabled=false`：保留 DIR 化学抑制与校正前 H-D，但完全跳过 FIR/YVV；与源 `diffusion_size_um=0` 的短路语义对应。
   - 默认 `true/true`：原始已移植 FIR/YVV、三高斯指数尾和整图边界算法保持原封不动。
3. `SpectralPhysics.swift` 新增可用于实际生产的非 DIR H-D 路径，拒绝 NaN/Inf。
4. `build84_original_film_dir_oracle.py`：检查上游四份 Git blob 后，从原始 Python AST 直接执行源函数体，并生成科学参考 JSON。不是凭视觉样本定义“等价”。
5. `Build84OriginalFilmDIRValidation.swift` 与 `build84-film-hd-dir-parity.yml`：
   - 原始 Python 正/负片与 Swift 对照：矩阵、校正前曲线、曝光 gamma、左右端点、银密度、high shift。
   - 重复横坐标右侧命中与独立负片子层最小值归一化。
   - Linux Swift `-parse` 检查完整 App 源码，单独编译及运行 CPU Double 数值内核。

## 状态与限制

| 子项 | 状态 | 条件 |
|---|---|---|
| 源 DIR 矩阵、H-D 插值与校正前曲线 | 数值等价（有限样本） | Ubuntu 24.04、Swift 6.4.2 / NumPy 2.3.5；5×3 曲线、2 种片型；门限 `2e-12`，实测最大误差 `4.44e-16` |
| 正负片银密度、非空间 DIR | 数值等价（有限样本） | Python AST 与 Swift 对照最大误差 `3.33e-16`；生产分支已接线，尚无 iOS 真机整图认证 |
| 原本已存在的全帧 FIR/YVV | 保留原状态 | 本批没有替换核或悄悄切换 CI 近似 |
| 全原版功能闭环 | 尚未完成 | 所有 256 节点真实胶片曲线、多种 sigma、相纸/随机颗粒整图、UI 显示与 iPhoneOS 构建仍需独立验收 |

**特别说明：** high-exposure shift 已在纯 Float64 原版算法里实现并对照，但 Python `apply_density_correction_dir_couplers` 默认不传它，因而**不能**宣称 iOS 生产已支持该自定义参数。两个新源开关目前是程序层参数，未加入主菜单或用户设置。

## CI 与发布

- 数值 CI **PASS**：`https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43672703876`，对应已验代码提交 `28d56e3b9f2adaefa6ab4812b9de131568fbe694`。本文件仅新增说明，不改变该次已验代码。
- 本批**不构建 IPA**。需要等后续 Build84 功能组一起通过 iPhoneOS、真机及 Release 认证才可能发布。
- Build83 C-R1 完整保留，未覆盖或合并到 `main`。
