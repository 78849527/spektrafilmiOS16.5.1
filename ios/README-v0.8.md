# SpektraFilm Port — experimental v0.8 on iOS 16.5.1

Based on the known-working startup architecture (macOS-15, Xcode 16.4,
deployment iOS 16.5; tested only on iOS 16.5.1). Prior v0.7 release
retained without modification.

### New real spatial effects
Implements GPU-backed Core Image spatial convolution prior to spectral
17³ LUT processing, on gamma-decoded linear RGB pixels. Two user switches
are located in the right-side adjustment column:
- 乳剂散射: original in-emulsion energy-preserving Gaussian core plus
  exponential-tail Gaussian-mixture diffusion, exact source coefficients:
  scatter_core_um=(2.2,2.0,1.6), tail_um=(9.3,9.7,9.1),
  tail_weight=(0.78,0.65,0.67) and the original 3-component fit.
- 背反射光晕: original 3-bounce Gaussian halation, widths sigma_h*sqrt(k),
  bounce decay 0.5, per-channel 1/(1+a) energy normalization. Sigma and
  optical strengths keyed by source profile use and antihalation:
  still 65um/cine 50um, strong/weak/none original 3-vector parameters.
  Adjustable 0x–3x multiplier.

Spatial processing is at FINAL preview or JPEG-export resolution; the
optical pixel-size conversion is 36000um / image long edge to keep
physical halo widths comparable at different output resolutions. This
preserves output dimensions and original long-press comparison.
Photos/Files/.cube loading, 28 materials and Hanatos2025 optics retained.

### Honest fidelity limits
The upstream physical halation stage operates on the RGB RAW film
irradiance, after optional highlight boost, before logarithm and DIR
development. This preliminary iOS GPU stage operates on linear sRGB
BEFORE the spectral 3D LUT, using the same kernel coefficients and
presets, but does not yet operate on actual RAW spectral-channel film
irradiance. The built-in Core Image Gaussian algorithm also differs
slightly from upstream reflected FIR/IIR boundary filtering. Therefore
v0.8 spatial effects are not yet numerically identical to upstream.
Highlight-boost reconstruction and exact RAW propagation remain pending.

The original film grain is density-dependent stochastic Poisson/binomial
per dye layer (with physical particle dimensions and layer substructure).
It cannot correctly be reproduced by adding RGB noise after the 3D LUT.
Do not call synthetic noise original physical grain. Grain, spatial
DIR diffusion (on film-density/exposure buffers), and full print/scanner
calibration are subsequent milestones.

### Validation
- Upstream optical coefficient/energy-preservation checks: six film
  presets, original exponential mixture, 3 bounces, normalization.
- Native Core Image spatial convolution tests on a constant patch and
  a single bright impulse, compiled and run on macOS CI.
- All earlier 28 original profiles, Hanatos/Mallett and DIR samples,
  128 negative-print routes, reversal-direct-scan numeric tests.
- iPhoneOS release build, Bundle Identifier and iOS 16.5 target checks.

Unsigned IPA needs manual signing before installation.
