
# Build110｜原版 Oklch/CAM16 真机一键验收

版本 v1.8.76 / Build110；最低 iOS 16.5；目标实机 16.5.1。
生产光学算法不变；保留全部 Build106–108 报告与诊断。新增单一真机按键。

路径：高级 → 验证状态与诊断 → **Build110：Oklch／CAM16 四模式真机＋综合报告**。
一键生成同编号 JSON+LOG：记录按下按钮时原版像素／全光学／Hanatos／扫描和 Oklch/CAM16 开关实际状态。
使用同一张 512×512 受控合成 sRGB 图，真正调用 OriginalSourcePhysicalImage.developInPlace 四次：
1. xy + Legacy Scan；2. Oklch Only；3. CAM16 Only；4. Both。
每种记录 Float64 真正运行、CPU 用时、RSS 25ms 采样峰值、FNV64 Float64 输出指纹、样本校验和、与默认 xy 模式的平均绝对差与变化通道数；未观察到输出差异为失败。
合并旧 Build108.capture 的 28+20 阶段、24 组内存预算、旧 100万/200万像素测试，一份 LOG+JSON。

科学边界：用户开关状态快照与四个受控运行是**两种不同证据**；本测试**未直接处理用户导入照片**，也非 Python 原版 512² 整图像素逐一对照；未证明 RAW、广色域、EXR/XMP、13MP、默认无种子多线程和 Jetsam。全部数据由真实 iPhone16.5.1 运行后才能认证，CI PASS 仅代表代码与 IPA 编译通过。
