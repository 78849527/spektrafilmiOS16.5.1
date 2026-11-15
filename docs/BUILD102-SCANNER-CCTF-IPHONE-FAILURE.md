# Build102｜真机回报的第一处源数值对照失败：扫描器 CCTF 诊断修复

**上轮精确源码**：Build101 `fc6265f82ef3d701b67259333e32cdae43c06bdd`；基线 iOS16.5.1，最低 iOS 16.5。  
**本轮**：v1.8.69 Build102；只修改原版物理图像的**对照预期算法**、原版诊断数值错误信息和测试，不重写生产扫描光学路径。

## 用户上传的 Build101 实际 iPhone JSON（仅据此报告）

- `physicalDevice=true`、`osVersion=16.5.1`、`binarySourceCommitVerified=true`，Build 101 的 SHA 与发布版本对应。
- `status=controlled_stage_failed_or_reference_missing`；`controlledParityPassOnTargetDevice=false`；`fullPythonOriginalCertified=false`。
- 首个失败字符串：`Production scanner glare wrong stage order p=\\(pixel)...`（其中像素/差值没有正确 Swift 字符串插值）。
- 在用户设备上该调用耗时约 0.038 秒，失败发生在 Build92 原有 `SourcePhysicalImageParity.evaluate()` 的扫描眩光额外生产链自检阶段。因此报告本身**不能证明后续原版 4 图×12 阶段整图已执行完毕**。

## 源码审查发现的具体问题

原版 Python `colour.RGB_to_RGB(linearRGB, "sRGB", "sRGB", apply_cctf_decoding=False, apply_cctf_encoding=True)` 执行真实 **3×3 Float64 sRGB→sRGB 矩阵**，然后施加逐通道 sRGB CCTF。这个同色域矩阵在 64 位浮点计算中不严格等于单位矩阵，不能省略。

- **生产 Swift 路径**：`OriginalSourcePhysicalImage.develop` 最终调用 `OriginalScannerMath.sourceCCTFEncoding([r,g,b])`，保持源矩阵→曲线次序。
- **Build92 设备诊断旧预期**：`SourcePhysicalImageParity.swift` 的扫描器眩光验证却逐通道调用 `encodeSRGB(expectedLinear[ch])`。这个标量函数遗漏了完整 3×3 矩阵，可能错误地抛出 *Production scanner glare wrong stage order*。
- **Build102 修复**：诊断改为对整个 `expectedLinear` 向量调用 **同一原版三通道** `sourceCCTFEncoding`，随后比较 `expectedEncoded[ch]`。XYZ、linear、encoded 阶段均保留原来的 `1e-11` 比较门限，禁止以放宽容差掩盖真实失配。
- 同时将 `"p=\\(pixel)"` 等误加的反斜线改为真正的 Swift 字符串插值 `"p=\(pixel)"`，后续若仍出错，将直接显示像素位置及 XYZ/linear/encoded 分段误差。原有颗粒/色彩诊断的转义输出也改为真实数字。

## 严格验证

1. `Build102ScannerCCTFValidation.swift` **真正编译链接** `OriginalScannerMath.swift` 和由 Python colour-science 原版重生的 `GeneratedScannerReference.swift`，证明正确的 3×3+曲线与生产接口一致，旧 scalar 预期存在非零差异。
2. `build102_scanner_cctf_device_audit.py` 继承 Build101→100→99→98→97 所有 CI 回归，核实生产路径、原版色彩矩阵来源、严格 `1e-11` 阈值未改变、错误数字不再转义。
3. iPhoneOS arm64 Release 的 `SFSourceCommit` 仍与当前 `GITHUB_SHA` 一致，验证 IPA 的真实版本及依赖，未签名包仍标为 `UNSIGNED-UNVERIFIED`。
4. **新包在实体 iOS16.5.1 重新运行同一按钮并上传新的 Build102 JSON** 才能验证第一失败是否消失、暴露下一阶段的实际差异。Build101 失败报告作为已经发生的真机负面证据仍然有效。

## 不能过度宣称

这一修复有充分源码证据指出 **对照预期不一致**，但尚未由 Build102 在用户设备上复测，不能宣称生产算法完全正确、更不能宣称 4×12 阶段全数通过。若下一次出现真正 Float64 数值不符，应保留首错并修复相应阶段，不改变阈值或回退快速 LUT。

富士 RAW 专项继续暂停，已移植 LibRaw/高位深及原版胶片、相纸、DIR、颗粒、扫描器算法原样保留。
