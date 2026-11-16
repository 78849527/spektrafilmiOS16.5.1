# Build112｜纯界面迁移及顶部固定悬浮提示

- 仅改 SwiftUI FloatingEditorWorkspace.swift 与版本、CI/审计文件；不触碰原版 Float64 光学、颗粒、扫描、PhotoEditorModel、处理序列、精度或默认值。
- 旧顶部状态卡片此前在 VStack 中占高度，短文 1 行／长文 2 行让 GeometryReader 预览高度变化。现在两张提示卡都放进 previewArea 的 overlay：statusChip 固定 32px 且单行省略；输入提示固定 42px（两行）；两项合计固定 78px。任何文字变化不再推动相片坐标。
- 悬浮提示仍可点击：状态进入旧诊断页，照片信息进入 Build111 输入档案和明确 P3 转换。隐藏控件时状态卡隐藏，但不改变预览布局。
- 「工艺」进入精细冲印后增加四个原版色域路线：经典 xy/ACES、Oklch、CAM16-UCS、Oklch+CAM16。没有独立存储模式；映射到既有 sourcePhysicalInputOklchEnabled 与 sourcePhysicalCAM16DefaultGamutEnabled；无输入输出算法修改。Mallett 状态下不允许选择 Oklch，也不静默改 Hanatos 方法。
- 相机光谱重建下沉至「工艺→拍摄」；原版三亚层颗粒开关下沉至「工艺→胶片」；快速版 CAM16 LUT 下沉至「工艺→扫描」；精细版原版 CAM16-UCS 状态显示于扫描；受控单线程扫描 XYZ 眩光开关亦进入「工艺→扫描」，原始眩光参数及未认证多线程实验保留在高级。
- CMY 滤色片作为「工艺→相纸」可展开滑块，原始数据库、放大机光源及未认证曲线留高级；旧版 CAM16 LUT 和原版 CAM16-UCS 明确分名。专业参数保留，但移除同字段重复控制。精细冲印单项受控 PASS，13MP、RAW、多线程和 Python 整图未认证。
- 不调整 3 个主入口/底部调整/长按原图/分屏对比/编辑面板 AnyView 懒加载，不引入新的顶级 SwiftUI 泛型树。

## Build112 集中验收界限

- 可使用：工艺页精细／快速切换、四种色彩线路、阶段开关、P3 明确转换；静态检查不能替代实机操作。
- 受控验证：固定种子 8888 单线程扫描 XYZ 眩光、四条色域线路以及已有数值参考；仅以对应已执行报告为准。
- 未认证：完整 Python 原版整图、真实 13MP 全光学、RAW 全链和无固定种子多线程颗粒。不得作为通过项。
- 回归：顶部两条提示改变文案时 GeometryReader 尺寸保持；长按原图、分屏对比、滑动胶卷、三级菜单懒加载均需真机复核。
- 交付：Build112 必须有当前最新 SHA 的 iPhoneOS 编译日志、静态审计、IPA 资产和 SHA256；未完成真机测试时 Release 仍标 UNSIGNED-UNVERIFIED。
