# Build81｜13–16 几何、预览、自动曝光、输入色域移植（进行中）

- **来源基线**：Python 原版 `andreavolpato/spektrafilm@3bb2c2d2801ff68b92019cf1dbcbb133d60832bc`。
- **承接已发布测试包**：Build80 v1.8.55(80)，`73907878435e9790409fdc9dd61b180d7f6675cd`；未签名 Release `ios1651-v1.8.55-build80-RAW-DIAGNOSTIC-UNSIGNED-UNVERIFIED`。
- **工作分支**：`port/build81-crop-resize-preview-gamut-13-16`，候选 v1.8.56(81)，iOS 最低 16.5，未经完整源等价认证；本批不自动发布 IPA。

## 13 / crop_image

- **原版源码**：`src/spektrafilm/utils/crop_resize.py`，Git blob `4737b922c34f5cf77f66f8bb022b0625e4e37dd1`。
- **真实 Swift 实现**：`ios/SpektraFilmPort/Build81OriginalCrop.swift`：
  1. `np.flip(center)` 后以 `(height,width)` 各自乘以归一化中心；
  2. 长边归一化尺寸：`np.round(max(height,width)*np.flip(size))`；
  3. NumPy `np.round` **ties-to-even**，再分别执行原版先截负、后截右的原始索引变换；
  4. 复现 NumPy 负索引切片规则（包括 crop 尺寸大于单轴时），不转换 ICC、不缩放、不改变 Float64 RGB 样本位；
  5. Python 返回空切片时明确报错：现有 `OriginalSourcePixelIO.Frame` 不能表示空宽或空高，绝不自动回退整图。
- **原版 Python 独立验证**：`ios/scripts/build81_original_crop_oracle.py` 在固定 Git blob 校验后直接抽取 `crop_image` AST，执行 13 组不同长宽比、边缘、半整数、超尺寸和空切片，输出参考 JSON。
- **Swift 实测入口**：`Build81OriginalCropValidation.evaluate()` 复核原版的像素排列、宽高、Float64 channel bitPattern，接到 `ios/tests/SpectralValidation.swift` 的实际数值套件；候选 CI：[Build81 branch Actions](https://github.com/78849527/spektrafilmiOS16.5.1/actions?query=branch%3Aport%2Fbuild81-crop-resize-preview-gamut-13-16)。
- **当前状态**：函数已实现并接入自动测试，**未完成全部真实图片几何/缩放链路认证**。只有 CI 真正通过后才能认定上述有限范围的数值等价。

## 13 其他缺口与 14–16

- 13：原版 `skimage.transform.resize` **order=3**、抗锯齿、reflect 边界和 `pixel_size_um` 前后变化仍未完整迁移。
- 14：`resize_for_preview` 的原版 `order=1,anti_aliasing=True,preserve_range=True` 与曝光测量 256 长边，尚未独立逐像素移植。
- 15：原版 RGB/CCTF→XYZ autoexposure 计量分支，尚需全部测光模式数值验证。
- 16：输入 xy、Oklch、Reinhard、光谱边界与 LUT 重映射，尚未完全迁移和认证。

禁止以当前 ImageIO、Quartz、Core Image 或任何已有近似预览声称上述功能已经原版数值等价。Python 上游仍是唯一算法基准。
