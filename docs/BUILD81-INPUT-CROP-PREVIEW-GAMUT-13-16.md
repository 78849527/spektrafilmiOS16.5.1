# Build81 / 13–16 — 原版输入裁剪、缩放、预览与色域压缩

**候选版本：1.8.56 (81)，目标 iOS 16.5.1。**
**阶段状态：源函数已移植，数值对照与真机完整图像认证分开。**

源标准固定为 `andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`，不改动 Python 原版；Build80 Release `ios1651-v1.8.55-build80-RAW-DIAGNOSTIC-UNSIGNED-UNVERIFIED` 独立保留。

| 工作项 | Python 源（固定 blob） | Swift 原生模块 | 本批支持范围 |
|---|---|---|---|
| 13 裁剪 | `utils/crop_resize.py@4737b922...` | `Build81OriginalCrop.swift` | NumPy nearest-even、长边比例、中心 x/y 翻转、边界修正、Python 负切片语义及 CPU Float64 RGB 复制 |
| 14 缩放 | `utils/preview.py@985c4099...`、scikit-image 0.25.2 | `Build81OriginalPreview.swift` | order=1、antialias Gaussian sigma=(factor−1)/2、reflect→SciPy mirror、grid_mode、Float64 插值 |
| 15 预览 | 同上 | `Build81OriginalPreview.swift` | max_side 触发条件、`int()` 向零取整、非缩放直通与零维尺寸失败 |
| 16 输入色域压缩 | `utils/gamut_compression.py@9783e7fc...` | `Build81OriginalInputGamut.swift` | Reinhard knee、源射线与多边形相交、xy radial、active=false 直通；输入 Oklch 尚未移植，显式报错 |

### 实际验证

`ios/scripts/build81_original_input_oracle.py` 强制校验上游三个 Git blob SHA，**直接提取并运行 Python 原始函数 AST**，使用 scikit-image 0.25.2 实际生成源参考：

- **11 种裁剪输入**：画面比例、右下角/左上角、肖像/横幅、短边溢出、Python bankers-round、Float64 RGB 位模式；
- **8 种预览**：缩小、不缩小、不同尺寸比例；原版 gaussian/linear Double 像素，输出尺寸与每通道误差；
- **3 种膝部参数**：Reinhard knee、真实 XY radial 源函数、显式封闭矩形多边形、active=false 完全保留。
  
`Build81OriginalInputValidation.swift` 与 CI 中的 Swift 原生实现逐项对照：裁剪及 no-resize 必须 Float64 **按位相等**；预览需通过明确的绝对误差阈值 `3e-6+2e-6×abs(original)`，打印 MAE/RMSE/max；色域色品误差 ≤1e-9，knee ≤1e-12。任何失败立即中止 CI，不对未通过模块宣称完成。

### 尚未认证／不可偷换

- 当前色域算法仅使用**显式传入的光谱多边形**；源默认的真实 CIE 1931 380–700nm、5nm 的 polygon 需要单独数据绑定并对照。源 Oklch 分支尚未移植。
- 本次预览的 Float64 路径是实际缩放数学；Float32（scikit/SciPy 每阶段强制窄化）尚未单独等价认证。
- 现有 ImageIO/Quartz 缩略图不得默认冒充原版 scikit-image 预览。
- 本批不会把图像导入、缩图或 gamut 从旧默认路径**静默替换**；接入生产完整链前必须保留原版源色域、源参数与输入边界。
- 尚未提供 X-T5 RAF、ProRAW、完整 RAW 色彩、真实整幅 iPhone 16.5.1 像素对照和 Oklch LUT，一律不可标记“数值等价”。
- 此批不自动发布 IPA，Build80 已发布测试 IPA 原样保留；Release 必须通过独立 CI 并真实验证。

**CI 实际记录：** [Build81 GitHub Actions](https://github.com/78849527/spektrafilmiOS16.5.1/actions?query=branch%3Aport%2Fbuild81-input-geometry-gamut-13-16)。仅当最终日志与源提交一致时报告通过。
