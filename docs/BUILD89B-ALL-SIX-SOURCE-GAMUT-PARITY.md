# Build89b｜原版输出色域六算法缺口补齐｜Oklch、Oklrab、JzAzBz

**开发分支**：`port/build89b-perceptual-output-oklch-oklrab-jzazbz`，在已通过 iPhoneOS arm64 编译的 Build89 源分支 `port/build89-output-gamut-space-38-39-bulk` 之后衔接，版本标识仍为 `v1.8.58 / Build83`，未签名发布。

**原版唯一标准**：`src/spektrafilm/utils/gamut_compression.py`，Git blob `9783e7fcfc2909c4acdf2da53595c5404645dde9`；原版 `colour-science==0.4.6`。依照源版本版权声明 Colour Developers BSD-3-Clause；不得以常见 Oklab/PQ 网页近似公式冒充精确矩阵。

## 生产代码修改

- `generate_scanner_reference.py` 从实际 colour 0.4.6 导出四组 Oklab 原矩阵（XYZ↔LMS↔Lab）和四组 Safdar2017 JzAzBz/PQ 矩阵及 NumPy 原逆矩阵，保留 Build89 源 sRGB、Display P3、ITU-R BT.2020 Float64 XYZ/白点输出。
- `Build89bOriginalOklabGamut.swift`：原版 XYZ_to_Oklab/Oklab_to_XYZ，signed cube root，64×720 的 Cmax(L,h)、18 次逐节点 bisection、边界 slack 1e-6，源双线性 Cmax 查表；L=0.02..1.0，最大 chroma=0.5。
- `oklch` 亮度 L、色相 h 不随 chroma 膝点变化；源亮度单侧压缩 `(0.7,1,2.2)` 在查 Cmax **之前**计算。可显式将 lightness 设为 nil，保留高光和负值。
- `oklrab` 在源 OkLab L 经单侧亮度压缩后才执行 Ottosson 2023 L→Lr；Cmax 查询采用 Lr，但最终重构保留原 L；Cmax 节点使用 Lr→L 逆变换。这不能混同 Oklch 色域表。
- `Build89bOriginalJzAzBz.swift`：Safdar2017 JzAzBz XYZ→Izazbz→Jz、PQ 正/逆 `m2=1.7×2523/32`，真实源矩阵 + 100 cd/m² SDR 白参考；64×720 的 Cmax(Jz,h)，18 次 bisection、上限 Cz=0.3，Jz 节点范围 0.002..0.18。
- `Build89OriginalOutputGamut.swift` 的六算法真实 dispatcher 现在均执行对应源 CPU Double：`off`、`aces_rgc`、`cam16ucs`、`oklch`、`oklrab`、`jzazbz`。以上新 3 个路径均拒绝 ACES fallback，也不使用 33³ Float32 LUT。
- `OriginalSourcePhysicalImage` 的上游真实生产接口早在 Build89 已接入 `sourceOutputGamut`，此批三个算法通过同一个 source 光谱 XYZ→RAW RGB→output gamut→镜头 Gaussian/FIR/YVV→可选 CCTF 接口。已有 opt-in 输入为 nil 的旧移动快速模式不变。
- `Build89OutputGamutProductionDiagnostic` 增加小幅 7×5 真实负片/相纸光学图像的 Oklch、Oklrab、JzAzBz 处理验证，并复核原始线性 RGB、真实 source gamut tap、外层 gamma 开关和光谱顺序；作为原 8/8 真机测试**之外**的独立附录，不计 9/8。

## Python 原版 → Swift Float64 数值证据

- [Oklch／Oklrab 原版 144 组](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43686071340)：**PASS**，3 种输出 RGB primaries × 2 算法 × 2 knee/lightness 配置 × 12 输入，RGB 最大绝对误差 `5.551115123125783e-15`；所有 64×720×18 Cmax 精确由原版源码计算。
- [JzAzBz 原版 72 组](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43686386307)：**PASS**，源 Jz forward 最大 `3.826921960749241e-14`，Safdar PQ inverse XYZ 最大 `1.1908696251339279e-11`，输出 RGB 最大 `6.470379787515412e-13`，SDR white100 / 3 种 RGB primaries / 2 种 knee/lightness 配置。测试使用源实际 `compress_rgb`。
- 生产 `jzazbz` dispatcher 入口由后续 CI 自身再次验证，原 72 组孤立内核通过不等于已检测真实 App 分发器。
- Build89 已有 source CAM16 216 组及 ACES/OFF 126 组，当前累计所有六算法精确源数学对照为 **558 组**（`216+126+144+72`），各型号和空间重复是参数样本，不表示 558 张 iPhone 全幅照片。

## 仍未认证（禁止标作完整移植）

- **真实 Display P3/BT2020 文件输出 ICC**：已经有三空间的 Float64 色域数值，但原 App 原像素 JPEG 只能 sRGB 明确 ICC，广色域导出前仍显式拒绝、不会用 sRGB JPEG 假标签保存 P3 颜色。
- 8–13MP 原版 Python 每一阶段完整 RGB 逐 tap 数据及真机内存消耗、iOS 16.5.1 实际 App 交互、RAW/高位深、默认 Numba 无种子多 worker 随机场均还需要独立验收。
- 六种源算法均有指定测试输入的**数值等价**证据，不等于 iOS 全范围输入、全部曝光、全部色域外颜色已完全通过。
- Build89b 仍补充路线第 **38 项**，不应将路线“39／47”自动改写为“40／47”。下一工程批次 Build90 对应第 40–41 项文件导出、元数据及 LUT/缓存完整行为。

## iPhoneOS arm64 发行边界

本分支必须通过一次所有新增真实 Swift 模块合并 `xcodebuild` iPhoneOS Release、arm64、Metal 检查才能声明“编译通过”；只能从关联 SHA 的真实 GitHub Actions 记录确认。即使通过也是 unsigned app，不是 Build89b IPA，不得提供旧版 IPA 冒充新一轮。
