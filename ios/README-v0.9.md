# SpektraFilm Port v0.9 — Film optical-density grain (iOS 16.5.1)

Version based on successful v0.8 independent development branch; does not
replace original stable release. Xcode 16.4, min iOS 16.5; only actual target
to verify is iOS 16.5.1.

**New two-stage measured film calculation:**
1. Existing 28 measured original profiles and Hanatos2025 source spectra
   produce film exposed/developed optical dye-density RGB channels, using
   the existing film-specific DIR nonspatial chemistry. Compiled from original
   measured log-H&D curves and packed as a 17³ CIColorCube.
2. Density-space GPU particle statistics are applied independently to the
   three developed emulsion channels using deterministic seeded normals.
3. Perturbed physical density feeds *another* 17³ CIColorCube implementing
   negative film -> selected original photographic paper/motion print film ->
   original CIE scanner pipeline, or direct reversal-film scanning.

This is NOT a postprocessed RGB noise overlay.

**Source grain parameters** from model/grain.py and runtime/params_schema.py:
particle_area_um²=0.2, particle_scale=(1.6,1.6,3.2),
density_min=(0.03,0.03,0.03), uniformity=(0.97,0.99,0.97),
pixel_um = 36000 / final image long edge.
The original non-layer particle model is Poisson(n/sat) followed by
Binomial(seeds,p), with particle optical density (dmax/n)*sat.
The native implementation replaces the discrete random draws by a seeded,
per-channel Gaussian approximation with EXACT matching first and second
moments: mean D and variance (Dmax+dmin)² * p * saturation / n.

**Limitations and remaining original modules**:
- Grain's Poisson/Binomial random distribution, separate three emulsion
  sublayers, dye-cloud blur and nanometer microstructure are not exact here.
- 17³ dual cube interpolates film density/optical print vs original full
  per-pixel spectral evaluation; RGB clamp/ICC differences remain.
- In v0.8 halation operates on linear sRGB before film density, not yet
  actual film RAW. Spatial DIR diffusion on donor/receiver density buffers
  is pending. Full color scanner/calibration, print-curve morph pending.
- Grain strength off by default (so v0.8 optical results unchanged).
  Right control toggles measured-density grain; a strength slider changes
  stochastic amplitude. Enables on-demand generation of density/print
  cubes, retaining the stable v0.8 single-LUT fast path by default.
- Deterministic seed 8888 stabilizes preview during slider changes;
  density distribution differs with preview vs export resolution but
  uses physically scaled micrometer/pixel statistics in both.

Build-time quality gates:
- All earlier Hanatos/Mallett/DIR/28 profiles/128 negative-print routes;
- exact sample nodes of separate developed-density and print/scan LUT
  compared against independent full SpectralPhysics methods;
- independent native CoreImage GPU density grain mean, variance, seed
  repeatability, zero-strength behavior and finite range checks;
- all v0.8 spatial scatter/halation impulse and flat-field tests;
- iPhoneOS Release build and bundle / minimum iOS check.
Unsigned IPA must be re-signed for personal device installation.
