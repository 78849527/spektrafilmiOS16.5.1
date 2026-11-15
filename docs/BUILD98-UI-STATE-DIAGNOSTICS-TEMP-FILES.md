# Build98｜正式化批次：异步一致性 / 模式保护 / 诊断归档 / 临时文件生命周期

**基线**：Build97 SHA `fa8e0d2b6f8f7482bc9c1ac6b1bce38b0f88a380`；版本 `1.8.65 Build98`；iOS 16.5 最低目标不变。

## 新增和修复（本批）

| 审计项 | 生产代码 | 验收范围 |
|---|---|---|
| A05 | `PhotoEditorModel.selectFromPhotos` 最新选择 token + 取消旧 transfer；新图解码/预览后再提交，LUT 导入 refresh 异常恢复 LUT、DIR、颗粒状态与预览 | 自动源码测试，真机交互未验收 |
| A06 | 光谱渲染 `activeSimulationGeneration` 独立所有权，只有最新任务能释放 `busy`；Metal/DIR 错误清除旧处理预览；旧渲染 revision 在检查前失效 | 生产路径静态回归；高频拨轮真机尚未验证 |
| A07 | `originalPixelInputAvailable` 阻止仅有 LibRaw/Apple 兼容 CI 图时误进入原版 Float64 源像素模式；真正的输入位深/ICC 仍由原版 PixelIO 验证 | 模式可达性静态回归；不表示全部 RAW/ICC 已认证 |
| A08 | 原有 Apple RAW、Build81 的测试按钮迁出 46pt 高的主工具栏，进入可打开的“完整检测报告”页，保留程序及入口 | 不删除诊断函数或算法 |
| A09 | `FastSettingsSnapshot` 保存快速冲印关键参数，切入原版精细时经用户确认暂时调整，完整退出还原原有参数；新照片清除跨图快照 | 明确快速/精确参数分离，复杂切换实机仍需验收 |
| A14 | `Build98ExportTemporaryFiles` 仅管理 app 临时目录中 UUID 命名且扩展名匹配的已知 JPEG/TIFF/PNG，分享关闭/Photos 保存后清理，重启限量清理超过 24h 的历史孤儿文件 | macOS 真实文件写入、TTL、排除非本 app 文件；RAW 存放 Documents 从不清理 |

## 严格保留

- 上游 Python 源码是原版唯一数值基准；原版 Float64、原有颗粒、相纸、扫描器、固定随机参考和高位深都不删除、不改等价阈值。
- Build97 P0 fail-closed、RAW 两阶段导入和 JPEG 原尺寸内存限制完整保留。
- X-T5/LibRaw 仅保留已经引入的能力，富士专项**暂停**，不增加测试结论。
- 所有 CI 通过的旧阶段 source tapes、真实 TIFF16 内部 16bit 证明、RGB48 传输测试必须继续通过。
- 生产者不设置静默算法降级，不把目前的精细实验路径强行改为“完整数值认证”。

## 明确仍需

1. 真机 iOS 16.5.1：快速连续切换模式、多次拨轮、导入失败和重复照片选择，必要时采集 .ips。
2. 完整精确模式 Float64 原版 Python 整图对照、默认无 seed 多线程 Numba 的算法和统计验收。
3. 原版高位深宽色域 ICC/XMP、实机大图实际峰值、相册和第三方分享 App 完整保存后的生命周期。
4. 后续批次再清理其余旧实验 UI，逐模块标记完整移植／数值等价／近似实现／尚未移植。旧诊断后端继续保留。

本次 GitHub Release 仍严格标记 **UNSIGNED-UNVERIFIED EXPERIMENTAL**，Xcode 编译成功不等于正式真机认证。
