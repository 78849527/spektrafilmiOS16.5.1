# SpektraFilm iOS 16.5.1 — v0.7 original film DIR chemistry

Unchanged: 20 original filming stocks (16 colour negative, 4 reversal),
six printing papers, Kodak 2383/2393 printing film, original Hanatos2025
film spectral irradiation (per-stock 192² TC), Mallett2019 test path,
D55 or tungsten CAT16, D50/K75P scanner illuminants, original print
neutral filtration database, twin wheels, long-press original and export.

New in v0.7: actual original *nonspatial* development-inhibitor-releasing
(DIR) coupler chemistry in the negative/reversal film development step:
- Stock-specific gamma self-layer and six cross-layer inhibition coefficients
  from runtime.params_builder._apply_film_specifics, including Provia/Velvia.
- Original donor→receiver 3×3 coupler matrix from model.couplers.
- Inversion of the measured *normalized* H-D characteristic curves to
  produce pre-DIR development curves (including original reversal
  silver-inversion branch).
- Predevelopment film silver density, donor-sourced inhibitor exposure
  correction, and final interpolation on pre-DIR corrected curves.
- Reference neutral-print exposure is still calibrated from original
  develop_simple without DIR inhibition, just as upstream FilmingStage
  _simple_rgb_to_density_spectral does.

Original source samples are prepared during CI from untouched measured
profile JSON and the original Python-equivalent matrix/inversion routines.
Twelve per-stock positive/negative Python reference densities are checked
against native Swift with tolerance for Float32 packed measured curves.
Runs all 128 negative+print and 4 reversal direct-scan routes plus Hanatos
and Mallett source numerical tests.

**Not yet done / why not 100%**: original DIR spatial Gaussian +
exponential-tail diffusion requires image-space density/exposure buffers;
the current 3D color cube only supports local colour transformations. The
original NumPy/scipy stochastic multilayer grain, halation/scattering,
glare, complete print-curve morph and colour-reference / gamut correction
are also not ported. These will need a separate *per-pixel spatial render*
stage with explicit agreement tests, not a random grain overlay falsely
labelled as "source physical grain".

Compatibility: only target real iOS 16.5.1 on device; use pinned
Xcode16.4/macos-15. Assets are unsigned and must be signed manually.
