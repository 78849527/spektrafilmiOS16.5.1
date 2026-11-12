# SpektraFilm Port 1.1 — Source scanner colour branch (iOS 16.5.1)

This branch inherits v1.0.1, **confirmed by user to boot and respond**.
No change to the user-tested pinned preview, floating two-wheel and
adjustment dock, lazy-load startup, double-tap zoom, compare slider or
UIKit long-hold original gesture. Builds Xcode16.4 / iOS >= 16.5.

## New optional scanner routes

The "扫描光源 · ACES 色域" toggle is OFF by default to preserve v1.0.1
appearance. When enabled, measured paper / reversal-film spectral CMY
density is converted into actual CIE 1931 XYZ via D50 or Kinoton K75P
and normalized by the source illuminant-Y integral. The exact
colour.XYZ_to_RGB source transform for that illuminant under colour
0.4.6 is generated at CI build time. The output RGB uses original
gamut_compression.compress_rgb_aces_rgc with original default
knee(threshold=0,limit=1,power=6), then sRGB transfer encoding.

**Important:** original Python's DEFAULT gamut compression is **CAM16-UCS**
rather than ACES RGC. ACES is a supported **alternative** in upstream;
therefore do NOT claim default gamut parity.

"黑白场校准（端点估算）" is an optional separate checkbox, only present
when experimental scanner path is active. It uses original
ColorReferenceService.black_white_xyz_correction luminance scaling
and original encoded black_level=0.01 / white_level=0.98, but currently
estimates the reference luminances from measured film/paper density
curve endpoints. The full Python print-exposure-aware reference
computation (source printing.py source film_black/white, paper development,
reference correction and film exposure updates) is NOT yet ported.
This option is not full source colour-calibration parity.

"扫描锐化 / 微眩光" toggles post-LUT image-space output finishing:
original RGB unsharp equation, sigma=0.7 / amount=0.7 and source's
print-glare lognormal distribution (3%, roughness=0.7, blur sigma=0.5)
with a fixed seed, normalized by source /100. Its tiny print glare is
approximated after display transformation and not at upstream XYZ stage
before output gamut mapping. Direct reversal film never gets print glare.
Preview and JPEG export have the SAME finishing configuration.

## Quality gates
- Generate source scanner reference transformation for D50 and K75P using
  exact original Python colour-science XYZ_to_RGB calls.
- Run 4 reference XYZ→RGB and 8 ACES RGC source-vector parity checks.
- Run scanner black/white reference luminance correction tests.
- Core Image smoke checks on constant frame and glare shader.
- All 128 negative/print and 4 reversal direct routes under new scanner;
  density-then-print split remains functional when grain enabled.
- Preserve all existing original Hanatos/Mallett/DIR, density grain and
  spatial scatter/halation tests.
- Fully compile unsigned iPhoneOS Release with bundle ID unchanged.

All new features are opt-in. If unstable on physical iOS 16.5.1,
simply disable new scanner toggles or reinstall v1.0.1, still available.
The unsigned IPA requires re-signing.
