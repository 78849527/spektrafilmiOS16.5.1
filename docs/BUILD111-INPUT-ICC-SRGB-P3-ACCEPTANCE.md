# Build111｜拍摄／相册／文件的位深和色彩空间入口统一修复

基线：Build110 成功真机回归与 four-mode Oklch/CAM16；iOS 16.5.1，Swift 5。**不改原版光学数学、默认参数或浮点精度。**

## 修复范围
1. 拍摄处理图、相册、文件统一使用 Build111PhotoInputProfile.inspect。读取实际文件格式、位深、CGImage 色彩空间、分辨率、Alpha 结构。
2. 导入后照片顶部显示来源、JPEG/HEIC、8-bit/16-bit、sRGB/P3/其他、像素。无需先运行出错才知道不兼容。
3. 原版入口开关读取同一 directCompatible，发现不兼容时灰色，但允许点开查看原因；P3 允许用户明确转换。移动快速模式不受影响。
4. 只有确实标记 Display P3 的 8-bit 无 Alpha 文件、用户明确确认后，Quartz/ColorSync 转换实际颜色并输出独立 sRGB JPEG 副本。原始文件不覆盖。未知 ICC、无标签、RAW、HDR 不自动转换。
5. Build110 真机综合报告增加当前照片摘要、能否直连、是否经过明确 P3 ColorSync 转换；保留原四模式诊断。
6. CI 真实生成 P3 JPEG，测试明确转换输出 sRGB、原始数据字节不变，sRGB 直接可用，损坏输入明确拒绝。

## 回馈流程
- iPhone 前置拍摄，或从相册、文件导入。观察顶栏位深和色彩空间。
- 如果 P3：点击顶栏，阅读提示，确认转换。确认后显示 sRGB｜ColorSync 已转换。
- 在高级实验参数中打开 8-bit 原版直连、全光学、Oklch、CAM16。
- 高级→验证状态与诊断→Build110 四模式综合 LOG＋JSON。上传同编号文件。
- 如失败，提供错误全文；不修改原光学算法以掩盖输入问题。

## 未认证范围
诊断内部 512×512 合成图不是用户照片的 Python 原版逐像素认证；ColorSync 不是 Python 色彩等价证明。高位深、RAW、未知 ICC、HDR、13MP、Jetsam 等仍受原有限制。