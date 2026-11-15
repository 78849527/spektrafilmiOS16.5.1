# Build94｜富士 X-T5 压缩 RAF / LibRaw 0.22 原生 iPhoneOS 解码

基线：Build93 v1.8.60, commit `33c63f542b18769f107a902012e3ff73494633dc`。本批 App 版本 `1.8.61 / Build94`。最低 iOS 16.5，arm64。

## 实际代码

- 编译固定的 upstream LibRaw **0.22.0**，Git commit `0b56545a4f828743f28a4345cdfdd4c49f9f9a2a`，使用真实 iPhoneOS SDK / arm64；由 `ios/scripts/build94_compile_libraw_ios.sh` 构建 `libraw.a` 并检查 `fuji_compressed.o` / `xtrans_demosaic.o`。
- `Build94LibRawBridge.mm` 调用 **libraw_open_file → libraw_unpack → libraw_dcraw_process → libraw_dcraw_make_mem_image**，禁止 thumbnail 代替 RAW。采用 camera WB、no auto bright、dcraw 色彩处理到 **8-bit sRGB**，解包后的图像保持原尺寸（输入上限 4500 万像素）。
- Swift 显式选取「使用 LibRaw 0.22 富士 RAF 模式打开（8-bit）」后，才解码进入已有编辑器。原始 RAF 通过 Build79 的 SHA256 复制验证保留，不覆盖；Apple RAW 兼容路径仍可单独选。
- 非精确模式：**不是**原版 Python rawpy/LibRaw 场景线性原始数据，也不是 CPU Float64 原版完整光学 RAW 链。8-bit sRGB 快速兼容色彩数据不可标记为原版数值等价。40MP 全画幅内存仍需 iOS16.5.1 真机测量，失败明确提示。

## 兼容性边界

| 格式 | 软件能力 | 认证等级 |
|---|---|---|
| X-T5 无压缩 RAF | Apple RAW 独立路径；LibRaw 可选 | 设备、实际 RAF 待测 |
| X-T5 无损压缩 RAF | LibRaw 富士压缩/ X-Trans 原生库编译及调用 | iPhone RAW 文件实测待完成 |
| X-T5 有损压缩 RAF | LibRaw 解码请求，不预先宣称成功 | iPhone RAW 文件实测待完成 |
| 其他相机 RAW | Build93 Apple 原生入口 | 逐型号/压缩方式待证实 |
| Python 数值原版 | 不自动降级；不走 LibRaw RGB8 | 尚未完成 RAW→光学整链等价 |

## 编译与证明

- 先校验官方源固定 SHA，再构建真实 64-bit iPhoneOS 静态库，检查 compressed decoder / X-Trans 文件包含在 `libraw.a` 中。
- Build92 48 阶段 source tapes、Build93 原有 GUI 验证及 Build94 新 LibRaw 静态检查必须通过，随后执行 `xcodebuild -sdk iphoneos`，验证 app 版本架构及 Metal library。
- GitHub Release 仅发 `UNSIGNED-UNVERIFIED` 实验版。**没有 X-T5 三档 RAF 真机记录、设备峰值内存报告和 Python 原版对照前，不能称认证完成。**
- 第三方源码由 CI 临时获取，固定 tag SHA，最终编译入 IPA（不是假 stub）。LibRaw 双重许可 **LGPL-2.1 / CDDL-1.0**；采用 CDDL-1.0 选项，源码及许可证来自 https://github.com/LibRaw/LibRaw/tree/0.22.0 ，不修改其上游 C++ 文件。正式分发前核查源代码提供、版权声明及发布义务。

### 参考

- https://www.libraw.org/supported-cameras
- https://www.libraw.org/docs/API-C.html
- https://www.libraw.org/docs/Install-LibRaw-eng.html
