# SpektraFilm iOS16.5.1｜Build109 集中真机测试 IPA

基线：4e1ab8faf4ebfe47a6bac7e85e657881d68d2bf1，保留原版 Float64、旧版 Build106-108 诊断、原有 iOS16.5.1 UI。
新版本：v1.8.75 / Build109。唯一新增科学处理：真实生产 Oklch→Hanatos 192x192 TC LUT（默认原 xy 不变），可选逐像素源 CAM16-UCS 输出（默认不开）。

CI 签名状态：未签名；必须先自行签名再安装。
CI 额外重新核对 Python 原版 Oklch 96/96、真实 TC LUT 4038/4038、CAM16 216/216，连同 Build108 旧受控回归、真实 iPhoneOS arm64 Release、IPA 中 CFBundle 版本／SHA256／Git SHA 一并验证。

安装后统一入口：高级→验证状态与诊断→Build108 真实 100/200 万像素与 Build106-108 综合 LOG，分享同编号 .log/.json；另检查新版 Oklch/CAM16 两项 opt-in 的实际预览／文件输出。
仍未认证：rawpy/RAW 全链、EXR/XMP、默认多线程无种子 RNG、12/13MP 真机 Jetsam、原版整图 Python 原始参考、GUI 12 项。这是实验性 IPA，不能作为正式全原版等价版本。
