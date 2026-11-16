# Build108 固定基线｜47 项集中验收启动

- 原始源码提交：`b02e2773f07d913e101bd3dcdc5d0c709b74dc77`；App `v1.8.74 / Build108`；iOS 最低 `16.5`、测试目标 `16.5.1`。
- 此分支 **不修改任何生产代码**，不自动生成或发布 IPA。
- 验收脚本按《MASTER-PORTING-ROADMAP》逐条建 47 行记录，引用源码文件，并把目前不能认证的项目标为阻塞。历史已通过测试被继承，但不被扩大为全部功能通过。
- 历史 Build108 GitHub Actions 成功运行：[43798512291](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43798512291)；不代表源算法完整科学认证。
- 已提交用户真机 Build108 JSON 的 SHA256：`936697573994c6ada6a808f11b18d431ca40e2e00eaf3346312ce213c9cc6df0`。用户原始图片和完整 JSON **未复制到仓库**。
- 独立 CI 运行 Swift 源文件语法解析、Build91 1–13MP 预算矩阵、Build106 颗粒阶段内存账本检查，上传 `final-47-acceptance.md/json`。
- **最终认证门禁设计为失败关闭**：RAW/rawpy、ICC/EXR、默认 Numba 多线程、CAM16 默认接线、Python 1/2MP 独立整图、13MP Jetsam、12 项人工 GUI 等有阻塞，就返回 `BLOCKED`。这种门禁失败不是编译故障。
- 通过后的下一阶段才是集中修复，不以重复打包证明缺失功能已存在。
