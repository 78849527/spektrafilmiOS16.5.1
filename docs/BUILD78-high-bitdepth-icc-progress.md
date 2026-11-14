# Build78 / 工作项 06–08：输入精度与 ICC 科学边界

- 计划基线：v1.8.51 Build76，`f00383059882efe9b9a09151898b5dadaa2906f9`
- Python 唯一算法标准：`andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`
- 当前承接分支：`port/build79-raw-identify-09`；从已有 Build78/79 继续，不回退 RAW 生产入口。
- 科学验收：**未完成**。本文件不是完整原版等价证明，也不授权正式 IPA。

## 06：8-bit JPEG/HEIC/PNG/Alpha/方向

状态：**近似实现**。`OriginalSourcePixelIO.decode` 在实际像素路径读取明确标记的 sRGB 8-bit 文件，使用 Exif 1–8 坐标变换，不透明 Alpha 检查。其 Quartz 绘制、不同文件编码和 ICC 解码仍须用真实文件按 Python 上游色彩入口逐像素复核；不能声明整个 06 完整。

## 07：16-bit/Float TIFF、PNG、HDR、EXR

状态：**近似实现**。原有 `Build78HighBitDepthIngress` 已连接实际 TIFF/PNG 16-bit UInt16→CPU Double，独立 macOS ImageIO 文件测试覆盖 18×2 RGB 通道、方向、最近邻预览、Alpha/P3 拒绝。`Build78FloatTIFFIngress` 已连接带明确 extended-sRGB 标记的 Float32 TIFF→CPU Double，使用真实 ImageIO 文件测试负值、超白和全部 18 通道。

本次补缺：同一个浮点入口在接收到真正 16-bit IEEE754 浮点 TIFF 的 ImageIO 位图时，按文件已声明的 16-bit 字节序读取 `Float16(bitPattern:)`，无量化地提升到 CPU Double；仍拒绝未标记/P3/线性 profile、非有限值、非不透明 Alpha 和未经认证的缩放。生产分流在 `OriginalSourcePixelIO`，测试在 `Build78FloatTIFFValidation`。

该测试必须使用真正 TIFF 文件反复经过 ImageIO：如系统不能生成/解出 Float16，明确记录 **UNAVAILABLE** 或拒绝，不能声称该设备已支持。可用时按 18 个 Float16→Double 的 bitPattern 对照，包含非正常最小值、负零、负值、超白。测试通过只证明对应 CI macOS 主机及样本，不证明 iOS16.5.1 真机支持。EXR、其他 ICC、任意 HDR 传递函数、完整 Float16 相机文件和整图精度尚缺。

## 08：ProPhoto、P3、Adobe RGB、ACEScg、线性 / 编码映射

状态：**尚未移植**。目前宽色域在精确像素输入路径上 fail-closed，不执行与原版未验证的隐式 sRGB 转换；拒绝不等于完整色域移植。必须实现原版输入传递函数、适应矩阵和 profile 映射，并用真实 ICC 样本和 Python 参考验证。

## 验证门槛

- 本批新增源代码末端 SHA：`2cebb2abcaf55121ef7f38e8997728d0bba148ec`。
- 自动化 CI：<https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43623403709>。**此文写入时尚未确认最终结果**，不可误报通过。
- iPhoneOS arm64 编译、iOS16.5.1 真机文件测试、设备峰值内存、Python 原版逐阶段全图、宽色域等价仍按独立证据认证。
- Build77 的完整七 tap 与原版默认行为尚未通过最终设备认证；Build78/79 既有实验流程不能被表述为已认证原版。
- 本补丁不生成 IPA、不变更上游算法基准、不重命名任何已经通过的模块。
