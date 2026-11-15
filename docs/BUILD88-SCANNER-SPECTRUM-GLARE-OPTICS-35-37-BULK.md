# Build88｜原版扫描光谱 XYZ、Numba 眩光、镜头与锐化｜35–37 合批

**源基线**：`andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`。原版 Python 函数必须由源码 AST 执行且 SHA/Git blob 锁定；Swift 侧使用实际生产核心，不以假高斯或 Core Image 替代。

**开发分支**：`port/build88-scanner-spectrum-glare-optics-35-37-bulk`。
**基线修复**：Build87 最终 Xcode 16.4 compile run `43680411412` **失败**，精确定位 `OriginalSourceDiffusion.swift:132` 类型检查超时。已仅将原本求和表达式分拆为显式 Float64 局部变量，两个分支同步修复，未改变数学公式。Build87 旧失败不能标为成功，**需 Build88 全量再次编译才算最新链路通过**。

## 本轮实质移植

| # | 源能力 | 本轮实际生产变更 | 验证范围 |
|---|---|---|---|
| 35.1 | 81 波长实测染料和片基密度 | `Build88OriginalScannerSpectrum`：81 × 3 Float64 CMY 光谱、每材料 NaN 波段掩码、CIE 光谱 XYZ 积分 | 8 相纸 + 4 正片 × 4 实测 H-D 密度档（源级测试） |
| 35.2 | 源 `np.log10(np.fmax(XYZ,0)+1e-10)` | `SpectralPhysics` 完整 Float64 光学扫描入口恢复扫描端 `10**log_xyz`，旧快模式不变 | 原版黑场 +48 密度 |
| 35.3 | 查看光源和适应 | 保留 D50/K75P 81 波长、真实 CIE 1931 2° 及 viewing XYZ 色度适应 | 12 库存原纸/正片 |
| 35.4 | 色域前的精确颜色转换 | `OriginalScannerMath` true XYZ→linear sRGB→ACES-RGC；非源码默认 CAM16 等价宣称 | 实测 RGB 各 tap |
| 35.5 | Colour RGB_to_RGB(sRGB→sRGB) | `generate_scanner_reference.py` 产出原版 **非单位** Float64 3×3 转换矩阵；`OriginalScannerMath.sourceCCTFEncoding` 在编码前完整执行矩阵 | 修复源已观察 sRGB 约 2.27e-5 漂移 |
| 35.6 | source 输出 CCTF 开关 | `Parameters.sourceOutputCCTFEncoding`：true 为源 3×3+CCTF，false 保留曝光和色域之后的 **线性 RGB**；印相扩散和正片直扫两条分支统一处理 | App 真实处理链诊断已编写 |
| 36.1 | 原版扫描器 glare in XYZ | 光谱 XYZ（已完成黑白 Y 校正）→原版单线程受控 Numba→Gaussian FIR/YVV→叠加归一化扫描光源 XYZ→linear RGB | 64 幅源 RGB/XYZ 前半阶段 |
| 36.2 | 黑白校准＋眩光同时启用 | Build87 不允许二者组合；Build88 仅在完整原版 Float64 prepared Y 参考就绪时开放，保持原源码运算顺序 | 4 组 B/W 开关 × 光学场；不可与旧近似校准混用 |
| 36.3 | zero-roughness RNG | 原版 `fast_lognormal` 的 `sigma<1e-6` **不抽任何 Numba 正态随机样本**。放宽此特例可不提交 seed，真正随机场仍强制显式单线程 seed | 0 roughness + percent120/blur110 原版对照 |
| 36.4 | Glare 参数覆盖 | 去除非源码百分比、粗糙度、模糊半径 ≤100 的人为上限；NaN/Inf/非法输入继续报错 | 大于100 的实测 fixture |
| 37.1 | scanner lens Gaussian | 全幅真实 FIR(<3)/YVV(≥3)，反射边界，允许原版 σ>50；负 σ/0 不调用 Gaussian | 60 幅源 RGB 输入/中间 tap |
| 37.2 | unsharp amount | source `rgb+amount*(rgb-fast_gaussian_filter(rgb,sigma))`，允许 amount>2；sigma≤0 或 amount≤0 的源分支无动作 | 60 幅原版边界与中间 tap |
| 37.3 | 原版输出顺序 | 扫描光谱→B/W XYZ→glare XYZ→XYZ→ACES 线性 RGB→镜头滤波→反锐化→可选 CCTF | `Build88ScannerCombinedProductionDiagnostic`（App 端自检代码，尚非执行记录） |

## 本轮固定来源校验

- [Build88 原版 60 幅扫描镜头滤波](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43680835221)：**PASS**。使用真实 `diffusion.py` 与 `fast_gaussian_filter.py` 原始函数 AST，对比 `OriginalSourceScannerOptics.swift` 生产 Double。
- [Build88 原版 64 幅扫描黑白→Numba 眩光](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43681488804)：**PASS**。Python `ColorReferenceService.black_white_xyz_correction`、`glare.add_glare`、受控 Numba 单 worker，黑白阶段最大绝对误差 `5.551115123125783e-16`，最终 XYZ 最大 `1.687538997430238e-14`。
- [Build88 12 原材质×48组 81nm/XYZ/ACES/CCTF](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43681587759)：**PASS**。真源完整 CIE 波长掩码、D50/K75P、`log10`→`10**`、Colour 同空间 3×3 矩阵；XYZ 最大 `6.661338147750939e-16`、线性 RGB 最大 `1.3322676295501878e-15`、ACES 最大 `1.3322676295501878e-15`、最终 CCTF 最大 `7.771561172376096e-16`。
- 在开发中定位源色彩差异：源 `colour.RGB_to_RGB(sRGB,sRGB)` 的 identity-roundtrip 并非逐元素精确 1，曾见 sRGB 通道误差约 `2.27e-5`；现已移植源矩阵而非扩大误差容限。
- 全量 iPhoneOS 编译和 iOS 16.5.1 真机逐 tap 测试是两种不同认证。未生成 IPA、未签名、未发布 Release。

## 源范围状态说明

- **数值等价**：仅上面列出的真实源码 AST、给定种子/尺寸/档位的原版 Float64 样本。
- **已接生产路径但未设备认证**：Black/White + Glare + CCTF开关、12 实测 81nm、正片/负片扫描拓扑、App 内自检。
- **近似实现/尚待移植**：Python 原版 `Numba prange` 无固定种子多线程调度/分布全面验证；默认 CAM16-UCS 逐像素算法（目前 source 支持 ACES-RGC 可选分支）；高位深/RAW 整链及 8/12MP 真机/峰值内存。
- 没有把默认 CAM16 偷换为 ACES，也没有默默将原版 Double 替换成 Metal Float32。

**进度**：路线图现已推进到 **37 / 47 ≈ 78.7% 的工程工作项顺序位置**；这不是任何意义上的“原版科学认证完成 78.7%”。Build88 35–37 条目须待最终源码/tap/编译/真机审计才能逐条标记全部完成。后续 Build89 是 38–39 默认 CAM16 全参数及多算法输出色域。
