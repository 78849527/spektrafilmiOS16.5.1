# Build87｜29–34 原版光学放大机、相纸 H-D、空间扩散、黑白参考｜合批报告

**工作基线**：Build86 完成时的 `port/build86-grain-rng-cloud-endtoend-bulk-26-28`。
**开发分支**：`port/build87-print-optics-reference-29-34-bulk`。
**唯一原版**：`andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`，全部 Python AST 测试以原文件 Git blob SHA 严格校验。
**版本身份**：保留原 iOS 16.5 最低兼容和 Build83 v1.8.58 身份；本分支暂不冒称 Build87 IPA，未签名、未发布 Release。
**计数法**：推进到路线第 34／47 项只等于顺序位置，**不等于 72% 的全量源码/真机科学认证**。

## 本轮代码实际覆盖的功能（12 大类）

| 原版模块 | 完成的本轮修改 | 生产/验证状态 |
|---|---|---|
| 29 负片光学印相及正片直扫 | 继续沿用源负片→纸张及正片直扫各自拓扑；正片黑白参考倍率作用在胶片 photon 显影前 | opt-in 生产路径已接线；真机未执行 |
| 30 两种放大机光源与镜头 | TH-KG3 / TH-KG3-L 现有 81nm 光谱能力保持；数据库覆盖遵循源规则 | 依赖原已移植数据 |
| 30 自定义中性滤色片 | `OriginalPrintOptics.Settings` 增加 C/M/Y 三原版独立 neutral；保留数据库启用开关 | 实际光谱生产入口 |
| 30 CMY 滤镜范围 | 移除 iOS 非原版的 ±100 CC 参数上限，仍拒绝 NaN/Inf | Python 原版验证 |
| 30 预闪光范围 | 移除 iOS 非原版 preflash≤1 的上限，仍拒绝负曝光与非有限值 | Python 原版验证，预闪光最高 1.2 |
| 30–31 midgray | 保留源四种 `normalize_print_exposure` × `print_exposure_compensation` 模式；与原版 81nm 测试结合 | 96 种真实胶片/相纸光谱条件通过 |
| 31 印相 raw spectral | 实测 film CMY、片基缺失波长掩码、81nm paper sensitivity 与 10^(-density)、预闪光 photon 光谱积分；纸张 logRaw | 96 组 Python→Swift 对照通过 |
| 32 反射 FFT 退化尺寸 | 修复 `OriginalSourceDiffusion` 原来误拒绝 1×1、1×N、2×N 的支路；建立周期性 np.pad(reflect) 映射 | 108 组源 2D RGB 图像通过 |
| 32 四类 PSF 特殊参数 | 所有三组 intensity=0 时，按源 `_resolve_family_cfg` 恢复**所有**默认 size；极小 spatial_scale 在径向核中按源 ≥1e-6 处理 | 原版 PSF/FFT 双对照通过 |
| 33 纸张 CDF / morph | `OriginalPrintMorph.Settings.valid` 移除不存在于原版的 Gamma≤3；保留 sigma floor、fast/slow/red/green/blue、exhaustion 与正/负片极性 | 8 种相纸×2 极性×10 参数完整 256×3 数据通过 |
| 34 负片黑白曝光参考 | `Build87OriginalColorReference` 使用原版未经 morph 的实测纸张 256×3 H-D，分别反演黑/白、中灰光子倍数；实际处理路径印相之前校正 photon | 96 组源参考数学验证通过；生产 opt-in |
| 34 扫描 / 正片黑白校准 | 黑、白、同时、关闭四路独立开关；用原版 Y slope/intercept 在 XYZ 阶段校准；正片摄影 exposure factor 在显影前，提供生产链诊断附录 | 96 组 CPU Double 数值验证；不计入原 8/8 设备诊断 |

## 最新 Python AST → Swift Float64 科学测试

本批 **四个独立 GitHub Actions**：

1. [黑白/正负片参考源测试](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43679683082)：源 `ColorReferenceService` 的 12 份真实材料、96 组开关与黑/白测试，**PASS**。
2. [放大机 81nm 光谱](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43679795550)：96 组真实负片→相纸组合，四种曝光模式、三种 preflash=0/0.24/1.2，最大绝对误差 **1.4210854715202004e-14**，**PASS**。
3. [相纸原版 256-node morph](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43680042643)：8 份原始 fitted models × 2 极性 × 10 参数，122,880 个曲线节点；最大误差 **7.458131889848119e-10**，插值最大误差 **2.8743496471861363e-10**，门限 3e-9，**PASS**。
4. [全部四家族 2D Python PSF/FFT](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43680239231)：108 幅原版源代码真实 `np.pad(reflect)`、`fftconvolve`、PSF，最终图像最大误差 **1.2212453270876722e-15**、PSF 最大误差 **9.992007221626409e-16**，**PASS**。

**已验证 460 组独立来源用例**。注意：相关样本类型不同、包含两种反相测试材料，仅用于分类统计，不能视作 460 幅 8MP 相机实拍图。

## Build87 App 生产路径

- `OriginalSourcePhysicalImage.Parameters.sourceColorReference`，默认关闭，旧路径不变。
- `SpectralPhysics` 使用 `sourceMeasuredFloat64` 的未经修改的 **原纸实测 256×3** H-D，按 Python 原版印相中灰反演的光子倍率计算，不再限幅为 ±4EV。
- 原版负片 reference：film-black（含 source grain.density_min）、film-white、光谱积分、纸张 develop_simple、扫描 source Y、印相曝光倍率。
- 原版正片 reference：原片曲线最大密度/透明白、源曝光 reference、胶片 H-D 前倍率、直接扫描，跳过纸张。
- `SourceSpatialFilmParams` 只允许正式准备的 source reference；不允许旧模拟黑白端点走 source physical。
- 原版扫描 XYZ 白黑修正发生在 XYZ→ACES/gamut→sRGB 之前。
- `Build87PrintScanProductionDiagnostic` 在已有诊断附录中检查：12×10 RGB、独立负片 3 模式、正片直扫、可重复回放和不支持的眩光组合显式失败；此诊断 **尚无本轮真机执行结果**。

## 仍未认证 / 不可冒称

- 全幅 8/12MP 原版每 tap Python→iPhone RGB、CAM16 默认逐像素、动态内存峰值、iOS 16.5.1 真机精确输出仍未完成。
- `printDiffusion` 已做真实小幅 2D FFT，但不能把它扩张为大图无内存限制；超过内存预算仍应显式失败。
- `sourceColorReference` + 原版受控随机扫描眩光组合在未通过数值叠加测试前主动拒绝，未静默输出近似。
- 与 Python 原版不同的未验证输入格式、RAW、ICC、色域和 UI 细节继续作为后续工作；**没有 Build87 IPA**。
- 路线图 29–34 已进入并移植多条主路径，但不将这些标为全部「完整移植」；请区分“源 Float64 指定样本数值等价／生产入口已接线／真机仍待验收”。

## 一次批量编译

此分支在完成源验证后仅集中执行 `.github/workflows/build87-print-optics-iphoneos-compile.yml` 的 iPhoneOS arm64 unsigned app 编译（不发布 IPA）；最终编译是否通过须以**具体受测 SHA** 和 GitHub Actions 结论为准，不能用更早 Build87 中间提交的成功记录覆盖最新提交。
