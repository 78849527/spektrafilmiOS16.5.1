# SpektraFilm iOS 16.5.1｜开发代理与 CI 执行规则

**本仓库开发总原则的唯一权威入口：[`DEVELOPMENT_PRINCIPLES.md`](DEVELOPMENT_PRINCIPLES.md)。**

本文件适用于所有在本仓库工作的人工开发者、AI 代理及 CI。此前各类开发聊天、旧 AGENTS 约定、历史 Build 文档与下文冲突时，**以 DEVELOPMENT_PRINCIPLES.md 为准**。不得自行创建分支、扩展实验处理或改变原版算法。

## 接手项目必须先做的事

1. 读取根目录 `DEVELOPMENT_PRINCIPLES.md`，这是唯一当前有效的开发总原则。
2. 在现有 iOS 开发分支读取 [47 项原版移植路线图](https://github.com/78849527/spektrafilmiOS16.5.1/blob/work/build129-raw-float32-srgb-icc-admission-ios1651/docs/MASTER-PORTING-ROADMAP-ios16.5.1.md) 与最近的真实 GitHub 提交/CI；默认 `main` 可能尚未合入 iOS 工程。
3. 核对上游 Python 固定源码与相关数值样本，先检查旧实现是否已经正确移植及真实接入生产，再动代码。
4. **不新建分支；需要新分支必须先得到项目所有者明确许可。** 普通 Bug、编译失败、UI 微调、同模块开发继续使用原开发分支。
5. 仅做最小必要修复，清理已证伪的非原版兼容实现，保留原版数据和有效回归。严禁强制 Float32 全图 RGB 0～1 映射、隐式 JPEG8、伪造 ICC 或未认证光学近似。
6. 在代码/发布结论中区分：尚未移植、近似实现、完整移植、数值等价。只凭编译或画面相似不能认定原版等价。

## 固定构建环境与发布门槛

- **构建机架构不再限制：GitHub-hosted Intel/Apple Silicon macOS Runner 均可使用；按可用性与所需 Xcode/iPhoneOS SDK 选择。最终产物必须是 `iphoneos arm64`，最低部署版本 iOS 16.5，重点真机 iOS 16.5.1。**
- 不得将宿主机架构与 iPhone App 目标架构混淆。切换 Runner 不得改变原版算法、依赖版本、数值阈值或跳过回归。某个镜像缺少 Xcode/SDK 或工具时明确报错并换可用镜像，而不是静默退化。
- Python、NumPy、SciPy、Numba、llvmlite 的依赖版本需匹配原版冻结基准及当前已验证 Runner；变更必须有独立验证，不得静默升级。
- 批量修改、低成本预检后再启动全量构建；同一 Bug 构建失败不新建分支、不无意义增 Build 编号。
- 发布须真实通过适用的 Python 原版数值回归、Swift 验证、iPhoneOS 编译、真机验证及身份校验；无法完成全面科学认证时只能明确标记“未认证”。
- 未签名 IPA 不可直接安装；**只有已真实发布并通过 GitHub Release 资产核验，才能提供 IPA 下载直链。**

## 技术路线及历史记录

- [47 项原版最大化移植路线图](https://github.com/78849527/spektrafilmiOS16.5.1/blob/work/build129-raw-float32-srgb-icc-admission-ios1651/docs/MASTER-PORTING-ROADMAP-ios16.5.1.md)：完整范围、原版源码映射、四类认证状态与逐阶段数值验收要求。**这是技术清单，不是与总原则并列的第二套规范。**
- [Build131 清理记录](https://github.com/78849527/spektrafilmiOS16.5.1/blob/work/build129-raw-float32-srgb-icc-admission-ios1651/docs/BUILD131-ORIGINAL-FIRST-EXPERIMENT-CLEANUP.md)：历史实验清理证据，不能代替现行原则。
- 上游 Python：`andreavolpato/spektrafilm`。未经审计、批准，不自行推进上游源码基准。

**最终规则：原版优先、只在既有开发分支继续、没有证据就不宣称等价。**
