# Build108｜真实原版 Float64 100/200 万像素光学与真机 RSS

源代码基线：Build107 `d4edfb3e27ed71256927f374495644a6d69a1688`，原 Build106+107 真机受控反馈 `allControlledChecksPassedOnTarget=true`。

## 新功能

- **手动触发**：「高级 → 验证状态与诊断 → Build108：真实 100/200 万像素光学与 106–108 综合 LOG」；本机不会自动运行大型测试。
- 首先重新执行 Build103 Python 原版 28 阶段、Build104 Python 原版 20 阶段、Build106 24 个源预算判断及 Build107 16MiB 真实触页 RSS。
- **真实 1 MP** 1000×1000：固定 Kodak Portra 400 → Kodak Portra Endura；原版 Hanatos/H-D/DIR 整图 FIR/YVV → 完整 3×3 SciPy 胶片密度颗粒 → 原版光学印相与测量光谱扫描。Numba microstructure 仅在原版条件触发，seed=8888。
- **真实 2 MP** 1600×1250：同样完整负片/相纸/扫描链，*不启用*九层颗粒，明确不同测试覆盖；先完成 1MP，失败即不执行 2MP，避免重复风险。
- 原始 RGB 是确定性生成的内存中 sRGB 数组，不经相机、ImageIO、相册或 RAW 解码；直接调用生产 `OriginalSourcePhysicalImage.developInPlace`，不使用任何代理近似/Float32/CI 替代。
- 25ms 采集一个采样 RSS 的运行峰值，另记录内存准入预估、实际耗时、进程初始/结束 RSS、输出采样校验和、首个失败。
- 降级/缩图均被禁止；生产 `Build91PhysicalMemory` 二次前置检查拒绝内存不足。绝不虚称精准 high-watermark、Jetsam 13MP 测量或未经上游 Python 大图对照的数据。
- 一次导出一对 `Build106-107-108-device-feedback-<UUID>.log/.json`；内部同时包含前两版报告。

## 明确未验证

- 1300 万像素整图 / Jetsam 风险；1/2MP 独立 Python 原版完整图像等值验收（仅继承已通过的 28+20 受控阶段）；多工作线程默认未播种 Numba 随机性；RAW/ICC/EXIF/XMP/广色域全链；其他未开启的光学分支。
- 1MP 九层颗粒为实际全尺寸测试，不等于所有原始 Python 随机/所有图像处理路径已完成移植。
- 本轮仅新增诊断与真机报告，不修改原版光学公式/参数/计算顺序。
