# Build77 一次性整体验收：未完成

认证状态：**INCOMPLETE — 不得宣称完整移植或数值等价。**
Python 唯一算法源：andreavolpato/spektrafilm，提交 3bb2c2d2801ff68b92019cf1dbcbb133d60832bc。

## 已实现的一次性真实设备证据收集

仅在 Build78 诊断分支的无签名实验 IPA 中，打开 App 状态检测报告，按“一次采集完整负片／正片／扩散阶段证据”。三种生产分支使用与 Python CI 完全相同的 6×4×3 Float64 NumPy 输入（72 个 IEEE754 位模式）：

- negative-print: Kodak Portra 400 → Endura；负片七阶段
- direct-scan: Provia 100F 直扫；正片五阶段
- negative-print-diffusion: Portra 400 → Endura；二维扩散印相七阶段

导出到 文件 App → 我的 iPhone → SpektraFilm Port → Build77-ONE-SHOT-日期。
全部阶段数据是实际 iPhone Swift 物理代码的 Float64 数组，根目录包括版本、设备、提交 SHA 和未认证状态。不得用模拟器输出冒充真实硬件。

Python CI 同时生成 negative-print-controlled、direct-scan-controlled、negative-print-diffusion-controlled 三个真实原版源码参考目录。一次执行全部对照：

    python ios/scripts/certify_build77_oneshot.py --source-evidence PYTHON_CI_EVIDENCE_DIR --iphone-evidence DEVICE_ONE_SHOT_DIR --report build77-final-stage-comparison.json --atol 1e-8

报告一次核对输入 SHA、构建 SHA、分支、胶片与相纸、参数开关、原始 stage 数值、Float64 维度和 NaN/Inf 分类、MAE/RMSE/max。缺少设备证据时，必须非零退出，不能伪报通过。

## 最终验收所需但仍缺失的证据

1. 第01：iPhoneOS 源依赖与加载的 28 款素材的实测数据来源及运行时 SHA。
2. 第02：负片 7 / 正片 5 / 扩散 7 个真实 Python ↔ iPhone 阶段，**同一输入且同一参数**，达到逐 tap 阈值。
3. 第03：所有 RuntimePhotoParams 默认值、UI 真正的参数连接、原版预览/调试/LUT 互斥条件和缺省行为。360 组参数 digest 不等于 UI 完成。
4. 第04：28 款素材的实际 iPhoneOS 加载值、null masks、Float64 字节与独立原版 SHA。
5. 第05：真实默认无种子多线程 RNG 的算法/分布、全图色差与边缘、8/12MP 内存和耗时、真实设备与版本报告。
6. 真机 iOS16.5.1 兼容、全 UI 回归、签名和 Release 资产身份核验。

**受控 6×4 三分支全部通过也不等于默认原版整体认证；缺少一项即保留 INCOMPLETE。** 本文只定义一次性总报告，不允许把一项小测试写成项目认证完成。
