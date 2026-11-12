# SpektraFilm Port v1.4 — optical enlarger (iOS 16.5.1)

Independent branch based on source-tested v1.3; startup and picture controls
remain the iOS16.5.1 user-verified v1.0.1 floating photo workspace.

## Optical enlarger, opt-in
- Unfiltered original blackbody 3400 K / measured Schott KG3 source.
- 128 original database neutral CMY settings for all 16 negative films x
  8 printing media. C base CC is not adjustable; original M/Y shifts
  are independently adjustable from -50 to +50 Kodak CC.
- Original 81-wavelength dichroic CC transmittance from color_filters.py.
  Change M/Y -> recompute full paper-channel spectral exposure, not
  RGB color-balance sliders.
- Independent preflash CC (M,Y), preflash exposure, applied after source
  main-beam geometric midgrey normalisation and BEFORE print development.
  Source preflash uses paper spectral sensitivity and the film spectral
  base density, not the processed photo.
- Midgray exposure normalization toggle: source geomean factor 1/geomean
  over three sensitised printing channels. Upstream supports additional
  DIR-dependent midgrey compensation not yet fully reproduced.
- Source-specific 128 pair Python reference traces for filtered light,
  three-channel main optical response, and preflash at 0.15 exposure.
- The original source printing diffusion filter is inactive by default
  (not ported as an exact RAW per-channel optical filter).
- The original enlarger UV/IR and print-exposure compensation branches
  remain partially approximate in the native engine.

## Safety, fidelity and architecture
The whole enlarger mode defaults OFF, so v1.3 source output is preserved
exactly when the mode is disabled. The preflash itself also defaults 0.
Optics are calculated in the existing optical LUT generator as a spectral
integration, not added afterward as display RGB tint or gradient.
Reversal positive film bypasses enlarger even if UI toggled in a previous
negative. Preview and JPEG share the same photo LUT.

Original source ColorReferenceService B/W correction and s023 paper
development are retained. The in-progress physical DIR spatial diffusion,
exact multi-emulsion layer grain and full enlarger RAW spatial processing
remain separate followup phases.

Quality gates include 128 Python optical enlarger references, all 128
integrated original printing pairs, four reversal bypasses, the measured
dual-stage grain print pass, all existing Hanatos/Mallett/DIR/s023/CAM16
and CoreImage optical tests, safe startup guard, iPhoneOS Release build,
bundle ID com.twogou.spektrafilmport and minimum iOS16.5 check.

Unsigned IPA requires signing. Device touch behaviour is not verifiable
via Xcode CI; verify on physical iOS16.5.1 before daily use.
