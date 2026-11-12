# SpektraFilm Port v1.0 — floating photo editor for iOS 16.5.1

Independent release branched off the successfully built v0.9 optical-density
grain version. Prior IPA and source branches remain untouched.

## UI layout

The photograph is a pinned, full-window, aspect-fit preview; no ScrollView
contains the preview. Controls are overlays floating above the image:
- Top 46pt translucent toolbar: Photos, Files, external .cube, JPEG export,
  original/processed split comparison, one-tap hide/show controls.
- Lower-left translucent drag-handle wheel dock, collapsible independently:
  source film picker, print-media picker (reversal direct-scan label), original
  28-material catalog entry.
- Lower-right independent draggable/collapsible adjustment dock:
  separate film exposure, print exposure, LUT strength, emulsion scatter,
  multibounce halation, density grain, effect amount sliders and apply.
  The adjustment pane scrolls internally while the photograph stays fixed.

Original viewing: in normal mode the user physically holds the picture; an
iOS 16 UIKit UILongPressGestureRecognizer keeps the original visible until
the finger is lifted. Compare mode shows original left and effect right, with
a finger-draggable split position. Double-tap to zoom, pinch-to-zoom is
provided in normal mode. Collapse either dock or tap the eye button to hide
both while preserving full-photo preview. The eye button remains visible to
restore controls without leaving the photo.

## Compatibility and regression

UI work does not change v0.9 optical algorithm, app bundle ID or build SDK
pin. iOS 16.5.1 is the sole requested device target. ios/project.yml
keeps iOS 16.5 deployment setting; CI pins Xcode16.4 on macOS15-Intel.
All existing source Hanatos/Mallett/DIR, 28 material, 128 print route,
reversal scan, spatial halation and density-grain tests are required for
release. CI cannot prove on-device gesture/interaction correctness; test
hold, compare-divider dragging, wheel selection, floating dock dragging,
collapsed/hidden states and Photos/Files/.cube/JPEG export on target iPhone.

The UI is separate from the source physical-image algorithm parity work;
original source DIR spatial diffusion and exact multi-layer grain remain
unported. No misleading full-port claim should be made.

Unsigned IPA requires user-side signing before installation.
