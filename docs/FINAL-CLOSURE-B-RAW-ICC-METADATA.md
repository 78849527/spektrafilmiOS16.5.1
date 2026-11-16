# Batch B｜原版 RAW／ICC／输出格式验收（生产代码只读）

从源码 `4e1ab8faf4ebfe47a6bac7e85e657881d68d2bf1` 开始，新建只读验收分支。**不修改生产代码、不发布 IPA**。

- 原版 ICC：复跑 pin 住的 io.py profile，真实 macOS ImageIO JPEG/PNG/TIFF 8 组独立文件、位深和原版 ICC 容器级字节比对。
- RAW：复跑 6 类型容器（含 big-endian DNG）、12 个伪造头拒绝、原片完整复制 SHA256。
- rawpy/RAF/DNG 真实照片：仓库里无可用于跨 Python 数值验收的相机 RAW；此前 Apple/LibRaw 只证明兼容解码。
- EXR：数值映射存在；真正 OpenEXR 编码仍故意拒绝。
- XMP：未证明原版 Exiv2 的完整二进制保留。
- EXIF/IPTC/GPS：生产源码有拷贝字典逻辑，但不能把源代码存在当成真实文件往返证明，另设实际磁盘测试。
- 与原版 CAM16/Oklch 第一批验收隔离，不反复生成 IPA。
