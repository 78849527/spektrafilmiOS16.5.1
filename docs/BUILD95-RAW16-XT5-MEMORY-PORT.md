# Build95｜X-T5 LibRaw 16-bit RGB 高位深输入 + 内存防护

- 版本：1.8.62 / Build95，iOS 最低 16.5，ARM64。
- 基线：Build94 SHA `e0db981e0fa0ff7873c9c5ad3516f2bce881c9f0`。
- 原版 Python：不修改 48 份原版阶段 reference tapes；旧 Build94 8-bit 快速路径保持可用。

## 真实开发内容

1. LibRaw 0.22.0 Objective-C++ 桥允许**明确选择 8 或 16 bits/channel**；实际调用 `libraw_set_output_bps`，输出后核对 `image->bits`、通道数、宽高和 `data_size = width*height*3*(bits/8)`，禁止静默降成 8-bit。
2. 在原生 `libraw_unpack` 前用 X-T5 完整输出宽高估算设备内存，基线公式 8-bit `pixels*18+96MB`、16-bit `pixels*28+96MB`，硬门槛 1400MB。**是保守估计、不是 iOS 设备 RSS 实测**，拒绝不改变文件和处理模式。
3. Swift `Build95LibRaw16Ingress.open` 接收真正由 `LibRaw` 生成的 16-bit sRGB RGB 数据，以 48-bit `CGImage`、native little-endian `UInt16` 搬运至 `CIImage`。必须实际确认 iOS CGImage 支持；不接受 8-bit 自动回退。
4. RAW 导入弹窗新增「LibRaw 富士 RAF 16-bit 高位深兼容模式」，原版物理精确开关只有在用户明确选取后才关闭。旧 Apple RAW 与 LibRaw 8-bit 入口不变。
5. RGB 输入保持 16-bit，但既有**输出 JPEG 仍为 8-bit**；CPU Float64 / Python rawpy/LibRaw 源光谱等价、16-bit TIFF/EXR 端到端文件、实际 40MP 峰值并未完成，禁止据此称全流程 16-bit。

## 证据等级

| 项目 | 当前 |
|---|---|
| Xcode iPhoneOS arm64 构建 | 待本批 CI 核验 |
| LibRaw 8/16-bit 生产桥接 | 已编码 |
| 16-bit RGB48 CGImage/CIImage macOS 测试 | 待 CI |
| 原版 48 source tapes | 每轮独立审计 |
| 实机 iOS16.5.1 X-T5 无压缩/无损/有损 RAF | **未验证** |
| 16-bit 精确光谱路径 | **尚未移植** |
| 40MP 真实峰值、CPU/GPU OOM | **未验证** |

发布的 IPA 只能标注 `UNSIGNED-UNVERIFIED`，真实设备执行及 RAF 图像像素对照仍是硬门槛。

LibRaw 固定官方版本 `0.22.0` / commit `0b56545a4f828743f28a4345cdfdd4c49f9f9a2a`；上游许可 CDDL-1.0 或 LGPL-2.1，继续保留源码来源和发行义务：https://github.com/LibRaw/LibRaw/tree/0.22.0
