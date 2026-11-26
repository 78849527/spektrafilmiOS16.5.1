# iOS16.5.1 原版移植：性能与内存专项任务清单

基线：v1.8.108 Build142 / 44036842de68ca9288a69694e3381e0b302c9a8b。原开发分支继续，固定上游 3bb2c2d，遵守 DEVELOPMENT_PRINCIPLES.md 与 47 项路线图。不改变原版科学算法，不静默降级。状态：待实施 / 已提交候选 / 数值验证 / 真机认证；后两者必须有实际证据。

| ID | 任务 | 路线图 | 状态 | 验收标准 |
|---|---|---|---|---|
| OPT-01 | RAW 解码/线性输入缓存 | 09–12,41 | 已提交候选：快速预览单条线性输入缓存；全尺寸缓存待实施 | 同文件同裁切输入 bitwise；文件/几何变化失效；内存警告回收；精细导出仍真实 RAW |
| OPT-02 | 过期冲印取消及调度 | 42–46 | 已提交候选：RAW 编辑预览取消、预览/JPEG/TIFF16 互斥、核心像素循环检查；全部任务与导出优先待实施 | 连续调整、换图、删除、导出竞争测试；无过期结果；峰值不叠加 |
| OPT-03 | 分阶段动态内存账本 | 42,44 | 已提交候选：逐阶段模型/生产预算对照与报告；放宽预算待实测 | 生存期与实测 phys_footprint 一致；保留 70/80% 门限直到证据支持变化 |
| OPT-04 | 独立解码、裁切、预览、光学与导出尺寸边界 | 09,13,44 | 已提交候选：解码/预览/裁切与光学工作尺寸分离；全幅固定上限待处理 | 取消无依据固定上限；保留 checked arithmetic/FFT 安全边界及动态拒绝；不自动缩图 |
| OPT-05 | Float64 固定长度向量/SIMD/原地运算 | 42 | 已提交候选：两个热循环复用 RGB scratch；SIMD 待验证 | 逐 tap 独立 Python 对照、无静默精度变化、真机耗时 |
| OPT-06 | Accelerate Double FFT | 20,32,42 | 已提交候选：显式测试后端；生产仍为原版 Swift FFT | 固定完整 PSF/反射边界/采样/归一化；Python 数值与真机基准；原版回退明确 |
| OPT-07 | 光学阶段缓存与依赖失效 | 03,41 | 已提交候选：确定性 PSF 缓存；整幅阶段缓存及随机状态依赖待验证 | 所有参数、源版本、随机状态、全幅几何参与失效；缓存/冷启动数值一致 |
| OPT-08 | DIR 关闭时无用整帧缓冲 | 22,42 | 已提交候选：生产无零帧，诊断保留零 tap，分配推迟 | DIR off/on、负片/正片、诊断 tap 独立回归；仅减少分配 |
| OPT-09 | 真机内存/耗时诊断 | 44–46 | 已提交候选：RSS/phys_footprint、阶段模型、真实参数准入；持续压力待实施 | RSS/phys_footprint/headroom、逐阶段峰值、取消回收、持续冲印报告 |
| OPT-10 | CI 公共脚本、Apple Silicon 优先 | 47 | 已提交候选：共享17门槛、Apple Silicon优先、集中验证不发布 | Python 3.11/Numba 0.61.2 不变；arm64 iOS16.5；保留所有历史独立数值门槛 |
| OPT-11 | ContentView 职责拆分 | 46 | 已提交候选：独立系统文档/分享适配器；其余模块待渐进拆分 | 状态与 UI 行为一致，分模块渐进重构 |
| OPT-12 | 历史实验/诊断/分支治理 | 01,45,47 | 已提交治理清单；历史代码/工作流/分支未删除 | 证据归档、去重复；不删除有效回归，不未经批准删除分支 |

## 首批候选修改

- OPT-01：只缓存 Build139 未经光学处理的线性 Double 快速预览输入，单条最多 40 MiB；文件路径、设备号/inode、字节数、修改时间、裁切、长边共同作为键。新照片/删除/完整精细预览/导出清除缓存；原片、完整光学与导出不改。文件元数据不可取得时不缓存。现有 Build139 数值测试增加位级一致、CoW 隔离及失效测试；未运行。需要真机验证缓存占用及内存压力清理。
- OPT-02：编辑器 RAW 预览任务显式持有句柄，换参数/刷新/失效时取消。RAW 编辑预览与 JPEG/TIFF16 导出使用同一互斥入口，包括输出打包；过期任务等候前后检查，核心像素循环每 4096 像素检查，主要阶段边界检查。LibRaw 原生调用、长滤波/FFT、非 RAW 预览与诊断尚未实现中途取消/统一优先级；不能宣称所有任务已串行化。
- 既有 Build139/140/141/142 认证与数值流程保留；Build141 源码门槛补充缓存分支几何核对。只提交源码，不触发逐项 IPA 构建。

## 第二批候选修改

- OPT-03：生产 MemoryEnvelope 提供八阶段 B/px 候选模型以及真实现行准入 B/px；基准使用生产 104 B/px，历史 120 B/px 诊断保留其历史语义。阶段估算不包含 FFT，观察器内存独立保留，尚未作为准入依据。Build140 256 组合测试扩展；未运行完整测试。
- OPT-08：DIR 关闭且没有观察器时不分配 inhibitors/diffused 整幅零数组，保留减 +0.0 的算术；开启时延迟到摄影光学结束再分配，所有原版滤波及 tap 语义不变。真机峰值及原版对照未认证。
- OPT-09：Build133 schema 2 增加 25ms physical footprint 与阶段采样、候选/准入模型；预算预检改用当前实际 optical parameters，工作尺寸在 Double 分配前检查。未测 iOS Darwin API 实际返回，采样不等于真实 Jetsam 高水位。

## 第三批候选修改

- OPT-04：快速预览源允许现有 LibRaw 45MP/10k 解码边界和原有 70% live headroom gate；确认裁切后按裁切工作尺寸进入原版光学，复制 packed crop 前检查可用内存。裁切几何仍受 Build81 的 8192 单边保护；全幅光学 13MP/8192 和 70/80% 门槛仍保留。无自动降级，尚未认证真实大尺寸 RAW 导入/预览/导出；新增 24MP 源、6MP 裁切几何测试。
- OPT-05：光学两个逐像素热循环复用 3 个 Double 的 Array scratch，不改变逐通道减法、浮点位深、随机顺序或 H-D/光谱函数；真实加速需编译与基准。
- OPT-06：Accelerate vDSP_fft_zipD 显式测试后端，保留原 Swift reference 默认，复用 setup，使用相同 PSF、反射、FFT grid、卷积与混合。四个现有原版独立数值样本增加候选与 reference 对照；Apple SDK 编译、Python 数值及真机内存/速度未验证，不接入生产默认。

## 第四批候选修改

- OPT-07：单条不超过 1 MiB 的 PSF 缓存，只缓存确定性 kernel；family/active/几何/pixelUM/全部 Double 参数按 bitPattern 匹配，冷/热输出逐位比较，参数和几何变化检查。内存警告清除 PSF 与 RAW 预览缓存，PSF 缓存 generation 阻止清除前旧任务重新填充。全帧、随机颗粒、扫描眩光等状态不缓存；尚未认证。
- OPT-10：Linux 与 macOS 重复的 17 项源码门槛移入共享顺序脚本（失败即停），原门槛保留。Apple Silicon 优先（Intel 手动可选）；Python 3.11/Numba 0.61.2 不变，扩散独立 Python oracle 加入集中验证。push 仅验证及 iPhoneOS 编译，不打包/发布 IPA；手动发布必须明确开启，正式新版本需统一升级版本号与标记。
- OPT-11：ContentView 末尾两个 UIKit 系统适配器原样移入 EditorSystemSheets.swift，仅放宽到模块内部访问，不改导入/分享语义，原严格范围门槛只新增此文件。
- OPT-12：建立历史治理清单，所有既有证据、诊断与工作流保留；没有删除分支或未经认证的科学实现。历史清理待实际回归后分项执行。
- 兼容性门槛修正：P1 原片未裁切仍受光学尺寸上限，裁切/预览分离 decoder gate；更新旧文本断言验证真实分支、裁切后的全光学预算及无自动降级，不删除保护。

## 集中验证记录（2026-11-26）

- 45763169587 / f93f61b：Linux 前置检查失败于拆分后的 raw_picker_all_files，macOS 未执行；0f18157 修正历史门槛的实际文件位置。
- [45763431466](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/45763431466) / 0f181570506c16c2373348d5aea8fc4603167993：Linux、macOS arm64 两任务 success；Xcode 16.4 BUILD SUCCEEDED、原生 LibRaw、256 内存选项、Build139/141、独立 Python 扩散四族、缓存冷热位级及 Accelerate 候选对照均通过。生产 Swift FFT 与原版 Python 四族最大绝对误差 1.78e-15（门槛 1e-12）；候选 Accelerate 对 Swift 通过现有测试门槛 1e-10 相对/绝对混合，不冒充 Python 直接对照实测误差。Oklch 96、TC 4038、CAM16 216、原版随机与光学参考门槛通过。未构建 IPA，未实机认证。
- 本轮后续候选：RAW 预览缓存增加 generation lease，清除后拒绝旧任务回填；预览缩减及原始 Float32→Double 解包循环可取消。新增旧 generation 拒绝回填测试。与上述已通过 SHA 区分，需重跑；不改变浮点运算顺序。全尺寸缓存、SIMD、动态尺寸、整帧复用和真机性能仍未完成。

## 第三轮验证与后续候选（2026-11-26）

- [45765344119](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/45765344119) / 8da030f89a165348f5b6e15504b65b9e2b873179：Linux 与 macOS 全部 success，缓存失效 lease、输入取消、独立数值回归及 iPhoneOS arm64 完整编译通过，未打包 IPA。
- 本轮新增候选：OPT-04 16/24/32MP 仅 dry-run 试算与充足/不足 headroom 回归，仍保留生产 13MP 以及各模块 8192/FFT 几何门槛；不将试算视为大图已可导出。
- OPT-08 眩光二维随机场改为单通道原版 FIR/YVV，保留随机抽样顺序及 /100。原局部滤波缓冲模型 64 B/px -> 16 B/px（13MP 理论少 624MB，非 RSS），仍保持旧生产 96B/px 眩光准入系数，实际内存与速度待测。新增 120 组旧 RGB 对照（6种几何×10个sigma×2种roughness，每组注入/seed），并减少 DIR-off 每像素无用零数组创建。需重跑 CI；不替代真机认证。

## 第四轮失败及修复（2026-11-26）

- [45766811206](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/45766811206) / 9fdd5d1：Linux 通过，macOS 第16步编译失败，MT19937 的 GeneratedSourceMT19937Reference 尚未生成；未执行新增眩光数值回归或最终编译。
- 将新增眩光独立测试移至真实 NumPy/Numba fixture 生成之后，旧单通道 FIR/YVV 测试仍原位执行。明确链接 generated MT19937 与 glare 参考，同时新增 6 组固定原版 Python 眩光与 XYZ 对照；120 组新旧 Swift bitwise 对照仍保留。没有伪造或绕过参考类型。修复提交待复验。

## 第五轮通过与全尺寸 RAW 缓存候选（2026-11-26）

- [45767790114](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/45767790114) / 4ee08ed3c547d8b3b42f1024c9e03fcba5b201e0：Linux/macOS success，120/120 单通道眩光 bitwise；独立 Python 6组 maxAmount=2.6020852139652106e-18，maxXYZ=1.1102230246251565e-16；16/24/32MP dry-run 与低内存拒绝通过，Xcode BUILD SUCCEEDED。
- OPT-01 新候选：完整精细 RAW 预览可保留一条原始 packed ACES16 解码结果（6 B/px），使用文件元数据 + 流式 SHA256 标识；导出或后续完整预览 take 消费，仍执行完整 Float64 光学和实际内存门槛。仅在 packed bytes <= 当前剩余 headroom/5 时保留（缓存策略而非生产准入上限）；换图/内存警告/快速预览清除；generation 拒绝旧任务回填。快速缓存仍独立；不缓存全幅 Double、输出、颗粒或其他随机状态。新增 exact bytes、内容变化、低内存、失效测试。真机缓存命中率、耗时与内存仍待测；当前候选需重跑 CI。

## SIMD 光谱积分候选（2026-11-26）

- OPT-05：印相光谱累加 printRaw、实际扫描 XYZ scanPhysicalXYZ 改为 SIMD3<Double> 三个独立通道；保留 81 波长顺序/有效掩码、标量密度逐通道求和、pow、clamp、归一化和 CCTF；不横向归约、不显式 FMA、不改随机过程。旧移动 scanLinear 不变；共享 printRaw 的兼容 clamp 分支同样接受 bitwise 验证。
- 增加真实生产 helper 抽取编译 -O/-Onone 各384组逐波长 bitwise 检查，以及 SourcePhysicalImageParity 内全部实测材料、两种输入精度、三组密度和 clamp/epsilon 分支的旧标量对照。后者需完整源整图诊断实际运行，不能将编译当作执行。A15 速度未测，SIMD 并不保证更快；待 CI 与设备认证。光学全帧中间阶段复用仍待实施。

## Build143 集中真机候选（2026-11-26）

- [45769345496](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/45769345496) / 8159e9f：Linux、macOS 和完整 iPhoneOS arm64 编译均通过。全尺寸 packed RAW cache 独立回归通过。
- SIMD 候选 189b5ac 合并入此次 Build143（1.8.109）；新独立门槛仍必须实际通过。用户要求必要时构建 IPA，因此本次 head commit 使用 [device-ipa:143] 一次性明确发布标记；普通后续 push 仍只编译。版本/架构/真实 Xcode/完整 SHA 与 ZIP/哈希检查全部通过才发布唯一未签名候选。无设备性能或 RAW 原版认证声明。
- 真机优先：同一 RAW 冷/热快速和完整预览、同设置原尺寸 JPEG/TIFF16、裁切、8/10/13MP 内存阶梯报告及原版分段对照。Accelerate 不作为生产默认；尚需独立设备性能对照，未解除生产 13MP 尺寸约束。

## Build143 真机反馈入口补充

- 用户要求无需手工记录：新增高级/验证状态报告中的「导出性能反馈 JSON」，记录真实 RAW 快速/完整预览及 JPEG/TIFF16 导出，按操作 ID 保存缓存命中/未命中、真实运行阶段、耗时、阶段 RSS/physical footprint/available 快照、失败/取消。仅本地保留最近 160 个事件，阶段原子写入，闪退后可读检查点；不包含原图、文件路径字段或 RAW 哈希（底层错误文字可能包含文件名）。阶段快照不等于连续采样峰值，Build133 原有专项报告仍保留。日志写入开销计入耗时，失败仅影响记录不影响光学算法。
- 本次为用户要求的真机反馈补齐，原 Build143 构建尚未完成时更新同分支，重新完整 CI；仅成功后发布 exact-SHA IPA。

## Build143 真机反馈驱动优化（2026-11-26）

- 已发布 8e280c8 / CI 45771056174，用户真实 iOS16.5.1 日志：3024×4032，quick 5.017s；full 46.233s（无颗粒阶段）、67.704s（含颗粒）；JPEG 68.562s（含颗粒）；后者物理 footprint 阶段最大 1,407,013,504 bytes，颗粒 scratch 释放前后减少 683,148,544 bytes。完整输入准入 cold 0.654s vs hit 0.033s；JPEG miss，未确认 eviction 原因。样本非同参数 A/B、非连续峰值，不认证原版整图或加速收益。
- P0 颗粒：新增 production channelSublayersInto，纯实测 H-D 反演只做当前通道 3 亚层，避免原 3 次重复 9 亚层反演；使用完全相同的 searchsorted、端点和 Float64 插值。诊断仍保存完整九层，既有随机消费顺序和 memory ledger 不变；五组 Python 粒子参考中另测当前通道分支的调用次数、最终密度 bitwise。
- P0 Hanatos：4×4 Mitchell RGB 3 通道改为 SIMD3<Double> 独立累加，原权重、反射、遍历、total、末端除法保留；真实生成 Float64 LUT 每 stock/3 色域/521 输入与旧标量路径逐位对照，当前候选待 CI。性能未测，不认定必然加速。不发布新 IPA。

## P0 实图瓶颈优化第二批

- SciPy：全 Poisson 结束后将每个已消费的 seed 原地覆盖为 Binomial，避免同时保留两张 Int64 全图；理论少一张 8B/px 计数数组（1219 万像素约 97.5 MB）。原独立 Python 计数向量仍验证实际 drawLayer。未减少生产准入预算，峰值待真机测。
- Numba：独立 counts-only 两阶段路径同样复用计数数组，不改变原完整诊断双数组路径；并行 worker 只读原 rates/probabilities 的既有区间，不复制两张局部输入。原 worker 区间、种子和正态缓存顺序保持；新增 Python golden counts、后续 RNG 字、切片/区间与下一次 normal 的等价检查。实际并行调度仍不宣称原版逐位一致。
- H-D：Build84 动态 DIR 已准备的每通道曝光轴，逐段缓存原 1/dx（重复节点仍 0），保留 binary search、端点和 t*(y1-y0) 顺序；80 实测胶片设置的独立原版对照加旧标量 bitwise gate。实际耗时待测。
- 不改 13MP 准入、生产精度和原版 RNG 参数；此轮仅 CI，无 IPA。

## P0 实图瓶颈优化第三批：印相及扫描

- 每个光学 engine 准备一次有序、有效波长的紧凑 Row（Double 片基/三个染料吸收系数/SIMD3 Double 权重），当前负片印相及正片/相纸 XYZ 扫描的生产像素路径复用；放大机扩散前真实 paper photon 同样复用。保留 81 波长原掩码、三个密度加法顺序、pow(10,-density)、clamp、XYZ 归一化/CCTF、全部原始标量诊断及初始化参考。不是光谱近似/全图缓存。
- -O/-Onone 使用真实生产 helper 各 768 组独立标量 bitwise 对照；实测所有材料诊断追加真实 plan 对照。实际耗时及设备整图数值未认证。继续使用原生产 memory admission 与 13MP 界限。此轮仅 CI，不发布 IPA。

## CI 复验补充

- 45775750265：Linux PASS；macOS 止于历史 Build116 源码范围检查，明确拒绝三个新优化文件。未运行到这些模块的数值验证。只加入三个实际批准的文件路径，保留其余白名单，不降低任何数值容差。
- 将实际 SciPy golden、Numba counts-only golden/后续 RNG、80 个动态 DIR Python 原版用例的独立 Swift 可执行验证显式纳入本轮 macOS CI，防止仅编译测试源码却未执行。新印相扫描候选合并后统一重跑。

## 独立测试抽取修复

- CI 45776146149 Linux PASS，macOS 第12步抽取生产 helper 单独编译时缺少 Foundation import，导致 pow 不在作用域。修复生成文件 import；生产算法和测试阈值不变。重新运行后才可判断数值一致性。

## 确定性实测 H-D 中间量复用候选

- 原版 Profile 实测曝光轴与三亚层反演轴逐区间准备 Float64 1/dx，保持原 right-biased search、端点、不排序、不重采样、重复节点 +0.0 及原乘加式。移动 Float32 均匀插值不变；只缓存小型确定性系数，不缓存整图或随机阶段。
- 实际 helper -O/-Onone 测试非均匀、重复、下降和 signed-zero 区间；整图诊断新增全部真实材料节点/区间以及负片/反转片三亚层旧标量对照。后者须实际运行，不能把编译当作测试通过。
- 此候选不改变相纸独立 CDF 曲线、生产内存准入或原版随机参数。仍需 CI 及 A15 实际耗时。整帧阶段缓存需独立的源 SHA、裁切、参数依赖、随机态、内存与失效认证，暂不冒险启用。

## 后续验收

独立 Python 各 tap、RAW rawpy 实图对照、8/10/12/13MP、全光学及连续操作、A15 iOS16.5.1 实机。集中构建前更新此清单，记录实际测试结果、SHA、未认证项与真实 CI/IPA 状态。
