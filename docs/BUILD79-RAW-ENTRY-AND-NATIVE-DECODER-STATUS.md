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

## Build79/09 后续补缺：CR2 / ARW 与严格 TIFF/DNG 头验证

- 真实生产 `Build79RAWSignature.Kind` 新增 `.cr2`、`.arw`。它们沿用 `loadPhotoFile → Build79RAWStorage.preserve` 的文件入口与 SHA256 保留逻辑，并可走用户显式调用的 `CIRAWFilter` **能力检测**；不能宣称已经完成传感器解码。
- Canon CR2：检查合法 TIFF II/MM 签名、偏移 8 的 `CR` 标志、2.0 版本、IFD0 和 IFD3 偏移，并验证 IFD0 结构。参考 [libopenraw CR2 格式说明](https://libopenraw.freedesktop.org/formats/cr2/)。
- Sony ARW：需要 TIFF IFD0 `Make` ASCII 值含 `SONY`；支持 TIFF 端序及短值/偏移字符串，避免只靠 `.arw` 后缀误识别。
- DNG：`DNGVersion` 除 BYTE[4] 类型验证外，强制读取 inline 真实版本值；拒绝零填充和未知非 1.x 主版本。覆盖大、小端 TIFF。
- Canon CR3：验证 `ftyp` Box 长度、边界以及 `crx ` 品牌，拒绝长度非法的伪造文件头。
- `Build79RAWSignatureValidation.swift` 增加 CR2、ARW、Big Endian DNG 签名样本及共 12 个无效/伪造头拒绝用例。样本为**自构造容器头**，不等于真实相机 RAW。
- 代码提交：`e9bd7ef4e647969dc8045f8064508d21f302383b`；验证：[Actions 43624477909](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43624477909)。结果须在运行结束后独立确认。
- **尚未认证**：X-T5 RAF（压缩/未压缩）、真实 CR2/ARW/CR3/NEF/DNG、机型兼容矩阵、RAW 全幅渲染、rawpy/LibRaw 数值、真机测试。现阶段仍不发布正式或实验 IPA。

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
