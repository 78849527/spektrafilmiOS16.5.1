# SpektraFilm Port — v0.6.0 original data and Hanatos2025 routes

Experimental user-specific port for **iOS 16.5.1 only**, with the last working
Xcode 16.4 / iOS deployment 16.5 setup. Based on v0.5, isolated development
branch. Stable user-tested versions and release assets remain unchanged.

## Complete original measured stock collection (28)
- **20 filming stocks**: 16 colour negatives and 4 colour reversals.
- **6 colour papers** (print media).
- **2 motion-picture print stocks** Kodak Vision 2383 and 2393.
- All 28 original source curves (81 wavelength samples, log sensitivity,
  optical dye and base densities, 256-point characteristic curves) are
  generated into compact Swift Float32 constants, with SHA-256 source digests.
- No 5MB original JSON folder is bundled: avoids previously observed UIKit
  startup regression on the target iPhone.

The main twin wheel selectors show all 20 filming stocks and all 8 printing
media. Negative film exposes/develops, optically prints to selected paper or
movie print film, then the printed medium is scanned. Reversal film exposes,
develops and scans directly **without any printing stage**, according to the
upstream SimulationPipeline topology. Print/paper wheel is replaced by a
"反转片直扫" label when a positive stock is selected. There are 128
negative/print combinations + 4 direct reversal routes.

## Original Hanatos2025 RGB -> film response
The upstream 2D irradiance spectral LUT
src/spektrafilm/data/luts/spectral_upsampling/irradiance_xy_tc.npy is
integrated with every film's actual 380–780nm sensitivity at BUILD TIME.
The original per-stock erf4 spectral window parameters and white-neutral
normalization are used (upstream default: window ON, surface OFF).
Generated TC raw arrays are stored in Float16 to reduce App size.

At runtime, original CAT16 chromatic adaptation transforms linear sRGB
to XYZ under D55, then xy→TC coordinates and 2D reflected Mitchell–Netravali
cubic interpolation recover the film raw channels. These are connected to
the original measured H–D curves, optical densities, 3400K + Schott KG3
enlarger, default CMY neutral filter, print substrate sensitivity, viewing
illuminant and CIE1931 XYZ conversion. Mallett2019 reference logic from
v0.5 remains as an independent numeric regression test.

## What has NOT been fully ported
This is **not the entire Python Spektrafilm algorithm**, and the output does
not yet match complete upstream renders to numeric tolerance:
- Hanatos adaptation correction SURFACE and gamut compression; only the
  default measured spectral WINDOW is included.
- DIR couplers and original grain sublayers with density-dependent
  stochastic distributions.
- Halation, film scatter and reflection, optical lens/diffusion effects.
- Paper density-curve morph, black/white scanner calibration, glare,
  gamut mapping, native processing at full precision/resolution.
- Source still/image pipeline uses dynamic 17³ CIColorCube interpolation
  for preview and export. Pixel-spatial effects cannot be captured in
  a static per-color LUT and remain a separate rendering milestone.

## Tests
GitHub Actions checks all 28 profiles, 20 filming stocks, 8 print media,
12 Python/Swift Hanatos2025 input reference samples, 8 Mallett samples,
all 128 negative/printing combinations, direct scans for four reversal
films, and 3D CIColorCube validity. It compiles on Xcode 16.4 for iOS 16.5
and verifies the Bundle Identifier and Info.plist. These are automated
tests; actual iOS 16.5.1 launch, UI and photo rendering need device test.

Generated IPA is unsigned and must be signed for installation. Compare to
the previous v0.5 IPA if a physical iPhone issue occurs.

Source attribution: Original Spektrafilm by Andrea Volpato (GPLv3), measured
profiles CC BY-SA 4.0 and original data-source credits in
src/spektrafilm/data/license/SPEKTRAFILM_LICENSE.txt.
