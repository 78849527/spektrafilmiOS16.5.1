# Build90｜输出格式 ICC 与 PCHIP／Mitchell 原版 LUT｜40–41 合批

基线：Build89b `port/build89b-perceptual-output-oklch-oklrab-jzazbz`，上一批六算法真实 iPhoneOS arm64 编译 PASS。本批分支 `port/build90-file-output-icc-lut-40-41-bulk`，不覆盖上轮已认证 CPU Double CAM16/Oklch/Oklrab/JzAzBz 的数学链路。

算法唯一来源：项目内的 `src/spektrafilm/utils/io.py` Git blob `3c1a8787cac39bd5d3e6652c6e34a111a2565f3c`、`fast_interp_lut.py` Git blob `a98208467c42af5b7661246b4c3409f2945ad3ed`、`lut.py` Git blob `f96342d99fc59b08724930e87e4c16a3387a2c40`。**不是依据视觉相似自行推算。**

## 40：文件输出和源元数据

1. `Build90SourceOutputQuantization.swift`：真正逐值 Source OIIO 规则。JPEG 和 PNG 无视请求位深，均为 UInt8、`clip[0,1] * 255`、**向零截断**，与已有界面 JPEG 使用 nearest-even 的老输出函数刻意分离，避免改动已认证用户流程。
2. TIFF 按源 `bit_depth=8` UInt8、`16` UInt16、`32` Float32，32 位保留超白与负值，失败不自动降成 RGBA8；EXR 数值为 Float16/Float32，原本源函数仍可在缺实际 iOS EXR 编码器的情况下作为纯数值移植，但**无真正 EXR 文件发布**。
3. `build90_original_io_quantization_oracle.py`：通过 AST **直接执行原版** `save_image_oiio` 函数，并使用只记录 OpenImageIO ImageSpec 的测试后端，捕获原版实际数值和 TypeDesc，不另造缩放公式。
4. `build90_generate_original_icc.py`：从原版 `_ICC_FILENAMES` 映射读取仓库原始 ICC 二进制，对 sRGB 编码/线性、Display P3 编码、ITU-R BT.2020 编码/线性 5 种原版源组合生成 Base64+SHA256 Swift 资源。缺 P3 线性原版文件时显式失败，不能拿系统 P3 编码版代替。
5. `Build90NativeOutputWriter.swift`：ImageIO 真实 JPEG/PNG/TIFF8/16/F32 文件，使用原始 ICC 创建 CGColorSpace，保留来源文件可读取的 EXIF、IPTC、GPS，输出新尺寸、Orientation=1、Software=spektrafilm、色彩空间标记；JPEG 0.98 与原界面 98% 输出分离。
6. 首次验证发现 ColorSync/ImageIO 将 sRGB ICC 源 9552 字节重封装为 9436 字节，字节不能相同，不能假装源精确。新增 `Build90OriginalICCContainer.swift`，原始二进制 ICC 在真实 JPEG APP2、PNG iCCP（zlib/RFC1951 stored blocks/CRC32/Adler32）、TIFF tag 34675 容器级重新嵌入；写完**重新解析磁盘文件**，证实 source ICC 原字节完全相同。
7. `OriginalSourcePhysicalImage.swift`：抽出与原 98% JPEG 相同的源全光学导出/内存预估/分辨率预检方法，并新增 opt-in 的 `OriginalSourcePixelIO.exportPhysicalOriginalFile`；旧 `exportPhysicalJPEG` 仍用原来的显示字节转换和相册/Files 分享，不改变现有交互。
8. 真实完整光谱 scanner 当前只输出已验证 sRGB 原始线性值；source Display P3/BT.2020 的纯数学和磁盘 ICC 独立可验证，但尚无等价的全光谱 destination XYZ 转换阶段，因此**完整光学文件输出仍明确拒绝冒用 P3/BT.2020 标签**。
9. 原版 pyexiv2 的全部原生 XMP/IPTC 语义无法仅凭 ImageIO 部分字段移植；**原始 XMP 逐字节/全标签复制未认证**，不得称任务 40 完整通过。
10. iOS 运行时原生 OpenEXR 16half/32float 文件编码、ICC 与外部工具 roundtrip 尚未完成；明确抛出 Unsupported，**不生成假的 .exr**。

## 41：原版 LUT 及缓存语义

11. `Build90OriginalLUT.swift`：按源 3D LUT 轴序 **R×G×B×3**；默认 PCHIP（原版 uniform 1D harmonic slopes 与单侧端点修正，三方向生成 Float64 斜率，Hermite 逐轴，最终钳位到该 2×2×2 cell 的实际 min/max）。
12. Mitchell 可选分支保持原版 B=C=1/3、四点相邻采样、反射边界、64 个权重、除以实际 weightSum 规范化。既不是 trilinear，也不是 Core Image 33³ cubic 插值。
13. 每通道独立输入 `minimum/maximum` 与真实源 `linspace`，严格按用户指定 LUT steps/revision 构造单独 Prepared，不使用已过期缓存；明确要求 revision，换胶片/相纸/调整参数必须构造新对象，完整光学 Float64 路线**永远不会隐式降级到 LUT**。
14. 原版代码 `prepare_lut_pchip_3d` 在 size=1 时提前执行单调性检查，`np.max(np.diff(...))` 抛 `ValueError`；iOS PCHIP 保留该失败语义，不能擅自当常量处理。原版单像素 Mitchell 1-node 返回常量；原版 1-node 图像批处理另待单独验证。
15. `Build90OriginalLUTCache.swift`：48 MiB 上限、数值/三轴 domain/revision 全量比对、2 次锁检测防并行重复插入、失效释放缓存，改变胶片/相纸参数不会命中旧样本；超出预算明确报错，不降 LUT resolution。
16. `OriginalSourcePixelIO.applyOriginalSourceLUTPreview` 已提供严格 16MP 输入尺寸、CPU Float64 原版 LUT/缓存选择的完整 RGB 图像快速预览 API，但**尚未添加独立的 SwiftUI 选择项**；既有 `FilmLUT` 导入/相册导出交互不变。

## 实测证据

- [真实 pinned Python OIIO AST 960 通道 vs Swift](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43688207358)：**PASS**，8 个格式/位深组合、40 组三通道样本（包含负值、超白、边界），整数相等和 Float32 位流完全相等；并不代替实际文件编码。
- [原版 Numba PCHIP/Mitchell 672 通道与缓存失效 vs Swift](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43689375517)：**PASS**。8 原版 LUT（1/2/5/7 点、含非单调），PCHIP 最大误差 `3.219646771412954e-15`，Mitchell 最大误差 `4.440892098500626e-15`，上限 `4e-12`；源 1-node PCHIP ValueError 单独验证，不计入 672 有效通道。
- [8 个原版 ICC 真实 macOS ImageIO 文件](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43689053728)：**PASS**。sRGB JPEG、PNG、TIFF8、TIFF16、TIFF32，Display P3 编码 PNG，BT.2020 编码/线性 TIFF16。**实际文件 ICC bytes、CGImageSource 回读尺寸与真实 bitsPerComponent**一致。缺少 P3 线性 ICC/EXR 实际编码显式失败。
- 总计本批纯数值通道 `960+672=1632`，磁盘文件 8。此为原版抽样输入证明，不等于 1632 张 12MP 真机整幅图。

## 编译/认证门槛

本批真实 iPhoneOS Xcode 16.4 Release arm64+default.metallib 批量编译仍单独记录 CI SHA。真正 iOS 16.5.1 真机媒体库授权、写入相册、Files 分享、EXIF/XMP 全标签、真实 EXR、全部宽色域 source scanner 完整 XYZ→RGB、13MP 峰值未验证；不得提供假 IPA。路线推进工作位置为 **41／47**，**不表示第40–41项所有科学分支完整认证**。

## 本批最终可追溯验证（2026-11-15）

- **最终完整 iPhoneOS Release arm64 合并编译 PASS**：[Actions run 43689500500](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43689500500)。精确受测 Swift/Metal 工程源码 SHA：`20cb39daf08f3f117820a98231720adba8c875d9`，Xcode 16.4，日志 `BUILD SUCCEEDED`，`default.metallib`、arm64 二进制验证通过，应用版本仍 `1.8.58 / Build83`。
- [原版 3D LUT/PCHIP/Mitchell + 缓存失效 run 43689375517](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43689375517)：**PASS**，672 个独立源 Float64 通道，最大 PCHIP `3.219646771412954e-15`、Mitchell `4.440892098500626e-15`；新增 48MiB 缓存的源内容、domain、revision 变化与强制失效均实际运行。
- [原版 io.py AST 960 通道 run 43688207358](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43688207358)：**PASS**，整数精确、二进制 Float32 位模式一致，JPEG/PNG U8，TIFF U8/U16/F32，EXR F16/F32 **仅数值数据**。
- [8 个真实 JPEG／PNG／TIFF 文件与原始 ICC run 43689053728](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43689053728)：**PASS**，原版 sRGB、Display P3、ITU-R BT.2020 的已覆盖组合实际编码，源 ICC 经 JPEG APP2、PNG iCCP、TIFF tag34675 容器嵌入后字节精确，保存文件重新解析的通道位深吻合。此为 macOS ImageIO 测试，不能伪称 iPhone 16.5.1 真机完成。
- 实际源码范围：相对 Build89b 基线，43 次提交、18 个变更文件、约 2271 行新增代码（以受测 SHA 为准）；此文档尾部只追加最终结果，不修改已编译 Swift 算法。
- **认证余项**：原版真实 EXR 16/32 文件编码器未移植／iOS 未接入；原版 pyexiv2 XMP/IPTC 所有细节复制未完成；高位深真实 iOS 文件完整回归、保存相册／Files 分享、8–13MP 整图/RAW/广色域扫描成像、真机内存与全阶段 Python 数值证据仍需继续。
- **禁止虚报 IPA**：当前是 `CODE_SIGNING_ALLOWED=NO` 的 Xcode 编译通过，没有 Build90 IPA、无签名、无 Release。路线工作位置 `41/47`（约 87.2%）不等于原版科学认证 87.2%，第40–41项的残留工程与实机验证如上。
