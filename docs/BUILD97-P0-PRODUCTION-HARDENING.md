# Build97｜正式可用化 P0 第一批修复与验证

**源基线**：Build96 `38fb2577a078c3fab93c360d903b91ec7996f8ad`。
**当前独立修复分支**：`hardening/build97-p0-failclosed-session-memory-ios1651`。
**目标**：v1.8.64 / Build97，iOS min 16.5，目标实测 iOS16.5.1。

这是正式版准备批次，不是已经经过物理真机/完整原版认证的“正式发布”。
冻结现有 X-T5/LibRaw 移植，不新增富士 RAW 功能。

## A01/A02｜停止静默丢失处理效果（P0）

- `Build97FilterContract.required`：所有主动启用的 CI 滤镜产物必须存在且尺寸有限，不能将 nil、空图像当作原图成功返回。错误中附首次失败阶段。
- `PhotoProcessor.apply`：CIColorCube、色彩混合、密度颗粒出错改为抛异常；不再静默退回 unprocessed optical 或普通 LUT。
- `SpatialOptics`：散射、光晕的 GaussianBlur、RGB 颜色矩阵、radiometricAdd 逐级 `throws`，不再 `assertionFailure+return lhs`；保持原公式和当前近似 CI 实现不变。
- `ScannerFinishing`：已启用的随机眩光、GaussianBlur、unsharp CIColorKernel 必须真实产生图像，否则抛错误。**不将现有兼容 RGB 路线伪称 Python 原版 XYZ 路线**。
- 用户禁用的功能或强度为 0 仍可直接通过，这是合法恒等状态，不是 silent failure。

## A03/A05｜导入事务与 RAW 原片分离（P0 + 部分 P1）

- 新增 `pendingImportedRAWURL`：保存 RAW 后只呈现选择，不修改旧照片、旧预览、旧原片关联、精确模式选择；新图仅在用户选定解码成功且预览成功后原子提交。
- 用户点击“仅保留原始 RAW”或者关闭选择时，当前编辑保持不变，原始 RAW 文件已独立保存。
- 普通相册／文件照片先 decode + first preview 再提交；`refresh` 若抛错，恢复源图、预览、关联 RAW、原处理模式。
- Apple RAW 和 LibRaw 8/16-bit 兼容导入保留先前后端和真实 RAF 解码，单改 UI 会话提交语义。
- 相册/文件导入按钮在处理繁忙期间禁用，减少简单重入；全异步状态机和参数会话快照另列 A06/A09 后续。

## A04｜JPEG 原尺寸内存防护（P0）

- `SafeExportResolution.validateForHeadroom` 验证所有三档。原始分辨率按预计显影缓冲 `104 bytes/pixel` 与物理预算 `min(1.5GB,RAM/3)`，同时要求真实 iOS 进程即时余量的 70%。安全/经济档保留旧 50%/30% 分配原则。
- 在用户确认前、开始后台 JPEG 渲染前分别检查尺寸和实时内存；原版 CPU Double JPEG 仍使用独立全光学预算预检。
- 任何预检不足均抛错误，不擅自降低位深、改变选定尺寸，或跳过胶片/相纸/颗粒算法。阈值**仅保守准入估算，不是实际 RSS/内存峰值认证**。

## 验证矩阵

- 继承 Build96 的 48 份 Python 原版 source tapes、文件/相机/RAW GUI 静态回归、真实 16-bit TIFF IFD 和 RGB48 测试。
- 新增 macOS `Build97P0SafetyValidation.swift`：nil/empty 故障注入实际抛错、真实 CI 散射/光晕/扫描滤镜正常处理、原尺寸 JPEG 70% 余量、物理硬门槛、明确选择降档。
- 新增 `build97_p0_production_audit.py`：检测原版 UI/文件路径未丢，4 类 P0 生产调用路径是否已改、冻结 RAW 仍保留。
- Xcode16.4 真正 iPhoneOS arm64 Release 与 `UNSIGNED-UNVERIFIED` 实验 IPA，签名前不能安装。
- **仍需人工 iOS16.5.1 真机**：打开原片、RAW 取消/解码失败恢复、连续调节和导出、低内存复现、实际内存峰值、快捷预览/拆分、照片库授权。缺这些记录不能转“正式验收”。

## 后续（本次不做）

- A06 全局异步任务状态机、A07 源像素能力锁、A08 诊断入口迁移、A09 处理模式设置快照。
- A10 真机科学精度认证和正式签名发行，A12 统一状态文档，A13 历史 CI 归档、A14 导出文件生命周期。
- 这些未完成项不得通过改名或改 UI 隐藏实际风险。
