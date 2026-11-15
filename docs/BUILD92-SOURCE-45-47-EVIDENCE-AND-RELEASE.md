# Build92 · 第45–47项：原版分阶段整图、iOS16.5.1真机回归、IPA 同 SHA 发布

**分支**：`port/build92-source-tapes-device-regression-release-45-47`，Build91 基线提交 `dd33f25333fa8954a9d823e84175304f483e04d7` 已通过 [iPhoneOS arm64 Release](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43691244359)。

**本批应用身份**：`com.twogou.spektrafilmport`，v1.8.59 / **Build92**，部署最低 iOS 16.5，arm64。严格遵循原版算法顺序、源文件真值、生产错误显式化与独立 CPU Double/Metal Float32 模式。

## 45 原版 Python 分阶段整图

- 原版 `ios/scripts/generate_source_physical_frame.py` 直接运行源 Python Hanatos 光谱 RAW 转换、非线性胶片 H-D、二维 DIR（FIR 与 YVV IIR）、相纸印相、XYZ/ACES RGB；另外调用实际 `model/grain.py` 三亚层颗粒、染料云及**种子 8888、Numba 单线程**微结构。
- 在 GitHub Actions 的本次提交现场重生 4 组图像：Kodak Portra 400、Fujifilm Pro 400H、不同原版相纸、印相色彩、活跃微结构等。对 **12 个源阶段 × 4 图片 = 48 个参考 tape** 校验来源文件 SHA256、宽高、每通道双精度浮点、有限性及边缘统计，生成 JSON 供后续设备审核。
- 在 App 真正加入 `SourcePhysicalImageParity.evaluate(fixtures:)` 并把原始 4 组 12 阶段 Float64 参考 tape 打包为文件夹资源：**真实 iPhone 用户主动点击**已有硬件诊断入口后，才会运行生产 `OriginalSourcePhysicalImage` / `OriginalSourcePixelIO`，逐源阶段报告 MAE、RMSE、最大误差和首个超限点，失败不转成通过。
- 不是无种子 Numba 多线程结果，也不覆盖完整 RAW/LibRaw、Apple ProRAW、16/32bit 入图、Display P3/BT.2020 真实光谱全流程、12–13MP iPhone 真正大量内存测量或无证据的源统计一致。即使 CI 通过，也**不能宣称以上分支已完成源 Python 数值等价认证**。
- **当前证据等级**：Python 原始 tape 已具备并可审计；Swift 物理图像对照入口已编译进入 App，**用户实际 iOS16.5.1 设备执行尚未取得记录**。

## 46 iOS16.5.1 GUI、相机、相册/文件完整回归

- `build92_gui_regression_audit.py` 验证 21 项原版 iOS16.5.1 界面/文件/API 静态不变量：iOS 16.5 目标、相机授权与 NextLevel RAW DNG 无静默 JPEG 回退、Photos/Files/LUT 导入、原图按住、双击放大、胶片/相纸拨轮、三级面板与切换确认、滑块默认恢复、原图/安全/经济三尺寸导出、Photos 相册权限和硬件诊断入口。
- CI 只能做**静态 UI API 和 iPhoneOS SDK 编译**，不能声称完成真实 iPhone 16.5.1 的授权弹窗、悬浮预览 5 次连续切换、滑块点击、分屏原图、真机导出入库和回归无崩溃。
- 这些人工/物理设备验证仍是科学认证的硬门槛；收到设备诊断文件才能添加证据，不允许自动改成 PASS。

## 47 编译/IPA身份/Release

- GitHub Actions `build92-source-stage-device-ipa-release.yml` 在受测 Git commit 生成所有原版 Python/Numba/SciPy/Colour 参考数据，审计 48 source tapes、21 GUI 不变量，运行本批所有 Swift/Metal 的 Xcode16.4 **真实 iPhoneOS arm64 Release**，验证最低 iOS 16.5、Build92 版本与源物理参考 bundle。
- 只有 **`BUILD SUCCEEDED`**、设备 `SpektraFilmPort.app` 的 `Info.plist`、`arm64`、`default.metallib`、原版参考数据包均通过，才用标准 `Payload/SpektraFilmPort.app` 打包独立 unsigned IPA；再逐个读取 IPA ZIP 中版本、最低 iOS 目标和源资源，生成 SHA256 与 identity JSON。
- 仅当远端最新开发分支 HEAD **等于实际成功编译的 `GITHUB_SHA`** 时，允许创建 GitHub Release，避免发错上一轮 IPA。
- GitHub Release 的实验版资产必须明确标注 `UNSIGNED-UNVERIFIED`，安装需要用户自己签名。绝不能冒充 Apple 已签名、TestFlight 已分发、成功在 iPhone16.5.1 安装或真机科学认证。
- 仍保留 `ios/scripts/verify_precision_release.py` 强门槛：真实 iPhone 16.5.1 原版数学与全图证据不完整时 **认证失败**，但这不会阻断**明确标记的未签名实验 IPA** 构建。
- 若仓库 GitHub Actions 无 `contents:write` 权限，可能仅生成 Actions 工件而不能发布 Release。必须以实际 GitHub Release/Asset 验证成功后才发**直链**，不许假造 URL。

## Build92 工作位置与实际科学认证

| 项 | 实现状态 | 认证状态 |
|---|---|---|
| 45 完整 Python source staged tapes | 源 4 图×12 阶段、原生对照入口和日志 | 仅 8-bit sRGB 的受控样本，RAW/高位深/默认随机与真机未认证 |
| 46 iOS GUI/相机/相册/文件 | 21 项静态契约 + 原版老 UI 交互保持 | 真正物理 iPhone16.5.1 手势/权限/文件验证未执行 |
| 47 构建身份与 IPA | Build92 exact SHA 构建 + 元数据/SHA/Release 流程 | 需 GitHub Release 真正发布成功才称 IPA 已交付 |

**47/47 只是路线图工作已推进到最后一批，绝非 47/47 原版完全认证。** 不允许因只通过 source Python fixture、iPhoneOS SDK 编译或 macOS ImageIO 测试就宣称上游无随机误差、全 RAW 逐值等价或实机 13MP 峰值可用。

