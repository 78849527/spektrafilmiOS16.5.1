# Build80 / 10–12 — RAW 开发、源级色彩与镜头校正

> 状态：**近似实现／尚未移植**；此批为 iOS 16.5.1 上的 Apple 后端实际诊断 + 一个 Python 原版函数的独立数值移植，**没有**完成全 RAW 精确移植。

- 源 Python 固定：`andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`
- 原版 RAW 文件：`src/spektrafilm/utils/raw_file_processor.py`，blob `97e34feb80fe47a6a3b36fcb93bef626d397135a`
- 上轮承接：Build79 分支 `port/build79-raw-identify-09`，SHA `fd0c14ed65977cbb26a3f29fc2696fe94dc93e0a`
- 本轮：`port/build80-raw-wb-lens-10-12`，工程候选 `v1.8.55 (80)`，iOS deployment 16.5，arm64。

## 原版精度基准（不能变动）

固定 Python 源 `load_and_process_raw_file`：

1. `rawpy.imread(...).postprocess(output_color=ACES,output_bps=16,no_auto_bright=True,gamma=(1,1))`，输出 16-bit ACES2065-1，转 Float32 / 65535；
2. 原片白平衡用相机 WB；日光/钨丝/自定则以日光为底，按 CIE D 系列 / Kang 2002 色温白点及 **Von Kries** 在 ACES 线性空间做色适应；
3. `tint` 是对 **G 通道的 Float32 乘数**；不等于 Apple `neutralTint` 的偏移量；
4. `lens_correction=True` 时调用 exiv2 与 Lensfun，执行渐晕、横向色差、畸变、几何与 scale；
5. 可按源选择输出色彩空间、CCTF，且 RAW 图像本身经过原版输入分支。
   
上游数学标准不因苹果 Color API 可以执行而改动。

## 本轮真实连接的生产功能

- `Build80AppleRAWDevelopment.swift`：**在用户无损保存的原始 RAW 上**使用 `CIRAWFilter(imageURL:)`，提供原片 WB、Apple 6504K、2850K 和指定温度/Tint 偏移；曝光 EV；Apple 原生镜头校正开关。
- 显式关闭 Apple draft、gamut mapping、global boost、local tone mapping；读取实际 Filter 输出，强制在中心 **4×4 RGBAf Float32** 真正渲染到 **extendedLinearSRGB**，并检查样本有限值。
- `ContentView.swift` 和 `FloatingEditorWorkspace.swift`：用户手动发起该诊断，界面显示实际色温、Tint 偏移、曝光与像素，**不修改 RAW 文件、不冒充预览或真正源显影**。
- `Build80OriginalRAWTint.swift`：把原版 Python `_apply_tint_adjustment` 精确移植为独立 Swift Float32 绿通道乘数逻辑，保留原版 `np.isclose(tint,1.0)` 边界。**此函数未接入不属于 ACES 的 Apple 输出**，不会将 4×4 示例标为整图匹配。

## 自动化证据

- `ios/scripts/build80_original_raw_tint_oracle.py`：检查固定 Python RAW 源 Git blob，直接抽取执行**原函数 AST**，生成六种 `tint`（None、1.0、近 1.0、1.2、0.75、-1.0）×18 通道的原版 Float32 bitPattern。
- `Build80OriginalRAWTintValidation.swift`：独立 Swift 路径逐通道 **0 ULP 位模式**对照源 Python；有差异立即失败。
- `Build80AppleRAWDevelopmentValidation.swift`：对原片/色温/Tint/EV 的边界校验、非法数字与 JPEG 欺骗的 fail-closed 回归。
- 工作流 `.github/workflows/build77-source-contract.yml` 把新增源文件编进 host Swift 主测试，之后实际编译 arm64-apple-ios16.5；同时跑原有 Python 参考、28 胶片数据与阶段验证。
- 本轮 CI：[GitHub Actions 43626039906](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43626039906)；只以最终成功的对应提交作结果判断。尚无新增 IPA。

## 严格未完成边界

- Apple CIRAWFilter 解码、X-Trans 去马赛克、白平衡、Tint 和镜头校正 **不等于** rawpy/LibRaw/Lensfun。
- 没有证据表明 Apple 内部去噪/高光/色适应与 Python 默认结果一致。
- 不可用 `neutralTint = 0` 推断 Python `tint = 1.0` 已数值等价。
- Apple 4×4 extendedLinearSRGB **不是** Python 全幅 ACES2065-1；尚缺原版 ACES Float32 场景色彩、整幅像素及白平衡、Lensfun 具体分支。
- 原片仍需实测：X-T5 RAF 未压缩及压缩、DNG/ProRAW、CR3/CR2、NEF、ARW；相同输入的两后端逐阶段与整图对照及 iOS 16.5.1 真机内存测试。
- **状态**：原版 RAW 数值等价＝尚未移植；Apple 辅助解码及手动控制＝近似实现；Python 原版 Tint 单函数仅在其数值 CI 成功后可在所测条件内标记数值等价。

本批不开正式 Release，也不自动上传 IPA；继续精确移植前不得删减已有源物理链、胶片/相纸/UI 等功能。
