# NextLevel 0.18.0 — iOS 16 professional camera fork

Original MIT library: https://github.com/NextLevel/NextLevel/tree/0.18.0

The original MIT LICENSE remains unmodified. The upstream NextLevel source
files are retained in this local Swift 5 package for Xcode 16.4 compatibility,
with exactly two additions:
- Sources/NextLevel.swift: replaces the upstream placeholder RAW TODO with
  AVCapturePhotoSettings(rawPixelFormatType:processedFormat:), along with
  a capability check and explicit unsupported-RAW failure handler.
- Sources/NextLevelProfessional.swift: new additive extension for strictly
  device-validated manual exposure, focus, white balance, EV and zoom.

All other original source files retain their upstream Git content. The local
Package.swift uses tools 5.9, Swift 5 and iOS 16.0 deployment because the
upstream legacy package manifest is not accepted by Xcode 16.4.

**Important:** Native Bayer DNG capture is separate from **Apple ProRAW**.
RAW + JPEG mode requests the DNG and a processed companion in the same
capture; it MUST fail rather than silently produce only JPEG. The original
DNG is stored unchanged in app Documents and shareable through Files.
The original Python film/print optical pipeline still receives the companion
JPEG/HEIC; actual RAW mosaiced sensor data processing is not yet ported.

The camera module does not certify NumPy/Numba stochastic full-image optics
or complete original Python RAW development. Full precise image parity
remains subject to its existing fail-closed certification requirements.
