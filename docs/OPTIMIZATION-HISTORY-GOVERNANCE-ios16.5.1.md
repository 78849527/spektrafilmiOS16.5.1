# 优化专项：历史诊断与构建治理

以第三批提交 b28be15030a9911b33039f39a530bbac466dacf5 的 Git tree 为盘点基准。该树有 84 个 workflow 文件、89 个 ios/tests 文件、139 个 ios/scripts 文件、99 个 docs 文件。数量不是重复或废弃项数量；不以文件名判断是否可删除。

## 权威顺序

1. DEVELOPMENT_PRINCIPLES.md 和 MASTER-PORTING-ROADMAP-ios16.5.1.md：唯一算法基准与既有路线图。
2. work/build129-raw-float32-srgb-icc-admission-ios1651：当前正式开发分支，不更换、不强推。
3. .github/workflows/build131-ios1651-strict-source-input-cleanup-ipa.yml：当前集中回归/编译入口。推送 workflow 更新只验证与编译，不自动发布旧版本 IPA。保留全部现有独立数值和设备证据门槛。
4. docs/OPTIMIZATION-TASK-LIST-ios16.5.1.md：优化任务状态，与真实 CI run/commit/device report 绑定，不将源码断言或候选提交视为认证。

## 诊断与历史保留

| 分类 | 处理 | 删除前必要证据 |
|---|---|---|
| 独立 Python/Swift 数值 oracle | 保留，固定原版 blob | 原等价数值覆盖和新测试实际通过 |
| 旧 Build 实机诊断、日志 JSON | 保留，不冒充当前版本认证 | 相同 SHA、硬件、系统和阶段指标可追踪 |
| 旧 UI 兼容实验 | 逐项查实际调用与入口 | 依赖扫描、编译和交互回归通过 |
| 84 个 workflow 历史文件 | 先盘点触发条件及归档用途；本轮仅更新当前入口 | 无活动依赖、保留历史运行与产物链接 |
| 旧分支/发布 | 不修改、不删除 | 用户明确授权及证据归档 |

## 认证状态

候选源码提交 -> 静态门槛 -> 独立数值回归 -> 真 iPhoneOS arm64 构建 -> 用户 A15 iOS16.5.1 真机验证。每层独立记录；未执行与失败不得合并成通过。历史发布保持不可变。不得以历史 IPA 名称冒充新增优化版。

## 后续拆分顺序

已提取系统文件选择/分享适配器。下一步依次处理诊断报告输出、配方持久化、RAW 编辑调度、导出协调，避免跨文件扩散私有状态权限；每次只移动有明确接口的模块。删除旧实验前逐项检查调用、资源、测试与 UI 链路。
