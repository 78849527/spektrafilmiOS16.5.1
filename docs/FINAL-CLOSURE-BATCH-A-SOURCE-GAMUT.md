# Final closure engineering batch A｜Build108 源精确模式补线（非正式认证）

基线：`b02e2773f07d913e101bd3dcdc5d0c709b74dc77`，按 47 项路线图 03/16/38 进行集中补线。

- 原版输入 Oklch：移植 Python `gamut_compression.compress_oklch_chroma` 的 xyY→Oklab、64×720 Cmax、18 二分、双线性插值与 Reinhard knee。更改 `Build81OriginalInputGamut` 可选算法，默认 xy 不变。
- 原版 CAM16-UCS：在“逐像素全光学”原版模式中增加显式 opt-in 的原版 `OutputGamutCompressSpec`（CAM16-UCS、sRGB、lightness knee）；调用已经单独通过 Python 216 条原版向量验证的 `Build89OriginalOutputGamut`，不使用旧 33³ LUT，原用户默认仍保持关闭。
- 严格保留 iOS 16.5.1、历史快模式/原版直连与 UI，不自动调整种子、精度、内存预检或者广色域输出。
- 新旧 Oklch/CAM16 在生产集成后仍需要 **iPhone 真机 + Python 源逐阶段图像** 证据，未达到路线图 16/38 的“完整移植”。
- 仍未解决 P0：RAW/rawpy 镜头、EXR/ICC/XMP、默认无种子多线程、13MP Jetsam、真实 GUI 12 项。

该工程批次不构建 IPA，先生成独立 Python oracle + Swift 数值对照及完整 iPhoneOS 类型检查，合并剩余 P0 后集中构建。
## 后续补线：原版 Oklch 实际生产路径

- 仅在明确开启新 Oklch 控件时，`OriginalSourcePhysicalImage.Parameters.sourceInputGamutAlgorithm=.oklch`。
- `SpectralPhysics` 重新计算 192×192 Hanatos Float64 光谱 TC LUT；`Build82OriginalSpectralRuntime.bakeOriginalXYGamut` 使用数值已通过的原版 Oklch chroma compressor，之后原样按照源 LUT 反射索引/双线性采样。
- 默认 `.xy` 无参数变化；Mallett 路径明确拒绝 Oklch（不回退）；不触动固定颗粒种子。
- 独立 Python Oklch 96 通道最大误差 `2.79e-14`，原版 CAM16 216 案例最大输出误差 `1.87e-14`。
- **未完成**：实际 LUT 全表 Python 对照、UI iPhoneOS 编译与真机整图；因此不能宣称“完整原版输入压缩移植”。
