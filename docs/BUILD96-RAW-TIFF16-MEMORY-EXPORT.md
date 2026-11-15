# Build96｜富士 X-T5 RAW 编辑闭环、真正 16-bit TIFF 导出与内存防护

基线：Build95 SHA `61a4242ea48fd4b227e9d4310d921622d7818833`；本批 `1.8.63 / Build96`，iOS 16.5 最低版本不变，arm64。

## 批量实装内容

1. **真正的 TIFF16 文件输出**：新增 `Build96TIFF16Writer.swift`。使用 Core Image `writeTIFFRepresentation(...format: .RGBA16)` 输出标准 TIFF。读回 ImageIO 尺寸／UTI，直接扫描 TIFF IFD 标签 `258 BitsPerSample` 严格验证 RGB/RGBA 分量实际为 16 bit。验证失败即清理文件，不将 JPEG/TIFF8 改名冒充 TIFF16。
2. **完整编辑→导出连线**：在 `PhotoProcessor.exportTIFF16` 调用原有 `PhotoProcessor.apply` 的光学／胶片／相纸／扫描器和已启用空间 DIR、颗粒模块。复用原有用户确认分辨率的 Lanczos 缩放次序，保证先定输出尺寸后运行效果；未认证 CPU Float64 直连模式拒绝转入 CI。
3. **三档 TIFF16 文件分享 UI**：原始／智能安全／省内存；沿用导出前确认底部工作流，文件分享、取消机制不变。相册继续 JPEG。TIFF 由实际 16-bit 文件导出，不称其具有 Python 完整数值精度或 16-bit 原版 ICC。
4. **40MP 安全预算**：TIFF16 按 `pixels*136+96MB` 粗略内存计量、物理上限 1.5GB/物理 RAM 三分之一、进程当前余量 70% 进行保守准入；大原图不足则**提示明确选择安全尺寸**，不可静默重采样或减少位深。
5. **RAW 解码前真实内存检查**：ObjC++ LibRaw 真正 `libraw_unpack` 前使用 iOS 16.5 `os_proc_available_memory()`，拒绝超过当前可分配余量 70% 的 8/16-bit X-T5 RAF。保留 Build95 上限及独立 8/16-bit 用户选择。此检查是建议性的阈值，不是 40MP 真机峰值的测量证明。
6. **测试分层**：完整 Build92 原版 48 阶段 Python reference tapes；先前 RAW/UI 静态检查；新增 TIFF16 文件实际编码/反解、标准 IFD 16-bit、40MP 预算单测；原生 LibRaw Fuji X-Trans iPhoneOS arm64 编译＋真实 App iPhoneOS Release 编译／资源校验／未签名实验 IPA。

## 严格边界

- X-T5 RAF 无压缩／无损／有损 **尚未分别用真实 iOS 16.5.1 设备测试**。
- 这里的 LibRaw RGB16 是**经 LibRaw 处理的 sRGB UInt16**；不是原始 14-bit X-Trans CFA、也不是 Python rawpy Float64 / ACES2065-1 源数值等价。
- TIFF16 是最终渲染数据 16-bit 输出。常规胶片处理路径可能以 Float32 及 LUT 计算，**不代表整条光谱链已经全程 16-bit/Float64 且数值认证通过**。
- TIFF16 目前输出 sRGB，不保证原文件 XMP、完整相机 ICC 或原版 Python ICC 的逐字节保留。Build90 已有独立原版 TIFF Writer，不应把两条路径混淆。
- 40MP 原尺寸高位深导出可能被内存防护拒绝。**这是主动 fail-closed，不是能稳定全尺寸输出的认证**。只有真机监测到实际 RSS/成功失败才能判断。
- 此轮 Release 必须是 `UNSIGNED-UNVERIFIED`，用户签名后才能安装。

后续仍需：iOS16.5.1 真机测试 X-T5 三种 RAF、40MP 内存／相机与镜头参数一致性、原版 Python RAW 实际图像对照、完整宽色域 ICC/XMP、真实 EXR 文件编码。

### 上游依赖

LibRaw 0.22.0 / SHA `0b56545a4f828743f28a4345cdfdd4c49f9f9a2a` https://github.com/LibRaw/LibRaw/tree/0.22.0 （源文件与许可信息均与 Build94/95 一致）。
