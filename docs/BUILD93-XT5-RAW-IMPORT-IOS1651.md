# Build93 · iOS 16.5.1 RAW 导入可编辑闭环｜Fuji X-T5 优先

- 分支：`port/build93-raw-import-fujifilm-xt5-ios1651`
- 版本：`1.8.60 / Build93`，最低 iOS 16.5 不变。
- 基线：Build92 `2b97b308bbdf705b5fb44ade7beabb49231a7740`。不修改其 45–47 原版 Python 数值基准。

## 实际修复

1. 旧 `PhotoEditorModel.loadPhotoFile` 识别 RAW 后仅通过 `Build79RAWStorage` 按 SHA-256 保存原件，马上清空 source，所以无法导入、预览、编辑。本批保留这个不改写 RAW 的存储行为。
2. 新增选择弹窗。用户点击「使用 Apple RAW 兼容模式打开」，才会关闭既有逐像素精确输入并进入明确标记的**快速兼容**模式；点击「仅保留原始 RAW」不进行显影。
3. 新增 `Build93AppleRAWImport.open`：严格进行 RAW 文件签名识别、`CIRAWFilter(imageURL:)` 实际去马赛克、4×4 全浮点 RGBAf 有限性测试；禁止 `CIImage(contentsOf:)`、`CIImage(data:)` 或 JPEG 内嵌缩略图回退。
4. 以真实 CIRAWFilter 产生的懒执行 `CIImage` 进入已有 `PhotoProcessor.preview/apply/exportJPEG` 流程，预览最多 1500px；原 RAW 文件仍完整保留。原尺寸导出依照当前内存预检，不能无声缩小。若用户显式选安全尺寸才允许降低输出分辨率。
5. 未完成的仍是：Apple RAW 与 Python rawpy/LibRaw 的像素数值等价、RAW 进入光谱 Float64 全链、富士 X-T5 压缩 RAF 的独立 LibRaw iOS 编译集成、iOS16.5.1 真机三档 RAF 测试、全幅 40MP 成功导出认证。

## X-T5 兼容范围与证据等级

| 文件 | 本批路径 | 验证 |
|---|---|---|
| X-T5 RAF 无压缩 | Apple iOS16.5.1 CIRAWFilter | 已开发，尚未使用真机 RAF 实测 |
| X-T5 RAF 无损压缩 | 必须移植 LibRaw 后端 | 尚未移植 |
| X-T5 RAF 有损压缩 | 必须移植 LibRaw 并单独验证 | 尚未移植 |
| DNG / Canon CR3 / Nikon NEF / Sony ARW | 有签名校验 + 系统支持时 Apple RAW 兼容模式 | 逐机型、逐压缩模式真机验证 |
| Python 原版 RAW 模型 | 保持独立 CPU Double + 原版数值比对 | 尚未验收 |

官方来源：
- 富士 X-T5 支持 14-bit RAF、三种压缩模式：https://fujifilm-dsc.com/en/manual/x-t5/menu_shooting/image_quality_setting/
- 富士设备系统兼容表（X-T5 无压缩 RAF 从 iOS16 起，压缩 RAF Mac 亦列 N/A）：https://digitalcamera-support-ja.fujifilm.com/digitalcamerapcdetail?aid=000004309
- LibRaw 官方支持 X-T5，**仅表示上游可行，不等于已打包在 App**：https://www.libraw.org/download

## 本批验收门槛

- Build93 静态源码和 UI 回归必须全部 PASS。
- 同一 SHA 的 iPhoneOS arm64 Release 完整编译、IPA Bundle 信息、默认 Metal library 和原版 fixtures 验证必须 PASS。
- 只允许带 `UNSIGNED-UNVERIFIED` 的实验 IPA；无法声称真实 iPhone16.5.1 运行、富士 RAF 解析成功、原版数值等价。
- 真机下一步：各拍一张 X-T5 无压缩／无损压缩／有损压缩 RAF，报告成败、输出尺寸、iOS 版本、内存峰值与第一处报错。仅在真实证据出现后更新状态。
