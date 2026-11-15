# Build89｜原版输出色域 + 输出空间 38–39｜合批开发与认证记录

基线：Build88 `port/build88-scanner-spectrum-glare-optics-35-37-bulk`，提交 `5608ba79276d39c6bac40d5dbabdba990f15c0c8`。本分支 `port/build89-output-gamut-space-38-39-bulk`。

算法唯一标准：`src/spektrafilm/utils/gamut_compression.py`（Git blob `9783e7fcfc2909c4acdf2da53595c5404645dde9`），依赖 colour-science v0.4.6 的真实 CAM16／Colour RGB 矩阵，原版 `OutputGamutCompressSpec` 默认 `cam16ucs`。

## 本批实际改动

1. `Build89OriginalCAM16.swift`：源 CAM16 (XYZ↔Jp'ap'b') 的前向／反向 CPU Float64；L_A=64 cd/m²、Y_b=20、average surround，CAT16 与锥体适应，不做 LUT RGB 插值。
2. 原版每输出空间的 `64×720` `Cmax(Jp,h)` 网格／18 次二分查找，按需计算和缓存相同的精确表节点，不改为 33³ Float32 图像 LUT。
3. 原版 one-sided lightness `(0.7,1,2.2)` 及自定义阈值、limit、power，在 Cmax 查表前应用；禁用 lightness 时不额外修正高光。
4. `Build89OriginalOutputGamut.swift`：六种算法原版枚举：`off`, `aces_rgc`, `cam16ucs`, `oklch`, `oklrab`, `jzazbz`。前 3 条精确 CPU 源路径可选；后 3 条**尚未移植**，显式报错，不冒称完整或偷换为 ACES。
5. 原版 ACES-RGC 完整用户自定义 knee (threshold/limit/power) 和 achromatic envelope；source `ach<=1e-12` 保留原始负片/黑场分支。
6. 原版 `off` 完整输出线性 RGB，保留低于零和高于 1 的数值，不夹断。
7. 参数校验完全遵循 `OutputGamutCompressSpec.__post_init__`：阈值 [0,1)、limit>0、power>0；不自创 limit>threshold，也不替换失败输出。
8. `generate_scanner_reference.py`：为 sRGB、Display P3、ITU-R BT.2020 导出原版色度白点及 RGB↔XYZ Float64 矩阵，拓展 D65 光源，并保留 D50/K75P 的已有扫描适应矩阵。
9. `SpectralPhysics.sourceSpatialXYZToRawLinearRGB`：从真实光谱 XYZ 输出未经任何色域压缩的线性 sRGB，供精确源模式使用。
10. `OriginalSourcePhysicalImage.Parameters.sourceOutputGamut`：生产 pipeline 明确选择原版 `off/ACES/CAM16`；nil 时保留既有 Build88 视觉输出／移动快速模式不变。
11. Full-frame 真正串联胶片 DIR/颗粒、原版相纸／光学扩散、81nm XYZ、黑白参考、Numba 受控眩光、逐像素 output gamut、扫描镜头 Gaussian/Unsharp 和 Colour CCTF，避免在已编码 RGB 上压缩色域。
12. 生产入口仅允许输出 sRGB JPEG；数值可对照 Display P3／BT2020，但在原版 ICC/宽色域文件导出未认证前**显式拒绝冒充 sRGB 输出**。
13. `Build89OutputGamutProductionDiagnostic`：实际小幅 RGB（7×5）运行 source OFF、ACES、自定义参数、CAM16、高光／CCTF、BW+XYZ glare+镜头顺序、固定种子回放及 ICC 拒绝路径；已编写的自检不等于已在 iPhone 真机运行。
14. 不能调用现有 `OriginalCAM16Gamut.compress` 的 33³ Float32 近似：其测试范围外采用 ACES fallback，不能作为默认原版准确度证据；现在新的原版精确 source route 全程使用新生 Float64 模型。

## 已验证的原版数值证据

- [真实原版 CAM16 216 组](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43683821720)：**PASS**。sRGB／Display P3／Rec.2020、4 种原版 knee/lightness 设置，Float64 CAM16 前向最大 `3.077538224260934e-13`，反向 RGB 最大 `4.218847493575595e-15`，完整输出 RGB 最大 `1.8207657603852567e-14`。真实 source 64×720×18 网格作独立计算，而不是复用 Swift 源值。
- [真实原版 ACES/OFF 126 组](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43683561713)：**PASS**。负值、超白、自定义 knee、关闭 chroma／lightness 参数；最大 `4.440892098500626e-16`。
- 合计 **342 组原始 Python 数值参考**；不是 342 张完整 iPhone 12MP 图像。

## 尚未完成、不可虚报

- `oklch/oklrab/jzazbz` 的原版色貌转换及各输出空间 Cmax 数值对照仍须移植，本批对它们显式失败。
- sRGB 以外的原版真实 RGB/ICC/EXIF 和 JPEG/PNG/TIFF 宽色域文件导出尚未完成；只完成色域数学与矩阵验证，不能写错 ICC。
- CAM16 CPU Float64 大尺寸运行开销、Cmax 缓存高峰、摄影样本 8/12MP 原版全图、iOS16.5.1 实机数值认证未完成。
- 受控 Numba 单 worker 的精确数值不等于原版无种子多线程分布/调度认证。
- 现有 Build83 v1.8.58 身份不变；源分支已修改 ≠ 已签名、已发布 Build89 IPA。
- 路线图进到第39／47项只是工程工作位置，**38–39 未全部科学认证完成**。

## 合并构建

Build89 Xcode 16.4 iPhoneOS arm64 只在此批数值测试和源代码合并后集中执行；真正运行结果单独引用工作流、受测 commit SHA 和结论。
