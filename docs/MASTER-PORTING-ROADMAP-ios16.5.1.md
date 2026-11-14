# SpektraFilm Python → iOS 16.5.1 原版最大化移植总路线图

**规范级别：项目长期执行基准；路线图版本：2026-11-14。**
**iOS 起点：v1.8.51 Build76，Git SHA f00383059882efe9b9a09151898b5dadaa2906f9。**
**原版源码唯一科学基准：andreavolpato/spektrafilm，当前核对 SHA 3bb2c2d2801ff68b92019cf1dbcbb133d60832bc（2026-06-06）。**
**本文仅为规划文档，不改变代码、算法基准、CI 或 IPA。**

## A. 不可变更的最大化完整移植原则

1. **默认完整移植所有原版功能**：以 Python 原版的参数、默认值、配置分支、处理顺序、色彩空间、光谱/曲线数据、数学公式、随机流、边界条件和输出为准；凡源代码提供且在 iOS 能实现的功能，都必须进入最终路线。不得以“够用了”“移动端用不上”“视觉差不多”“成本高”“比较慢”为删除理由。
2. **只有经证据确认 iOS 16.5.1 无法按原版技术路径实现时，才能采用替代**。必须记录阻碍点：API 不存在、硬件缺失、签名/JIT 规则、Metal 数据类型、具体文件格式不支持等。原 Python 库无法直接安装 ≠ 数学算法无法实现。替代前必须尝试 Swift、原生 C/C++、Accelerate、Core Image、ImageIO、Metal 和可合法集成的底层库；替代方案应尽可能保留完整功能和结果。
3. **先算法一致，再优化性能**。优化算法的内存布局、临时数组和线程执行可以，但不得改变原始模型、计算分支、默认行为、数据精度、随机调用顺序、卷积边界；优化后独立重跑 Python 源码数值测试。
4. **原版精确和移动快速模式严格隔离**。原版需要 Float64 时优先 Swift/C++ CPU Double；Metal 无原生 double，仅可放在独立快速路径或验证等价的具体子计算。不得把 GPU Float32、Core Image、Float16 或小 LUT 自动顶替完整源模式。
5. **无法精确复现的替代需显式披露**：同时报告原版输入/输出、替代计算、尚存差异、测试误差和限制。未通过同等证据门槛，一律标记近似实现，不能标记数值等价或完整移植。
6. **RAW、16-bit/Float32、P3/ProPhoto/ACES、压缩 RAF/其他相机 RAW、多线程随机流、CAM16 等全部保留在路线图**。不允许因为 iOS 复杂而直接删项。任何 RAW 解码后端如 Core Image/LibRaw 都必须按该后端的实际数值事实认证，不因 RAW 文件能打开便写成与 rawpy 数值等价。
7. **不静默降级**。禁止静默降低分辨率或位深、略过未支持步骤、近似滤波替代源 FIR/YVV、改变种子或重建随机流、抹掉色域边界、偷偷用色彩 LUT 代替源逐像素全光学。执行不了时明确给出错误并允许用户显式选另一模式。
8. **默认原版不被“受控测试设置”永久取代**。seed=8888、单线程 Numba、ACES 替代默认 CAM16 只能用于明确标注的受控路径；最终必须单独处理原版无固定种子、多线程 prange 的真实默认行为。对非确定性结果应区分算法/分布一致性和有种子可重放时的逐样本一致性，不虚构无种子的逐像素等价证明。
9. **每模块仅用以下状态**：「完整移植」（全部原版功能分支/输入边界/默认值和生产调用路径真实存在）、「数值等价」（注明固定源 SHA、设备、样本范围与门限，独立 Python 对照通过）、「近似实现」（存在算法/随机/色彩/精度/后端差异）、「尚未移植」（仅有原型/测试或生产缺失）。状态有严格测试范围，不因为 8/8 UI 诊断、视觉类似或 App 构建成功而自动升级。
10. **可维护性**：保存上游 Python 文件/函数/源 Git blob SHA 与 Swift/C++/Metal 模块映射；每次变更展示 source diff、数值差异、影响路径与需要重跑的测试。不自动改基准。
11. **设备/内存**：始终兼容 iOS 16.5.1；保留原始尺寸、智能安全最高 1200 万、经济最高 720 万像素的用户选择，并按实测/估计可用内存做前置保护。不调整算法代替内存错误，且安全上限不是保证输出值。
12. **UI 功能不回退**：保留悬浮预览、双拨轮、可重置参数、直接导入文件/相册、专业相机、RAW 文件保存、高清导出、保存相册与分享，UI 崩溃回归须进 CI。
13. **发布硬门槛**：真实改码→原版 Python 参考→独立 Swift/C++/Metal 数值及统计对照→iOS 16.5.1 真机测试→iPhoneOS Release 编译→IPA 身份/架构/版本与 GitHub Release SHA 校验。无法达到全原版认证则仅发布明确未认证实验版，签名状态真实说明。

## B. 路线图逐项执行（严格依赖顺序）

状态约定：**已接入/已有测试**仅用于描述现状，不自动等于全面完整移植。新功能在满足全部分支前，仍按四状态制登记。

### 第 0 组：工程与源证据基础（先于新算法）

01. 固定上游 Python 提交、文件 blob、profile/滤镜/数据 SHA、NumPy/SciPy/Numba 版本与完整依赖图；上游变化仅报告，不自动更改基准。
02. 建立 Python 每一处理 tap 与 iOS 同阶段数据的映射：RGB_IN → RGB_PRE → LOG_E_FILM → CMY_FILM → LOG_E_PRINT → CMY_PRINT → RGB_OUT；负片、正片、单独扫描分支全部涵盖。
03. 映射原版 RuntimePhotoParams / 参数 digest / 各胶片专属参数预设 / 默认开关与互斥规则；杜绝 UI 有控件但生产算法没有使用。
04. 对全部 28 个胶片/相纸 stock 数据及 81 波长实测参数逐项核验来源、Float64 字节、端点与许可说明；原有诊断与快速模式保持原样。
05. 建立每个 tap 的独立 Python fixture 生成与 SHA，记录 MAE/RMSE/max、色差、随机分布、边缘、内存和耗时；失败终止认证。

### 第 1 组：真正的原版输入、精度与色彩

06. 8-bit JPEG/HEIC/PNG 文件来源、Exif 朝向、Alpha、sRGB 像素保真与 ICC 行为；现有源像素路径须扩展各种边界。
07. 16-bit PNG/TIFF、Float16/Float32 TIFF、扩展动态范围及原版可写的 EXR；逐格式检查 iOS16 ImageIO/CoreImage 的真实支持，不可先强制压为 RGBA8。
08. 输入色彩空间与传递函数完整映射：sRGB、Display P3、ProPhoto RGB、ACES/ACEScg、Adobe RGB 等；明确 encoded vs linear、色度适应和源值域。
09. RAW 文件识别和后端矩阵：DNG/Apple ProRAW、X-T5 RAF（未压缩与压缩分开）、CR3、NEF 等；优先 iOS16 CIRAWFilter，不能支持的优先评估原生 LibRaw；每格式/机型实测，失败不伪称支持。
10. RAW 真正的场景线性处理：black/white levels、Bayer/X-Trans 去马赛克、相机矩阵、自动/原片白平衡、曝光、色温、Tint、噪声处理可控，桥接源期待的 ACES 或其他原版 RGB。
11. RAW 元数据与镜头校正：EXIF/IPTC/XMP、镜头型号、焦距光圈、焦外/渐晕、色差/畸变/geometry；优先原生等价 Lensfun，明确未覆盖的校正步骤。
12. Python rawpy/LibRaw 与苹果原生 RAW 后端执行逐阶段/整图对比，记录不同后端、不同 decoderVersion 的差异；若不等价，标记近似实现，不能因为 Core Image 可用就升级为原版数值等价。

### 第 2 组：几何、预览、原版相机光谱前处理

13. 原版 crop_image 中心/尺寸/边界/round 的精确实现，resize 的原版 skimage order=3 行为以及 resize 前后 pixel_size_um；不将 Lanczos 悄悄当作原版。
14. 小预览原版最近邻缩放、原图/预览的一致性边界、曝光测量 256 长边与缓存失效；和实际 UI 预览分开测试。
15. 原版 auto_exposure 各计量模式与 CCTF / RGB→XYZ 的实测像素对照；保持正确顺序：测光在光谱转换之前。
16. 输入色域完整压缩 xy、Oklch 分支、Reinhard 膝部、源光谱边界与 LUT 烘焙/重映射；未实现前不能默认当作已有完整。
17. Hanatos2025 完整色温/色适应 window/surface、spectral Gaussian、输入光谱 LUT 生成和缓存失效；默认值与每胶片敏感度一致。
18. UV/IR 原版滤镜同时支持 Mallett2019 和 Hanatos2025；Hanatos 需要按过滤后的敏感度重算 TC LUT，不能拿无滤镜旧 LUT 冒充。
19. 摄影原版 camera RGB→RAW（Hanatos/Mallett 选择）、相机 EV、高光 boost、RAW photon 零值与 log10 边界；现有实现按每条可选分支补全。
20. 摄影四家族扩散、镜头高斯、乳剂 scatter / halation 反射和多次 bounce；检查 Float64 FFT 与 SciPy 反射 padding 以及大图保护。

### 第 3 组：胶片显影、九亚层颗粒与原版随机流

21. 原版 256 点 H-D 测量曲线、density_curve_gamma、片基密度、负片/正片、Float64 非单调数组 searchsorted[0,256) 和端点。
22. DIR couplers 同层/层间反应、抑制、扩散、完整空间核；原版 FIR (<3)、YVV IIR (>=3) 四遍反射边界不得切换假高斯。
23. 胶片颗粒原版密度→三亚层转换、Poisson→Binomial 全图顺序、saturation/uniformity/density_min、sublayers_active、n_sub_layers 等全部分支。
24. 原版 SciPy 颗粒采样器：各速率分支、完整 NumPy/SciPy RNG 状态、随机调用次数、每层 seed 规则、长尾/极值、大图内存；以逐样本固定流和分布双重验证。
25. 原版 Numba fast_stats 路径：Poisson、Binomial、normal cache、阈值分支、单线程受控 seed，与 SciPy 路径严格隔离；补齐真实源 use_fast_stats=True 生产入口。
26. 原版无固定种子多线程 prange 随机状态：尽量重现原始各线程状态/执行语义；若跨平台线程调度不能逐样本等价，保留源算法及其随机分布，同时提供独立可复现受控模式；不得将固定 seed=8888 伪称原版默认。
27. 染料云逐层 sigma、Gaussian reflect 卷积、微结构 lognormal 与激活阈值、最后空间 blur；保留 Python 操作顺序和全幅边界。
28. 四个及以上独立原版完整颗粒→相纸→最终 RGB 图片样本回归，并增加实际 8MP/12MP 图像、随机统计、接缝、最大差异与峰值内存测试。

### 第 4 组：原版光学放大机、相纸、滤镜、校准

29. 负片→光学放大机、直接正片扫描的分支；每个分支都按 Python topology 原序执行。
30. 全部放大机光源与实测滤镜：TH-KG3/TH-KG3-L、镜头透光率、neutral CMY database、个性化 CC 调整、preflash、EV 与 reference midgray。
31. 原版 film CMY→纸张 photon 的光谱积分、波长过滤、preflash 真实影响与归一化，黑/白曝光参考校正；不能只做 RGB LUT。
32. 印相四家族 2D Double diffusion：位于 paper raw photon→log10→paper H-D 之间，原版完整 PSF、反射 FFT 和内存边界。
33. 相纸 H-D 实测曲线、absolute/相对密度、打印 morph curves 全参数与每张纸的原版裁剪/端点。
34. 原版印相/拍摄/扫描相关 white/black reference 全部校准分支与默认参数，恢复当前受控物理模式中明确关闭的分支，必须逐 tap 验证。

### 第 5 组：扫描、色域、输出与完整文件行为

35. 负片/正片基片密度→完整光谱 XYZ：查看光源、CIE 观察者、积分与归一化、使用原版原始数据。
36. 原版扫描 glare：lognormal 随机场→reflect FIR/YVV→乘 illuminant XYZ，必须在 XYZ→RGB/gamut 前应用；同时提供原版默认随机行为和受控种子。
37. 扫描 lens blur 与 unsharp mask：在线性 RGB 内按原版顺序作用，随后执行 CCTF；检查高分辨率扫描内存。
38. 输出色域压缩全部算法与参数：默认 CAM16-UCS 逐像素及其光适应条件、Oklch、Oklrab、JzAzBz、ACES RGC、off，包含 lightness_compression 与源 Cmax 缓存；当前 33³ CAM16 只能算插值近似。
39. 输出空间 sRGB 及源允许的其他 RGB/ICC、encoded/linear、色域内/外的数值处理；保留曝光超白和负值，不提前裁剪。
40. 文件输出所有源允许格式与位深：JPEG、PNG、TIFF 8/16/32、EXR（在许可与 iOS 静态库允许时）、对应 ICC/EXIF/XMP 和真实的 8/16/32 位编码；同时维持 iOS 相册、Files 分享和 98% JPEG 的现有交互。
41. LUT/缓存/快速预览：按原版 LUT 分辨率、线性三角/三线性插值、重新计算条件、invalidations、局部调整/taps 确认；原版完整算法仍为主模式，快速 LUT 不代替默认源计算。

### 第 6 组：真正的 iOS 原生加速、真机认证和发布

42. 全光学 CPU Double 对象/缓冲池、已验证 SIMD/Accelerate 加速，复用 memory scratch；保留数学算法和浮点结果误差上限。
43. Metal 优化原版 FIR/YVV、积分及颗粒可并行子步骤；单独验证 Float32 差异，无法数值等价的计算仍停留 CPU Float64；不承诺完整原版 GPU 计算。
44. 大图全链路内存预算：1/2/4/7.2/12/13MP、多种胶片和完整源颗粒、光晕、diffusion 的峰值记录；不足时报错，禁止静默切换模式；用户明确选择预定分辨率。
45. 完整 Python source → iPhoneOS Swift/Metal staged tapes：每个 source tap 的尺寸/浮点范围/MAE/RMSE/max/色差/随机分布/边缘 seam 分别核验，覆盖 RAW/高位深/广色域。
46. iOS16.5.1 真机 GUI 和文件完整回归：拍摄、导入、悬浮预览、胶片与相纸拨轮、菜单、滑块数值复原、双击名称复原、高清输出、相册保存、File分享及重复切换无崩溃。
47. 构建门槛、来源记录、签名和 GitHub Release：对应提交 SHA、iOS minimum 16.5、arm64、编译/测试日志、完整数值证据、实验/认证分别发布；真正未签名 IPA 必须说明安装前需签名。

## C. 建议批次（只有前一批通过对应验证，才推进下一批）

| 建议批次 | 工程工作项 | 必须产出的证据 |
|---|---|---|
| Build77 | 01–05 源基准/全部参数/原版拓扑/验证框架 | 完整源映射与每 tap 源 fixture |
| Build78 | 06–08 8/16/32 位输入和宽色域 ICC | 输入精度、方向、色彩矩阵、ICC 测试 |
| Build79 | 09 RAW backend：DNG/RAF/CR3/NEF 分类支持 | 真文件解码与 unsupported 明确报错 |
| Build80 | 10–12 RAW 白平衡/色温/tint/镜头矫正/后端差异 | 实测 RAW 与 rawpy 分阶段对照 |
| Build81 | 13–16 原版裁剪/resize/preview/输入色域压缩 | 像素几何、源反射/取整与输入 xy 证据 |
| Build82 | 17–18 Hanatos 适应/光谱滤镜/重建 TC LUT | Python 精确 81 波长/光谱基准 |
| Build83 | 19–20 原版相机曝光、摄影扩散和光晕各分支补齐 | 独立 Python 2D/FFT/胶片 RAW 等价 |
| Build84 | 21–22 胶片 H-D/DIR 原版完整多分支 | 256 点曲线、2D FIR/YVV 数值一致 |
| Build85 | 23–25 颗粒 3×3/SciPy/Numba fast_stats 全分支 | 两类 RNG 分开精确固定种子对照 |
| Build86 | 26–28 Numba 多线程随机真实语义/染料云/整图 | 原版默认随机分布及可控回放证据 |
| Build87 | 29–34 放大机/印相/源黑白校准/纸张 morph | 负片/正片/相纸 Python stage tapes |
| Build88 | 35–37 原版扫描 XYZ、随机眩光、镜头与锐化 | 源级 XYZ→RGB 数值/随机验证 |
| Build89 | 38–39 CAM16 默认与全部输出色域算法 | 色差、色域、黑场和逐像素基准 |
| Build90 | 40–41 全部输出文件、元数据和 LUT 原版模式 | 多格式 bit depth/ICC/EXIF 测试 |
| Build91 | 42–44 Double CPU/Metal 加速及大图内存 | 性能实测、等价证明、内存峰值 |
| Build92 | 45–47 真机端到端认证/回归/Release | 完整 Python 对照+同 SHA IPA/签名状态 |

**注意：Build77–92 是建议的依赖顺序和候选批号，不代表一次提交就能完成每批，也不预先宣称各项通过。失败可在当前批内修复和追加补充版本，不允许自动跳过缺口。**

## D. 需要明确避免的伪结论

- iOS16 支持某类 RAW ≠ 该机型/压缩格式必定支持 ≠ Core Image 输出等于 Python rawpy。
- Python 原版包无法直接运行在 iOS ≠ 该功能不能移植。
- Metal 缺少 double ≠ iOS 缺少 Float64 CPU 计算。
- 单线程 seed=8888 数值通过 ≠ 默认无种子多线程随机流等价。
- 4 张小图 7,053 RGB 通道通过 ≠ 全部 12MP/RAW/广色域/设备组合已认证。
- 完成 iPhoneOS build 和 unsigned IPA ≠ 已完成签名、设备安装或全原版科学认证。
- 最高 1200 万/720 万像素是导出档位上限 ≠ 开全光学颗粒保证达到这些像素。

## E. 下一步唯一执行起点

**Build77 第一目标为 01–05 的完整源代码/参数/拓扑/证据底座。** 在这个审计补齐过程中，可并行准备 06–12 的真实测试图片和 RAW/ICC fixture，但不能在未证明源行为前发布所谓“RAW 原版等价”功能。

后续开发必须以本文的条目编号引用当前任务、上游源位置、iOS 文件、状态、测试门限和失败边界，并在后续文档中附版本记录；只有用户明确改变标准时，才修改本文的项目原则。

上游：https://github.com/andreavolpato/spektrafilm
iOS 项目：https://github.com/78849527/spektrafilmiOS16.5.1
