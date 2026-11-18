# Build136｜内存与历史实验常量审计

**范围**：SpektraFilm iOS 16.5.1 当前工作分支。静态检视 ios/ 代码树中的生产 Swift、ObjC/ObjC++、测试 Swift、Python 验证与 CI 流程；GitHub 源码为审计对象。原版 Python 算法值仍是唯一数值参考，不修改其输出默认、RNG 顺序、Double/Float32 分界。

## 一、确认的旧上限／路径不一致

| 模块 | 旧行为 | Build136 处理 | 认证级别 |
| --- | --- | --- | --- |
| OriginalSourceSciPyParticles.swift | 104 B/px 的估算与固定 min(1500 MB, RAM/3) 比较 | 去掉 1500 MB 硬门槛；iOS os_proc_available_memory ×70%（macOS 测试退回 RAM/3） | 静态；真机峰值待测 |
| OriginalSourceDiffusion.swift / Build91PhysicalMemory.swift | FFT 额外工作区超过 512 MB 直接拒绝，误报为“原版数值上限” | 去固定限制；保留 32768 FFT 几何约束，Build91 整帧+FFT 动态 80% 校验，执行前再次检查 FFT 后续分配量 | 静态+数值回归；大型 FFT Jetsam 待测 |
| OriginalSourceScannerGlare.swift | 完整源流程最高 13MP，该节点 12MP | 统一至 13MP；不修改眩光随机或滤波算法 | 静态，13MP 组合真机待测 |
| OriginalSourceFilmHalation.swift | 完整源流程最高 13MP，该节点 12MP | 统一至 13MP；不修改散射或光晕算法 | 静态，13MP 组合真机待测 |
| OriginalSourcePixelIO.swift | RAW 完成 Float64 光学后，显示预览仍先生成全幅 RGBA8+Data，再缩到最大边 1600px | 对大图直接从完成的 Float64 帧生成至多 1600px 的 UIKit 预览，不再创建全尺寸 RGBA8/CGImage；导出不变 | 静态；预览像素/界面真机待测 |
| SafeExportResolution / ContentView / FloatingEditorWorkspace | RAW P1 全光学出口只准 original；普通图另有三档 | 新增用户显式选择 720/800/900/1000/1200 万；RAW 先按原尺寸完整 Float64 光学显影，只有文件输出另做 Float64 面积平均缩图，不触碰 DNG 和原版随机顺序 | 单元+CI 待确认；RAW 真机导出待验 |
| 历史 Python 断言 | 仍要求 1400/1500 MB 文字常量或 512 MB 固定阈值 | 替换为动态余量语义，历史版本/旧数值事实不删除 | 静态 |

2026-11 Build135 已修复其他位置的 1500 MB（原尺寸规划、CI TIFF16、RAW Float32、Metal IIR）、1400 MB LibRaw Swift/原生桥、1300 MB 智能模式旧门槛；Build136 不重复引入。

## 二、保留而未任意改动的数值

- **13,000,000 像素**：当前 CPU 原版 Float64 全帧链路的独立几何边界。是 iOS 实现的安全范围，**不是 Python 算法规定的上限**。40MP 需求需独立真实内存/分辨率验证后再审慎放开。
- **8192 单边／32768 FFT 网格**：数组、Radix-2 FFT 整数几何和内存风险约束，不应被“取消所有内存限制”误删。
- **12MP/7.2MP**：用户主动选择的智能/省内存输出几何上限，与新增固定像素菜单并存；不代表算法上限。
- **104 B/px CPU 原版估算、相机/扫描器/颗粒额外字节账本、TIFF16 编码固定开销 96 MB**：是保守内存**估算系数**而非固定内存上限；未有同机 Instruments 实测证据时不随意调低。
- **LibRaw 45MP、普通色彩输入 16MP、输出 writer 16MP**：兼容路径几何边界，不能误当为 CPU 原版 13MP 可运行承诺。
- **原版随机种子、28–35mm 光学参数、样本精度与各胶片/相纸数据常量**：原版／用户配置，未在本次内存审计改写。
- **“实验／未认证”文字状态**：部分是真机/Python 整图未认证的事实，不应只为界面整洁而改成“正式验证通过”。

## 三、内存优化计算与验证边界

以 3024×4032、1219 万像素 RAW 为例：

- 原先 UI 预览中间 RGBA8 一份约 48.8 MB，转成 Data 可能再复制约 48.8 MB，随后还需独立的小预览。
- 新版本直接写最大边 1600px 的显示 RGBA8。预计可去除至少一份全幅 RGBA8 中间对象，**实际峰值 RSS 节省量尚未在真机实测**。
- **RAW 输出缩到 1200 万、1000 万、720 万并不能降低此前已执行的原尺寸光学计算成本**。输出 Float64 重采样还会产生另一张小图的临时缓冲；现按原图全尺寸成本 + 输出缓存纳入预检，避免错误宣称降内存。
- 必须保留按当前进程余量拒绝、禁止无通知改变像素、退回 JPEG8/CI/Float32/修改胶片算法。Jetsam 不能靠 Swift catch 捕获。

## 四、后续真机验证

1. 3024×4032 RAW，三档 720/1000/1200 万 JPEG、TIFF16，检查文件 EXIF/尺寸/实际位深、RAW 未更改。
2. 分别开启光晕、扫描眩光、SciPy/FFT 源模块，观察真实 RSS 峰值、os_proc_available_memory 快照及完整渲染。
3. 对比 Build135 与 Build136 同一 RAW 初始/完成预览峰值、渲染时间；不能以静态内存预测冒充 Instruments/真实 Jetsam 证明。
4. 原版 Python 同图数值（RAW 解码、光谱、颗粒/扫描）仍待独立验收，不能因为 Xcode 编译通过宣称等价。

状态：此文档是代码审计与实施记录；最终 CI 及真机结果以实际 GitHub Actions 和设备日志为准。
