# Build119｜13MP Numba 渲染入口重复扣除已分配输入帧修复

## Build118 真机报告：2026-11-17
- 8MP SciPy/Numba：实测 PASS / PASS。峰值 1021 / 1100MB。
- 10MP SciPy/Numba：实测 PASS / PASS。峰值 1249 / 1326MB。
- 13MP SciPy：实测 PASS，RSS 1615MB，73.21秒。阶段峰值集中于九亚层颗粒。
- 13MP Numba：0 输出、0.07秒，内层 Build91 内存预检拒绝。计划总预算 2392MB，预检时 iOS 当前剩余 2873MB，80% 允许 2298MB；差 94MB。报告曾错误标记真实渲染失败，实际根本没有渲染。
- 三档均为合成 sRGB、无额外扫描器/扩散/完整 RAW/ICC/16-bit 光学开关；不等同全源 Python 整图像素级数值认证。

## 原因与修复
Build118 同一张已分配的 Float64 RGB 输入帧（13MP×3×8字节=312MB）同时被计入「完整处理链预估峰值」和「iOS 当前进程尚可使用的剩余内存」对比。内层渲染函数接到已经有输入数据的 frame，这个 312MB 不是**下一步还要新分配**的内存。如果还按总峰值 2392MB 对比剩余容量，就会重复收费，导致错误拒绝。

Build119：
1. **预解码、预分配**：保持零抵扣，完整估算 2392MB 仍要通过 80% iOS 可分配内存门槛才会申请大图。
2. **developInPlace 内层再次验证**：仅在输入 RGB Double 数量确证等于宽×高×3 时，扣除**已存在且在总估算内的**312MB；需要再分配 2392−312＝2080MB，与当前 2873MB×80%=2298MB 比较。既不扣除将来申请的颗粒缓冲，也不降低 20% 余量。
3. 确认入参扣除量不得超过基础内存估值，避免调用者乱传并越过保护。
4. 内层真正出现 Build91 预检拒绝时写入 `refused_by_production_memory_gate`，不再错写为 `real_source_render_failed_or_unmeasured`。
5. 三个独立按钮保留并标注 Build119；仍每档独立 LOG+JSON+闪退检查点。原版 Float64、三亚层顺序、SciPy 种子、Numba 工作线程的 RNG 消费均不改。

## 验收
CI 必须通过 Build119 13MP Numba 312MB 输入帧扣重算测试、Build91 80% 余量压力拒绝测试、Build118 分档报告检测、源 Python grain.py 5图×4阶段、FIR/YVV 回归、iPhoneOS arm64 完整编译和真实发布验证。此后需要 **13MP Numba 单项真机执行**才能证明 13MP 双路线，不得将再次预检放行视为测试 PASS。
