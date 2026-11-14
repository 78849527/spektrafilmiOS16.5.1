# Build79 / 第09项 — 真实 RAW 文件入口与苹果原生解码探测

**源码基准**：SpektraFilm Python `3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`。
**工程版本**：v1.8.54 (79)，iOS 16.5，arm64。
**状态**：RAW 格式检测/字节保留：已接入生产；原版 RAW 逐阶段等价：**尚未移植**。
**上个版本**：Build78 v1.8.53 (78) 已生成未签名诊断 IPA，GitHub Actions
https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43621321979/artifacts/14124322176 ，并非已认证正式版。

## 真实生产代码

- `Build79RAWSignature.swift`：依据文件内容而不是仅凭扩展名区分
  DNG（含 DNGVersion）、Fujifilm RAF（原始签名）、Canon CR3（ISO-BMFF crx）、
  Nikon NEF（TIFF Make=Nikon）；损坏、伪装 JPEG、未知其他 RAW 均拒绝。
  压缩 RAF、CR3、NEF 复杂元数据需真相机原片验证，不能仅凭签名声称支持。
- `Build79RAWStorage.swift`：保存原始 RAW 到文件 App，源文件与目标文件
  逐块计算 SHA256 并对照字节长度。失败删除目标副本，不转成 JPEG。
- `ContentView.swift → loadPhotoFile`：真实文件导入入口先 RAW 鉴别，再决定
  是否进入普通照片路径，RAW 仅无损保留，不会调用 `CIImage(data:)`
  误将内嵌 JPEG 当作 RAW 显影。
- `Build79NativeRAWBackend.swift`：明确的
  `CIRAWFilter(imageURL:)` 独立苹果后端检测，读取真实 RAW filter 输出，
  对中间像素执行一次 RGBA Float32 渲染；无输出、尺寸不对和非有限值明确失败。
  这仅表示**当前苹果系统可解码此真实文件**，并不证明与 Python rawpy/LibRaw
  逐阶段数值等价。
- `PhotoEditorModel.probePreservedRAWBackend` 和
  `FloatingEditorWorkspace`：用户保存原 RAW 后可以手动点击“检测真实 Apple RAW 后端”，
  不修改源文件或已选择的胶片/相纸，不静默启用未经认证的 RAW 原版模式。

## 经过自动化检查的边界

`Build79RAWSignatureValidation.swift` 覆盖 4 类签名、伪装文件/非法头、
普通 JPEG 拒绝与 RAF 文件流式 SHA256 保留；另要求 Apple RAW
原生探测不能将普通 JPEG 视为 RAW。

**以下仍需真实数据而不能自动宣布通过**：

1. X-T5 未压缩 RAF 与压缩 RAF 分别作设备测试；
2. DNG/Apple ProRAW、CR3、NEF 的真实相机文件；
3. RAW 后端黑白电平、X-Trans/Bayer 去马赛克、WB/Tint、ICC、
   Apple 与原版 rawpy 数值差；
4. 大图内存和最终图像全链路对照。

**不自动发行 Build79 IPA**；目前只需继承 CI 编译。
一旦第 09–12 项需要真实设备照片或系统后端验证，再生成合并测试 IPA，
不重复为每一模块打包。
