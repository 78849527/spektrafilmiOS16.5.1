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

## 真机反馈诊断细化候选

- FullInputCache 记录实际 store 结果、命中/未命中及清除原因；原租约/所有权/预算不变，旧租约不能覆盖新内存警告/切换快速预览原因。报告仅记录固定状态标签，不写原片名称、路径、哈希。独立 Build139 测试验证 actual store/拒绝、内容变化、memory_warning 和 stale lease。
- RAW 报告补充光学选项、EV、是否裁切、颗粒模式等，用于区分非同配置测试；增加实际 engine 构建、参数准备、相机预光学、印相扩散、相纸扫描、眩光、色域、镜头阶段快照。保持原有阶段名与观测顺序，不增加整图副本。非颗粒且非扩散的融合循环仍为融合耗时，不能据此分离 H-D 与印相。阶段快照仍不是连续峰值。
- 本次不改变光学算法、源 RNG、内存准入或 IPA 版本；与下一批一起验证。

## Build144 集中真机候选与收尾范围

- 45782717432 / f2bbe6a：Linux、macOS 全部成功，真实原版 SciPy/Numba 计数、80 个 H-D 设置、Hanatos、紧凑光谱、Xcode arm64 通过。随后合并 e644250、5369030、1d85b00；新 SHA 必须再通过全部 CI。
- 三亚层颗粒 saturation 由原概率及 uniformity 按相同 Double 表达式重算，省 8B/px 整图工作区；与之前的 Int64 两阶段计数复用合计理论减少两个独立分配各 8B/px，12.19MP 约 195MB（不保证同时位于峰值、不可直接从实际峰值减去）。既有 Python grain.py 五组四阶段门槛必须通过。单层原版路径保持既有饱和度字段。
- 正常 RAW 编辑/导出自动采样 25ms RSS、phys_footprint、最低 headroom，完成/失败事件记录采样摘要；保留阶段原子检查点，崩溃仅能读最后持久化快照，非 Jetsam 峰值。FFT 专项按钮对同一固定 512×384 输入和四族 PSF 运行 reference/Accelerate，记录原版与候选误差及各自耗时，结果合入 JSON；不是整图 RAW 的生产 FFT 认证。正式路径仍默认 reference。
- 选择 1.8.110 Build144 唯一集中设备包，保留 Build143 对照。Apple Silicon、Python 3.11、Numba 0.61.2、deployment 16.5、原分支不变。发布只允许所有回归及真实 Xcode 编译成功，精确 SHA 绑定且未签名。
- 仍需实机证据：固定相同 RAW、胶片、相纸、颗粒及参数，测冷/热完整预览与原尺寸 JPEG/TIFF16，导出单份 JSON；如可执行再做 FFT 专项和 8/10/13MP 内存阶梯。13MP 生产上限、70/80% 动态准入及 phaseModel 仅遥测保留，不能凭理论节省解除。整图/随机状态缓存暂不启用（高内存/依赖失效风险）；非 RAW 任务全局调度、所有模块尺寸边界重审、全面 UI 拆分和历史删除均不是已完成项。不得把真机未验收项或编译通过当作原版整图认证。

## Build144 运行器重试

- 45784394788 attempt 1 和 2：Linux 通过，macOS 任务在无步骤记录、无可读取日志的情况下取消；未发现实际 Swift 编译或数值失败，具体取消原因无法确认。
- 第三次仅通过显式 [runner:intel] push marker 使用既有 macos-15-intel，默认仍为 macos-15 Apple Silicon。保留 Build144、iPhoneOS arm64、原版 Float64、Python 3.11/Numba 0.61.2、所有数值和发布门槛。一次性 [device-ipa:144] 触发相同版本新 SHA 的完整验证发布；无生产源码修改。

## Build144 真机证据及多核候选

- 两份重复日志，共 6 次完成，iOS16.5.1 12.192768MP；无颗粒精细 44.109s、JPEG 44.303s、TIFF16 47.369s，连续 25ms 采样 physical footprint 1013/1007/1019 MB；相机阶段 17.149s，DIR 4.313s，融合显影印相扫描 21.761s。引擎约 5ms，非瓶颈。JPEG 真实缓存命中，TIFF 消费后 miss。FFT 4 族通过 1e-10 门槛但候选 7.832s vs reference 3.915s，保留生产 reference，不宣称整图 FFT 认证。不同 RAW 不作为严格版本 A/B，九层颗粒尚未实测。
- 新候选：相机 Hanatos/初始 H-D/DIR 抑制及校正 H-D/融合印相扫描独立像素采用最多四线程、同步 bounded wave（每线程 32768 像素）、唯一 inout buffer 借用和不交叠写入。原标量算式共享，所有全图空间卷积及随机粒子顺序不变，任何 worker 错误抛出、父任务每 wave 检查取消。无整图新输出缓冲；观察器模式明确拒绝并行，不静默降级。生产默认 1 worker，尚未启用候选。独立 helper 测试与真实四组原版图像串并行 bitwise gate；后者需实际运行，A15 性能/内存仍待验证。
- 此轮 compile-only，未构建 IPA。先完成 CI，再集中加入设备对照入口。颗粒后的独立扫描循环和全图空间滤波尚未并行。

## 多核候选阶段二

- 相纸光谱计算抽为同一个只读 printPixel，受控颗粒（仍原随机数/原滤波路径）完成后才并行印相；原版完整相纸 PSF/反射 FFT 完成后才并行相纸 H-D/扫描。诊断保留串行及全部 paper tap；生产默认 1 worker 不改，CAM16、眩光、镜头、CCTF 与全幅空间滤波保持旧路径。
- 验证状态新增「Float64 串行 / 多核对照」：固定线性 ACES16 量化后 Double 测试图，1024×768 无颗粒与 512×384 受控九层颗粒+相纸扩散两个场景；每个先不计时串行参考，再依次 1/2/4 worker，逐 Double bitPattern 直接比较，并记录 maxError、耗时、实际阶段、25ms peak footprint/RSS/headroom。参考帧在所有计时试验中保留（报告额外字节）；不同 worker 的临时内存与速度仍需 A15 实测，非完整 RAW 或 Python 整图认证。
- 与原 RAW 互斥入口共用，结果自动并入同一 JSON，未修改用户设置。未经设备验证不切换生产线程数、内存准入或 FFT。一次集中 IPA 之前先全量 CI，当前候选不代表已通过。

## Build145 集中设备候选

- 45808271485 / 482ad5e：Linux 6/6 通过，macOS 未分配运行器；本次不声称新增并行路径已通过。集中候选 v1.8.111/145，一次性 [runner:intel] [device-ipa:145]，使用 Build144 已成功的 Intel 主机，不改变将来的 Apple Silicon 默认或 iPhoneOS arm64 目标。所有旧数值门槛及新增独立像素 worker gate、真实 Xcode 编译和 exact-SHA 发布门槛全部保留。
- 设备操作：高级 → 验证状态与诊断 → Float64 串行 / 多核对照，自动 1/2/4 worker 与两种固定输入场景；分享单份性能反馈 JSON。此次仅对照，不改变正式冲印线程数或用户设置；并行整图候选需设备数值、速度、内存证据，测试不能代替全尺寸 RAW 原版认证。

## Build145 A15 对照结论与串行热循环

- 真机 9903c72 / iOS16.5.1：固定无颗粒 1/2/4 workers 2.646252/2.859015/4.768409s，受控九层颗粒+相纸扩散 1.430958/1.452164/1.822058s；6/6 bitMismatches=0、maxAbsoluteError=0。无颗粒 4 worker 仅15个采样（约190个理论25ms周期），峰值不能严格比较；线程调度、ARC、热状态均是待验证假设。保持生产1 worker，不转正多核。
- Hanatos rawLanes 使用 SIMD3 XYZ/输出及 SIMD4 Mitchell 权重，消除 XYZ、两组权重、旧标量 scratch 和中间结果数组；保留零起始、RGB donor、16个 reflected taps、原 pow 与归一化除法、brightness 乘法。旧 scalarInterpolation=true 完整参考保留。Array API 仅在边界构建输出；所有实际测量 stock×3 color space 的扩充样本验证 bitwise，包括 signed zero 和极小值。尚未实测提速。
- DIR inhibitor 不再拼接 density+maximum+matrix+[shift] 临时数组，单独校验等价；按 donor 原顺序逐次 SIMD3 加权，保留 highExposureShift 的运算顺序和原标量参考。80 real-stock Python oracle 加精确位比较。不得宣称减少实际 ARC 或已经改善真机性能。
- compile-only，原分支、生产串行、原 FFT、Float64 和内存预算不变。下一阶段继续减少相机/印相 API 边界数组并改进交替测量。

## 印相扫描值类型优化

- 45823480259 / 90965d7：Linux 6/6、macOS 69 passed + 4 packaging skips，上一轮 Hanatos/DIR 数值与编译 gates 完成；非真机性能验证。
- PreparedSpectralSum 增加 evaluateLanes，保留旧 Array API 作为边界；原版印相把波长积分结果直接传至固定三通道曝光和 source CDF H-D，不再为 raw/log exposure 各分配数组（有真实 paper observer 时才转换 log exposure）。相纸扩散前光子与 scanner XYZ 归一化、log10→pow10 同样减少中间数组。保持原版两个 1e-10 floors、归一化除法、源顺序、libm 调用、原随机数及所有空间滤波。兼容印相、nil plan 原数组路径保留；无缓存语义变化。
- 相机 H-D 有限值校验不再拼接两个 3 通道数组。新增固定值/边界/符号零测试和实际 stock 印相 log bits 对照，继续 Debug/Release helper 验证及原版历史 gates。实际 A15 提速待测。
- 下一阶段审计 stage cache 的完整依赖键与逐阶段失效策略；本轮未实现整图结果缓存或线程转正，不申请 IPA。

## 胶片密度阶段复用候选 / 编译修复

- 45828944869 / 5e842b2：Linux 6/6；macOS 到 Xcode 编译失败，唯一定位错误为 preparedPrintSum 非 Optional 却使用 if let。改为直接使用已准备的不可选 plan，保留 printRaw nil-plan 参考；不删除数值 gates。
- 缓存依赖审计：正片黑白参考会影响 filmingExposureFactor，必须排除；负片印相参考与 paperEV 下游可独立。完整相机测光、boost、UV/IR、重算 Hanatos、Oklch、自定义 DIR、颗粒及随机状态暂不纳入。
- 实现局部 FilmDensityReuse 会话（无全局缓存、未接 P1/editor、未启用生产）。仅负片 Hanatos 单线程无颗粒/无相机前级/无参考校准子集；键含真实输入 Float64 字节 SHA256（含已裁切/缩放像素）、尺寸、filmID、输入色彩空间、EV、参考倍率、DIR 状态/半径/尾权/像素尺寸和 densityMin 精确位模式。条件不满足显式拒绝，禁止伪造 stage taps。
- 冷路径以现有计算分离胶片 CMY 与印相，热路径绕过确定性相机/DIR/H-D，按当前参数执行原版印相扫描；缓存只在整个渲染成功且未取消后保存。缓存申请额外 24 B/px 动态准入，不抵扣可能释放的内存；1219万像素约额外293MB，故先局部诊断。真实 fixture 增加 fused/cold/hot paperEV 修改逐位对照、输入变化强制 miss；这些设备端验证尚未运行，主机编译不等于执行。
- 后续需覆盖纸种/扫描设置变化与全部上游键失效、错误/取消/内存告警和 A15 实测；不接入正式 RAW，暂不发布 IPA。

## 胶片缓存局部会话失效与设备对照

- 1396446 后续：局部 FilmDensityReuse 使用 NSLock + generation，开始新交易或清理都会使旧 lease 失效。当前渲染成功且未取消后才尝试写回，过期拒绝；不会将失效归因为算法错误。仅设备对照局部注册 iOS memory warning 清理缓存，结束时注销并释放；无生产全局缓存。
- 实际 fixture 增加冷渲染中主动清理、过期写入拒绝、下一次必 miss、最终输出逐位相同。单独 UI「Float64 胶片密度缓存对照」，固定 1024×768 ACES 输入，每个 case 独立原版 fused vs split/hot：冷、相纸 EV、纸种、扫描 lens、相机 EV、DIR、输入变化、渲染中清理后重建、再命中；显式不支持颗粒测试。记录真实 bits、maxError、冷热耗时、温度状态、25ms memory；真机小图不代表全尺寸收益或 Python 认证。
- 与其他 RAW/FFT/多核诊断共享互斥，静态门槛明确六入口。仍不启用真实 RAW 缓存或改生产线程，额外 24 B/px conservative admission 不变。CI 尚待本提交执行；计划集中 Build146，未发布。

## Build146 集中设备候选

- v1.8.112/146：合并 Build145 后 Hanatos/有序 DIR、印相/扫描 Float64 值类型优化及局部胶片密度复用诊断。45833771720/ec0cbba 查询时 Linux 6/6、macOS 已进入真实 iPhoneOS 编译，尚不能宣称通过。集中工作流重新执行全部历史及新增 gates，再以精确 SHA 发布未签名 IPA。沿用已成功 Intel 主机，本次显式 [runner:intel] [device-ipa:146]；Apple Silicon 默认、iPhoneOS arm64、iOS16.5 部署目标不变。
- 设备测试：高级 → 验证状态与诊断 → Float64 胶片密度缓存对照；使用固定 1024×768 ACES 图，检查9个冷热/失效场景及不支持颗粒的拒绝；另建议同一 12MP RAW 无颗粒/九层颗粒精细预览与 JPEG/TIFF16，回传性能 JSON。固定图和真实 RAW 不混作同一 benchmark；不同输入不声称严格加速比。
- 生产仍串行，原版 FFT、颗粒随机序列、Float64、动态内存准入、13MP 几何门槛不变；缓存仅局部诊断，任何候选不自动转正。无真机报告不声称完整原版认证或实际提速。

## Build147 第一批：接入快速 RAW 预览的胶片密度复用

- Build146 真机固定 1024×768 ACES 9/9 PASS，zero bits；paper EV 2.148→0.977s、纸种 2.185→0.984s、扫描 lens 2.336→1.128s。不是全尺寸认证。首次建立有额外开销；仅验证无颗粒负片子集。
- P1 developPreviewWithGeometry 接入单条 reduced Float64 CMY 缓存，实际输入字节 SHA256 与既有完整依赖位键不变；上游不变/相纸等下游变动才命中。原版无缓存 fused 路径保留，不支持参数/身份/预算时只关闭缓存并重新执行完全相同原版计算，非模式降级。
- 额外 24 B/px 内存准入，预览 960×1280 约29.49MB；预留原有输入缓存与 COW，不抵扣。保留 live headroom/5 heuristic（仅缓存而非 render 限制），渲染后不足即清理。切换全尺寸、导出、源更换、内存告警与旧预览 input 清理同步清除密度缓存。任务在解码前持有 generation lease，解码途中清理禁止旧任务回填；测试覆盖 begin 前撤销与渲染中撤销。
- 正式 12MP full preview/JPEG/TIFF16 不使用密度缓存；颗粒之前缓存仍待单独随机状态对照。默认生产串行、原版 FFT、Float64、几何与内存限制不变。
- 本提交 compile-only，后续完整 gate 和真实 RAW preview 冷热测试才确认接入。不得根据固定小图推断全尺寸性能。

## Build147 第二批：颗粒前确定性 CMY 复用诊断

- 147-A / 8bf8a38 / 45853337916 Linux 6/6、macOS 69 pass + 4 packaging skips。生产 reduced preview 接入编译完成，未做真实编辑 A/B。
- 147-B 仅新增明确 opt-in allowSeededGrainDensityReuse（默认 false）；缓存仍在任何 SciPy/Numba 抽样之前，原有 24 B/px 保守预算和代际保护不变。颗粒开关、种子、粒子参数为下游；densityMin 位模式保守纳入键。无种子多线程不准入；P1 生产调用仍拒绝所有 active grain，full 仍不使用缓存。
- 原版 3×3 颗粒、fast_stats、单层和 microstructure 路径都重新调用原生产函数，不缓存输出、不重用 RNG 状态、不改变 seed/层序/滤波。扩展现有真机对照为8个固定 ACES 颗粒场景，测试开关、seed变化、粒子尺度、fast_stats、单层、densityMin失效、再命中；明确用 3000nm 诊断参数触发实际 Numba 抽样，不改默认30nm。核对独立完整渲染每一位、seed变化输出、实际颗粒阶段、内存及温度。历史 Python fixture 也增加 cold/hot 对照。
- 仅提交 compile-only；待 CI 和设备报告后决定是否接入受控颗粒快速预览。全尺寸与无种子颗粒尚未验证，不能承诺 22 秒节省。

## Build147-C 第一阶段：九层颗粒全幅模糊缓冲审计

- 原版固定 grain.py 的 add_micro_structure 与 apply_grain_to_density_layers 保留 lognormal → 全幅 Gaussian → 乘法、减 density_min → 最终 Gaussian 顺序、阈值、Float64 及通道/亚层 RNG。现有生产 3 亚层输入、复用概率/rates、Int64 counts、单通道 cloud 与释放动作均保留。
- 无 stage observer 时微结构 clump 与最终 out 是本函数局部拥有的数组，改用 Build114 已有全幅 diffuseInPlaceMemoryBounded；有 observer 时保留分配式参考，以免快照 COW 或影响独立原版 stage 对照。单层颗粒、随机采样、空间滤波边界、运算顺序不改。分配式滤波需要 2 个单通道 scratch + 1 个 RGB result，原位需要 3 个单通道 scratch；每次调用理论净少 16 B/px（12,192,768 像素约 195 MB），两处不累加，实际分配/COW、峰值及速度待 A15 实测。既有 224/56 B/px 动态 ledger 不减。
- 加强真实 Python 五组四阶段源测试：无 observer 生产输出与有 observer 分配式参考逐位相同；保留通道 writer 调用数及原 Python 容差。增加无尾部 FIR/YVV 和 micro sigma 的独立滤波对照；不修改门槛。待 CI；未发布 IPA，未修改 Build146 版本号。
- OPT-13 部分完成，后续检查计数/微结构实际生命周期与生产上游 COW；OPT-14 热循环、OPT-15 原尺寸确定性缓存仍待实施，未宣称全面认证。

## Build147-C 第二阶段：染料云 scratch 复用与确定性热循环

- 原版 grain.py 的九次全幅 dye-cloud Gaussian 继续使用同一标量 FIR/YVV 内核。实际源码先前每次分配一个 pixels Double intermediate；新增调用者独占 scratch，由首个有效 sigma 懒分配，每次第一遍完整覆盖，跨 9 层复用，颗粒采样结束前释放；observer 保留每次分配参考。最多避免 8 次 8 B/px 的重复分配/初始化（12.19MP 每次约 97.5MB），不是峰值降低；复用会使 scratch 跨后续 RNG 层存活，可能提高该阶段峰值，必须保留 224/56 B/px 准入并实测。若原尺寸峰值不利，重新评估或撤回该复用。
- 仅提取每通道 uniformity、每层 minimum/maximum，不将两次乘法合并，不用倒数替代除法，不改 clamp、计数和通道/层序；单层及并行 RNG 代码不动。
- Build116 60 组旧 RGB 对照增加 caller scratch 分支，每次填充 NaN 测试完整覆盖、跨尺寸、FIR/YVV 与零 sigma，逐位比较原 allocating scalar；五组原 Python stages 与 no-observer final bitwise gate 保留。实际 CI 与设备数值/峰值尚待确认。
- 上一批 CI 45867442160 查询时 Linux 6/6、macOS queued。为避免 concurrency 取消该独立回归，本次先提交源码及测试，不触发新工作流；后续批次统一触发完整 CI。

## Build147-C 第三阶段：借用已死 rates、微结构确定性系数

- 审计 SciPy drawLayer、Numba serial counts、Numba parallel particleLayer：返回 counts 前均已完成 rates 读取（parallel concurrentPerform 同步返回）。每次下一亚层准备循环完整覆盖 rates。因此生产染料云 intermediate 直接借用 rates，不再额外分配/跨层保留 cloudIntermediate；observer 保留原分配式路径。既有 counts、probabilities、层序、所有随机调用、全图 FIR/YVV 保持。不预扣 ledger，实际 COW/峰值待 A15。
- 固定 microStd 的 controlled serial lognormal 只在进入微结构时准备 sigma2、sigma、mu，逐样本仍执行原 exp(mu+sigma*z)，保留所有 RNG draws、有限值检查、阈值及原标量 observer 参考。不改 unseeded parallel 的已有准备方式。五组 Python stages/no-observer bitwise 再加 64 组 Float64 对照及 invalid/overflow 拒绝。CI 待执行。
- OPT-15 审计：当前 FilmDensityReuse 的 SHA256 包含完整已裁切输入 Float64，代际 lease、24 B/px 额外 budget、无颗粒且无相机前级等 admission 已有；P1 正式 full 仍与 preview 缓存隔离。原尺寸候选需要独立诊断而非直接打开生产 full，先验证动态准入及冷/热和告警清除，不将小图或 CI 当成整图认证。
- 前一 CI 45867442160 查询时 Linux 6/6，Apple Silicon macOS 仍未获 runner。本批合并已有全部 C 代码触发 compile-only，使用已验证 Intel macos-15-intel 备用（默认仍 Apple Silicon）；旧排队任务按现有 concurrency 被替代，不删除历史 gate，不发 IPA。

## Build147-D：原尺寸 RAW 缓存隔离诊断候选

- 45868857762 Linux 6/6；macOS 止于历史 Build116 白名单，明确唯一未批准文件 OriginalSourceMicrostructure.swift，尚未运行新增完整数值回归。仅准许该真实修改文件，原其他文件范围及全部数值门槛保留。
- OPT-15 新独立「原尺寸 RAW / Float64 密度缓存对照」入口，与现有 RAW 任务互斥；只接受当前真实未裁切 RAW、支持无颗粒负片 Hanatos 设置，原文件前后 SHA 身份确认，不自动改参数/缩图。独立会话非生产缓存，任何退出及 iOS memory warning 清理，沿用代际保护。
- 四次同一 ACES16 RAW：两次无缓存（当前 CCTF 与切换 CCTF），再冷缓存及修改 CCTF 热缓存。输出逐次释放，只保留全部 Float64 字节 SHA256；验证冷/热完整字节摘要相同且实际 hit，非逐元素错误统计或 Python 整图认证。记录各次阶段、耗时、25ms physical footprint/RSS/headroom。先额外 24B/px 动态准入，四次逐次复查，不抵扣现存缓存；内存不足明确拒绝，不算通过，不切换快模式。原生产 RAW 路径/缓存/参数均不变。
- 尚未实现原尺寸颗粒缓存转正、完整原尺寸失效矩阵或生产保留策略。先独立设备数据；CI 只验证编译及既有回归。原尺寸诊断可能因保守预算不准入，此为真实结果非故障掩盖。

## Build147 集中真机候选

- CI 45869569506 Linux 6/6，macOS 9 pass 后止于 OPT 静态源契约第14行：旧 full 函数截取包含新增独立诊断，错误匹配 filmDensityReuse。修正边界到 runFullDensityReuseComparison，保留正式 full 禁止密度缓存、七个互斥入口及各新增候选门槛。不改变任何数值容差。
- 集中 v1.8.113/147，显式 [runner:intel] [device-ipa:147]，保留 Apple Silicon 默认，真实 iPhoneOS arm64、Python 3.11/Numba 0.61.2、完整历史 CI；仅通过全部测试、真实编译和 SHA/版本核验才发布未签名 IPA。本次是候选发布请求，不表示已经编译或发布成功。
- 真机建议：先同一 RAW 冷热快速预览无颗粒；固定胶片密度缓存对照（9组无颗粒、8组受控颗粒）；真实 RAW 无颗粒原尺寸缓存对照；同 RAW 九层颗粒精细/JPEG，记录实际内存与耗时。原尺寸缓存拒绝必须记录，不视为数值通过。未认证候选不自动转正。

## Build148-A — Build147 真机证据与受限缓存转正

- 三份用户提交 Build147 JSON 均为 3c3bfb508978cf91fad0b72ba60ef9ff3c90ee77 / iOS16.5.1，按 runID/date/stage 去重。完整 17 项固定 1024×768 对照全部 bitMismatches=0；受控九层 3.9396→2.5392 秒、改种子 3.9383→2.5375 秒、改粒子 3.8494→2.5307 秒，FastStats 82.4674→81.0440 秒。首次诊断不完整；完整一次 242.50 秒。未测 unseeded 并行转正。真实 3024×4032 无颗粒完整字节 SHA256 冷/热均匹配，37.4301→16.2475 秒，冷建 43.8570 秒，峰值 1024.23→731.71 MB。实际快速预览命中 1.59–1.66 秒；颗粒 JPEG 65.01 秒，峰值 1416.06 MB，跨版同 RAW/温度未统一，不声明颗粒优化成功。
- 仅在原有 reduced RAW cache eligibility 中显式允许已验证的 seeded serial grain；原 RNG 每次重新执行，不缓存颗粒输出、不改变种子，不开放 unseeded。full 只开放未裁切、无颗粒、原有支持的 Hanatos 负片参数，使用独立会话和同一完整输入哈希键；24 B/px 额外动态 admission，不降低原预算。全局失效、切换 quick grid、异常、取消和导出完成释放，只有成功 full preview 在密度+packed 总量满足 live retention margin 时可保留。无已存 entry 的 export 不建缓存。缓存可选拒绝不改变算法。
- 本次提交仅 compile-only；真实编辑、全尺寸 preview→export、memory warning 与跨参数失效仍需真机验证，不称为完全认证。原尺寸颗粒缓存与非受控随机流保持关闭。

## Build148-B — 串行粒子计数生命周期

- 原版九层 ch outer / sl inner、整图 Poisson 后整图 Binomial、SciPy 每层固定 seed、Numba 同一 worker 连续状态保持不变。新增 drawLayerInto / runOriginalTwoPhaseCountsInto，调用者持有一张 Int64 counts，完整覆盖旧值，作用域内只读别名结束后供下层复用。仅生产串行采样使用，observer/并行原路径保留；微结构前显式释放。最多避免 8 次 8 B/px 重复申请（12.19MP 每次约97.5MB），不等于进程峰值下降。Swift COW 实际收益待真机，不下调 ledger。
- SciPy 原版 randomLogGam 固定系数从函数局部字面量移为静态只读数组，Horner 乘加顺序不变；删未读取 fractions 九元素数组。Poisson 新复用路径加入与 Binomial 相同 4096 间隔取消检查，不改变成功任务随机序列。
- 现有真实 NumPy/SciPy 参考计数和后续 MT 门槛保留，新增污染旧 counts 后重复覆盖；Numba 连续两层 counts、后续 uniform、normal cache 位级对照。完整五组 Python 粒子/微结构/最终密度和 observer/no-observer gate 保留。未运行本批测试，不声明速度改善。
- Build148-A CI 45876274875 查询时 Linux 6/6、macOS 21通过，仍执行；本批暂不改 workflow，避免取消正在跑的回归。后续合并触发。

## 后续验收

独立 Python 各 tap、RAW rawpy 实图对照、8/10/12/13MP、全光学及连续操作、A15 iOS16.5.1 实机。集中构建前更新此清单，记录实际测试结果、SHA、未认证项与真实 CI/IPA 状态。
