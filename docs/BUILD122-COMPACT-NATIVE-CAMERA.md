# Build122 | Compact Sliders + Native Camera | iOS16.5.1

## Scope
UI and camera acquisition only, baseline Build121. The Python optical source algorithm, Swift/Metal numerical pipeline, seeded grain RNG, source parameter defaults, dynamic 80% memory guard, exports and original processing modes are unchanged.

### Compact slider and numeric entry
- System SwiftUI Slider visual size replaced by a small UIKit UISlider via UIViewRepresentable: 12pt thumb, compact rail, 24pt visual height, extra transparent hit target.
- Old hard-coded UI steps 0.25EV and 0.05/0.25 were not Python source precision requirements. Drag uses full Double model binding, triggering source render only on touch release.
- Tapping numeric label opens a finite Double precision entry sheet; +/- nudge 0.01EV for exposure, 0.01 for strength, 0.01 or 0.1 for optical properties depending on original parameter span. Bounds from existing source Binding range preserved; confirm runs one render; invalid/NaN/inf/out-of-bounds rejected.
- Effect percent shows 0..100% but stores the same 0..1 Double. Double-tapping the parameter title and the sheet Reset button restore existing default values.
- Reduces stage vertical spacing and inline bottom padding; floating photo parent and original hold/split preview stay unchanged.

### Native AVFoundation camera replacing NextLevel dependency
- Legacy source file path ios/SpektraFilmPort/NextLevelCamera.swift retained for old audit compatibility, but it now imports AVFoundation directly, not NextLevel. XcodeGen project no longer depends on NextLevel package.
- AVCaptureSession + AVCapturePhotoOutput + AVCaptureVideoPreviewLayer; serial session queue for session setup/teardown and hardware camera switching; simplified format JPEG/HEIC/RAW-DNG+JPEG, lens 0.5/1x/tele/front when hardware supports, ratios 4:3/3:2/16:9/1:1 and shutter.
- RAW supported only when an actual available Bayer RAW pixel format exists. Dual native AVCapturePhotoSettings RAW + processed companion; automatic stabilization disabled, per-capture photo delegate kept alive to final completion/error, errors never silently converted to JPEG.
- RAW DNG bytes remain intact/full-sensor. Optional aspect crop is only on the processed JPEG/HEIC companion (4:3 passthrough), off-main thread, using explicit actual pixel rendering and sRGB encoding. Native RAW stored atomically by unchanged model; the optical importer still processes companion pixels only. No claim of Python rawpy sensor-development parity.
- Camera switch and format capability dynamically checked at runtime; unsupported HEIC/RAW and missing RAW callback report explicit failures.

## Acceptance
- All Build92-121 source/Python/Float64/Numba/grain/RSS regressions, new slider & native camera source contracts, iPhoneOS arm64 build, version/SHA/unsigned IPA verification.
- Physical iOS16.5.1 still requires native device testing: lens/ratio/format switching, JPEG/HEIC output aspect, DNG full metadata, repeated RAW captures without crash, Documents saving, float source preview and camera dismissal. Hardware crash logs (IPS) required for any continuing crash. Passing CI alone does not prove a fixed RAW crash.
