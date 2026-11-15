# Build101｜Python 原版 → iPhone Swift 受控数值对照与证据保存

**基线**：v1.8.67 Build100，GitHub SHA `0fef417f037d83f7c523b1615ce80d147049ef28`。
**目标**：v1.8.68 Build101；最低 iOS 16.5，指定验收 iOS 16.5.1。
**范围**：已经存在、但缺乏实际设备执行证明的 `Build92DeviceSourceStageDiagnostic.evaluate()`，不凭空新增或更改 Python 胶片、相纸、颗粒、DIR 算法。

## 本轮真实实施

1. 在 App“高级 → 验证状态与诊断”增加**执行原版 Python → 本机 Swift 阶段数值对照**按钮。它不是比对两张肉眼照片，而是在当前设备上直接运行真正的生产 `OriginalSourcePhysicalImage` / `SourcePhysicalImageParity` 与 CI 打包的 Python 原版参考图像。
2. `Build101DeviceParityEvidence` 单独记录：应用版本／Build、编译 Git SHA、系统和设备标识、是否物理设备、是否恰好 iOS 16.5.1、参考原版清单 SHA256、受控检测耗时、原始诊断文字、首个失败错误。即使测试失败也会生成 JSON。
3. 只有真实 iOS 16.5.1 设备、有效 40 字符十六进制**被编译入 Info.plist 的当前 Git 提交**、有效原版参考 SHA 和实际 `evaluate()` 全部成功，`controlledParityPassOnTargetDevice` 才可能为 `true`。其他环境只记对应状态；即使成功，也始终 `fullPythonOriginalCertified=false`。
4. GitHub Actions 在 **Xcode Build 时**将真实 `GITHUB_SHA` 注入 `SFSourceCommit`，编译后/IPA 内再次核对同 SHA。Build77 旧静态来源 SHA 不拿来伪装当前 binary revision。
5. 证据保存在用户 iPhone **Documents/SpektraFilm Verification/Build101-controlled-parity-<UUID>.json**；仅用户主动执行，不上传用户图片，不删除旧证据。
6. 删除诊断报告分享的固定 350ms 延迟，改为实际 `.sheet(onDismiss:)` 完成后分享；Build77 历史 one-shot 与 Build100 清单同样沿用安全队列。
7. 受控机上 `Build101MeasuredParityEvidenceValidation.swift` 执行 Foundation/CryptoKit 实际写入、回读、错误注入、缺少参考、空诊断、非目标系统、缺乏源码身份等检测。此测试为**模拟输入的运行时门禁**，本身不认证任何 iPhone。
8. `build101_device_parity_audit.py` 继承 Build100～92 的静态回归与数值参考测试，再检查本次真实对比入口、文件路径及失败保留。

## 受控数值路径的严格边界

- `Build92` 对应 Python 原版生成的 **4 组受控小图／12 个参考阶段类型**；真实代码内部的比较阶段、阈值和报错位置仍由既有 `SourcePhysicalImageParity.evaluate()` 决定，不凭一个 PASS 编造每个 tap 的误差统计。
- 这不是整张实际用户照片的最终 RGB 对照，不代表 Python 原版的默认无 seed／多线程 Numba、RAW／宽色域 ICC／高位深／EXIF、13MP 真实内存或商业正式稳定性认证。
- **Build77 one-shot 的 3 路 6×4 Float64 原版源 tap 对照仍有独立严格程序** `ios/scripts/certify_build77_oneshot.py`；需要用户真实 iPhone StageTape 文件并匹配 Python reference 才能报告数值等价。不得将其 selftest（复制原版源文件）当作设备证明。
- **真机用户无需另外打开电脑 Python 原版处理照片**：点击 App 自带的受控数值对照，分享 JSON 给开发流程；实际科学认证必须保留完整对应输入、硬件、源码 SHA、每阶段差值。没有设备证据就是未验证。

## 真实测试矩阵

| 项 | 自动 CI | 真正 iOS16.5.1 设备 |
|---|---|---|
| Build92 原版 48 个 Python source tapes 重新生成／SHA | 必须 PASS | 不等于设备结果 |
| Build100/99/98/97 回归、RGB48／TIFF16／Core Image | 必须 PASS | 运行行为仍待验证 |
| Build101 SHA 绑定／JSON 实际写入／失败注入 | macOS 独立可执行 PASS | 待用户从 App 导出 |
| iPhoneOS arm64 Release，打包 exact Git SHA | 必须 PASS | 安装需签名 |
| Build92 Swift `evaluate()` 在实体 iOS16.5.1 的执行结果 | 不可由 macOS CI 宣称 | **必须从设备 JSON 中获取** |
| Python 原版完整默认路径、真机全幅／随机／色彩认证 | 不可用单一 fixture 替代 | **未完成** |

富士 RAW 额外开发仍暂停，已有 LibRaw、iOS UI、原版光学算法与结果保持不变。
