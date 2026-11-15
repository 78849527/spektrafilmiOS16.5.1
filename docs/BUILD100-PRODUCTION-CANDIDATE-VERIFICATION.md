# SpektraFilm｜Build100 正式候选整理与设备验收入口

**开发源基线**：Build99 `90cc19db94852897336ae44c07a416da83f03044`（已通过 iPhoneOS arm64 Release、生成未签名 IPA）。
**本批**：1.8.67 / Build100，最低 iOS 16.5、目标 iOS 16.5.1。
**原则**：仍为 `UNSIGNED-UNVERIFIED` 实验候选，直到完整源代码数值等价与真实 iPhone 测试资料通过审核。

## 本轮实际变更

| 模块 | 正常操作 | 实验／开发 | 验证要求 |
|---|---|---|---|
| 主界面导航 | 胶卷、调整、工艺 | 实验原版参数移入“高级→实验性原版参数” | 不删除高级算法和任何独立参数 |
| 处理路线 | 移动快速兼容；带条件的原版 8-bit 像素直连 | 原版 Float64 光学仍为“实验、未认证” | 不因 UI 迁移假装 full Python parity |
| 运行状态 | 诊断页明确当前处理路径、预览是否待更新 | 分离 Apple RAW / Build81 诊断与正常处理入口 | 仍保留历史诊断功能 |
| 真机验收 | 在“验证状态与诊断”导出 Build100 设备验收清单 JSON | Build77 实际设备 Float64 阶段采样按钮原样保留 | `Build100Readiness` 将全部未做项目写成 `not_run` |

## JSON 实际字段

- `schema=1`、`version`、`build`、`generatedUTC`。
- `platform`、`osVersion`（设备当前可访问元数据，不虚构 iPhone 16.5.1）。
- `mode`: `mobile_compatible` / `source_8bit_direct_limited` / `source_float64_experimental`。
- `sourceLoaded`、`processedPreviewAvailable`、`selectedMaterialPending`、`runtimeDiagnosticReportExists`。
- `releaseCertification=not_certified`。
- `manualChecks`：12 项，每项有 `id`、`title`、`result=not_run`、`evidence=""`。

输出到 `Documents/SpektraFilm Verification/Build100-checklist-<UUID>.json`，可通过系统文件分享。**不读取或上报任何用户原始图片**，原有 RAW 在 Documents 保留。文件只由用户触发创建；不是自动后台采集或认证。

## 验收 12 项

1. iOS 16.5.1 冷启动/连续进入。
2. 相册、文件、LUT 导入取消/异常回滚。
3. 连续 30 次胶片/相纸拨轮、预览与导出一致。
4. 快速/精确切换参数恢复。
5. 原图长按、分屏拖动与双击放大。
6. JPEG 原尺寸/安全/经济 3 档输出。
7. iPhone 实际 TIFF16 IFD/解码 16 位回读。
8. 系统相册权限、保存及分享回调。
9. 大图峰值内存与连续导出的 jetsam/失败恢复。
10. Python 原版 vs iPhone Float64 逐阶段、整图数值与最终 RGB 对照。
11. 随机颗粒 Python 默认无种子、多线程情况下统计对照。
12. 高位深 ICC/EXIF/XMP/广色域端到端核验。

### 不得据此宣称

- 现有原版 48 份 reference tapes **只能证明 oracle 生成/审核范围**，不能代替 iPhone 真正逐像素结果。
- macOS 上的原生 TIFF IFD 与 Core Image 压力测试不能代替 iPhone 16.5.1 真机验收。
- `hardwareDiagnosticReport` 有内容表示诊断尝试过，不能自动给 12 项任何一项标记 PASS。
- 即使本轮 Xcode 编译成功，也**不得发布“正式认证版”IPA**。
- 富士 RAF 专项仍暂停，Build95/96 的现有代码与已确认回归测试保留。

## 自动化测试

- `ios/tests/Build100ReadinessValidation.swift`: Foundation macOS 真正写入再解析 JSON，验证固定版本、模式隔离、12 项未运行、真实文件位置、无虚构认证等。
- `ios/scripts/build100_readiness_ui_audit.py`: 继承 Build99、98、97、96、92 静态回归并新增正式界面/验收入口检查。
- 持续执行 GitHub Actions 的 Python 源参考数据审计、Core Image 故障注入、RGB48/TIFF16 真实文件测试及 iPhoneOS Release 编译；只对真实完成阶段标记 PASS。

## 后续分支

- 完成 Build100 后，先让用户安装**已签名的候选包**，自行执行 12 项中的可实际操作部分并分享设备证据。
- 数值等价和统计验证继续由自动化执行；若发现偏差，按第一失败阶段修复，不用肉眼图片代替。
- 所有未验证算法仍隔离在高级/实验入口，不能单凭重命名转正。
