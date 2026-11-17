# SpektraFilm iOS 16.5.1｜原版优先：实验收敛与输入等价验收

基线：已发布 Build130（v1.8.96，实验性，非真机认证），在同一开发分支继续 Build131（v1.8.97）。历史 Release 保留用于追溯，不当作已通过的原版数值认证。

## 清理原则

- **保留**原版 Python 源码、胶片/相纸实测数据、光谱表、扫描参考、颗粒随机数种子/原版对照夹具、数值回归测试和已认证的 iOS 算法实现。
- **撤出生产路径**没有 Python 原版依据、会篡改原始像素值来通过限制的试验性转换（Build130 全图 Float32 RGB 仿射范围映射）；关联 UI、实现、验证脚本一并删除。
- **不清空**用户照片/RAW、DNG、已有配方、历史构建证据、原版基准。只清理本仓库已确认的非原版试验实现。Git 历史仍可追溯。
- **不将** Swift 现存约束写成“Python 原版要求”，未做逐阶段对比的实现仅可标记为“当前 iOS 未认证/待移植”。
- **不以**图像外观相似、能运行、Float32 TIFF 通过位深与 ICC 检验，推定 Python 原版数值等价。

## Build131 已清理

| 项目 | 处理 | 依据 |
| --- | --- | --- |
| Build130Float32RangeCopy.swift 全图 min-max 重映射 | 删除 | Python 原版没有该独立前置全图仿射映射 |
| Float32 范围映射专用 UI、确认弹窗、模型状态 | 删除 | 不能让“精细冲印”依赖改变输入数据的用户操作 |
| Build130Float32RangeCopyValidation.swift 与专用审计 | 删除 | 测试的是不属于原版的兼容处理，不是算法等价 |
| Float32 输入数据中的负值与超白 | 保留原值 | Build78FloatTIFFIngress；真实 TIFF32 夹具复核 |
| 当前 iOS 全光学 0～1 入口限制 | 暂保留拒绝，改变解释 | 已有数值认证仅覆盖当前范围，不能在未验证时直接放开 |
| io.py、raw_file_processor.py、filming.py、原版参考/随机数据 | 保留 | 唯一算法基准与逐阶段验证需要 |

## 待逐阶段严格移植（非已完成）

1. **入口**：原版 OIIO uint8/uint16/half/float 的读取和归一化，按文件真实精度/ICC/CCTF，不能无理由改成 sRGB 或 0～1。
2. **RAW**：原版 rawpy 的 output_color=ACES、output_bps=16、no_auto_bright=True、gamma=(1,1)、白平衡/色适应/镜头修正。与当前 Core Image RAW/LibRaw iOS 输出分别做逐像素比对。不得只因“都是 Float32”就标记为等价。
3. **入射曝光**：FilmingStage.auto_exposure、expose 以及输入 gamut LUT、CCTF 解码、Hanatos/Mallett 与真实 Float32 超界样本；当前 iOS 相关 0～1 全局门禁并非原版通用检查。
4. **后续工序**：RAW photon→log/H-D→DIR/散射/颗粒→相纸→扫描 XYZ/色域压缩→输出；对所有可见阶段采集原版和 iOS 同输入的差值，不能换数据“消除误差”。
5. **验证门槛**：原版逐阶段数值/随机统计及整图实测通过，才把模块从“未认证/近似”调整为“数值等价”。iPhoneOS 编译通过 ≠ 真机或 Python 原版完整等价。

严格区分“输入文件被读取”“可进入当前 iOS 数值流程”“与原版 Python 模拟等价”三个不同状态。失败要显示原始证据，绝不静默降级。

> 本轮只移除已确认的错误试验，并补充输入完整性回归，尚未宣称原版 HDR/负值 Float32 完整光学数值等价，也未删除其他诊断工具（它们仍为回归和故障复现所需）。
