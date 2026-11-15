# Build84 第二组合批｜20 款实测 H-D + 原版 FIR/YVV + 完整 DIR 数值闭环

**起点：** `port/build84-hd-dir-chemistry-spatial-21-22-batch1`，继承 Build83 C-R1 已验证功能。目标 iOS 16.5.1（Xcode 工程 deploymentTarget `16.5`）；**未构建 IPA、未改变 Build83 版本号**。

## 实际移植

- `Build84OriginalFilmDIR.stockMatrix`：逐字对照源 `runtime/params_builder.py::_apply_film_specifics` 的负片、普通正片、Provia 100F、Velvia 100 同层/层间耦合系数；支持 `amount` 与独立 inhibition 权重。此前的 `GeneratedDIRData` 实际生产预设保持原样。
- `SourceSpatialDIRConvolution.exponentialFitted`：补齐源 `utils/fast_gaussian_filter.py::fast_exponential_filter` 的 **2 高斯**分支，同时保留原来的 **3 高斯**低内存生产算法；逐通道 decay、0 sigma、reflect FIR、小半径和大半径 YVV IIR 均保留。没有改用 CI 模糊或缩图。
- 继续保持已接线的原版 `sourceCouplersActive=false` 及 `sourceSpatialDiffusionEnabled=false` 两个生产参数分支（前者使用未经 DIR 的 H-D；后者只跳过空间扩散，保留 DIR 化学）。

## 独立 Python → Swift 验证

- `build84_real_stock_spatial_oracle.py` 从源 `model/{couplers,density_curves}.py`、`runtime/params_builder.py`、`utils/{fast_interp,fast_gaussian_filter}.py` **实际提取执行 Python AST**。保持同版 NumPy `float64`，以 no-JIT 解释执行 Numba 内核原始函数体（不是自己重写算法参考）。
- 共 **34 份固定 Git blob SHA**：全部 28 份实测 profile JSON + 6 份 Python 算法/参数源码。任何源码或实测资料偏离自动报错。
- 20 款实际 filming profile，每款 256×3 实测节点、相应原版 DIR 参数、正负片分支、逐通道 gamma、端点及曲线校正；合计 **15,360** 个预 DIR 密度节点。
- 空间卷积 **40** 组：1×1、1×7、7×1、3×5、8×6，sigma=0、0.2、1.2、2.99、3.0、7.25，两个指数近似分支，三通道不同 decay。
- 完整 DIR **12** 组：两种片型；单像素宽/高、空间关闭、FIR↔YVV 临界、指数尾不同权重。逐像素的 H-D → silver → donor/receiver → spatial filter → log exposure 修正与 **Python `compute_exposure_correction_dir_couplers`** 实际计算结果比较。
- 编译使用未改写的生产 `SourceSpatialDIRConvolution.swift` Double 核（只通过既有脚本剥离 Linux 不支持的 CI 桥接），无模拟替代算法；同时对全 App Swift 源码执行语法解析。

### CI 实测（已通过）

CI：**[run 43674155765](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43674155765)**，受测 SHA `fca762ca0a5b7aff85cd7ec092d43e737fef839c`。

环境：GitHub Actions `ubuntu-24.04` x86_64 / Swift 6.4.2 / Python 3.12.3 / NumPy 2.3.5。误差为 **绝对值**，非视觉评分。

| 测试 | 门限 | 实测最大误差 | 当前状态 |
|---|---:|---:|---|
| 20 胶片的 H-D、256 节点、DIR 矩阵及 gamma | 2e-11（矩阵 2e-12） | 5.3291e-15 | 数值等价（上述测试范围） |
| 40 组原版 FIR/YVV + 双/三高斯 | 3e-9 | 1.3878e-15 | 数值等价（上述测试范围） |
| 12 组完整 DIR 反应与扩散 | 3e-9 | 4.6074e-15 | 数值等价（上述测试范围） |

## 尚未认证与开发边界

- 当前验证均在 Linux CPU Double；**未做 iOS 16.5.1 实机整图、内存、预览/导出和 iPhoneOS 编译认证**，所以不得标记 Build84 完整移植或发布正式 IPA。
- 生产路径沿用已有原始胶片测量和 `GeneratedDIRData`，本批未动态重算用户自定义参数的校正前 H-D，也未把双高斯选项挂入 UI；这两项仍不得宣称为用户可用功能。
- `high_exposure_couplers_shift` 上游实际默认传 0，本批未擅自修改生产默认值。
- 验证本身不改变原版 3-gaussian 默认滤波或移动快速模式，不覆盖 Build83 C-R1。

## 后续集中验收

完整原版 `DirCouplersParams` 自定义参数 → 动态校正前 H-D 的生产级闭环、更多真实 2D 镜头图样、真机全图随机颗粒交互对照，再决定集中一次 iPhoneOS 编译/IPA。
