# P1 RAW source input: 16-bit linear ACES candidate

Scope: add original Python `rawpy` **as_shot** decoder settings through the existing
native LibRaw bridge. Keep all fast sRGB/Apple RAW routes unchanged.
No RAW file is implicitly converted to JPEG, TIFF or an sRGB working copy.

Original basis: `src/spektrafilm/utils/raw_file_processor.py`,
`_postprocess_params` and `load_and_process_raw_file` at the frozen upstream
baseline recorded in `docs/MASTER-PORTING-ROADMAP-ios16.5.1.md`.

Native changes:

- New `sourceLinearACES` bridge option uses LibRaw output_color=6 (ACES),
  16-bit, gamma=(1,1), no auto bright, camera WB; legacy option is unchanged.
- `P1OriginalRawACESIngress` returns native 16-bit ACES channel bytes.
  Its Float64 frame function promotes **after** Python's Float32 / 65535 step.
- Unsupported compression, insufficient memory and non-RAW input fail closed.

Current certification: **尚未移植** for end-to-end RAW precise mode.
The candidate is deliberately **not** wired to the production precise
renderer: its Hanatos input mode currently has only sRGB/ProPhoto, and
full-image headroom/tap parity are not certified. Do not interpret a
source-level contract PASS as numerical equivalence.

Next P1 gates before production wiring: real same-source RAF/DNG corpus,
fixed LibRaw/rawpy decoder versions and options, white point/matrix and
demosaic checks, WB/daylight/tungsten/custom/tint/lensfun branches, identical
RGB pixel arrays with max/RMSE/MAE, ACES CCTF and exact Hanatos input
matrix, negative/superwhite stage boundary, full-resolution memory tests
and iOS16.5.1 hardware run. Never silently substitute sRGB if ACES fails.

## P1 ACES camera spectral dispatch
Python `spectral_upsampling._rgb_to_tc_b` uses a per-stock
`colour.RGB_to_XYZ` with the stock reference illuminant and CAT16.
The original generator now embeds a separate ACES2065-1 Float64 matrix.
Hanatos accepts `.acesLinear` without decoding sRGB CCTF.
Non-sRGB Mallett paths still fail closed. Production RAW direct rendering
is not enabled: Python/Swift numeric parity, full-resolution memory,
and a real iOS16.5.1 build remain unverified.

## Actual RAW reference fixture and one-to-one comparison

`python ios/scripts/p1_rawpy_input_golden.py --selftest` checks seven
independent UInt16/Float32 bit patterns. With a real RAW file,
`--raw camera.raf --out /tmp/p1-raw-golden` uses the frozen original Python
processor and records its actual RGB Float32 bytes plus input/output SHA,
dimensions, source parameters and decoder versions.

The new test-only Swift `P1RawpySourcePixelComparison.evaluate` consumes
the actual 16-bit linear ACES LibRaw buffer and original Python Float32
reference bytes **without TIFF/sRGB conversion**. It reports all-channel
exact count, MAE, RMSE and maximum difference. Both devices must use the
same unmodified RAW and verified orientation/matrix settings.

No source RAW corpus is committed yet. Therefore no real image comparison
or whole-pipeline certification has been executed.

## Source HDR and negative-value boundary fixture

`python ios/scripts/p1_original_input_boundary_oracle.py --out /tmp/p1-boundary.json`
invokes the actual pinned `_rgb_to_tc_b` for 7 RGB vectors across four
input color/CCTF branches. Samples include negative RGB, superwhite, zero,
neutral and out-of-gamut values. The oracle records per-sample TC lookup
coordinates and physical brightness **without** modifying original input.
The Swift source tap must be measured against this fixture before removing
the existing iOS-only input-range rejection. This test has not been run
against a macOS/iPhone build and is not a certification by itself.

## Direct RAW → Float64 optical engine (candidate, NOT a released feature)

`P1OriginalRawACESIngress.developSourceCandidate(rawURL:opticalSettings:)`
connects the preserved native 16-bit/Float32 linear ACES pixels directly to
`OriginalSourcePhysicalImage.developInPlace` while setting
`cameraInputColorSpace = .acesLinear`. No TIFF/JPEG intermediary, re-tagging,
CoreImage RGB working space, or alternative optical algorithm is used.

This function is **diagnostic-only** until a real iOS16.5.1 compile, decoder
comparison, exact stage taps and memory accounting have passed. The existing
13MP ceiling remains enforced explicitly; do not misrepresent it as an
upstream Python limitation. The current app UI is unchanged.

## Early large-RAW admission

`SFBuild94LibRaw.decode(... maximumAllowedPixels:)` checks the true
LibRaw RAW header dimensions **before** unpack/demosaic. The candidate
source engine sets that ceiling to the existing 13MP optical policy.
The existing sRGB fast routes and decoder-only RAW pixel comparison use
`maximumAllowedPixels=0` and keep their old 45MP decoder limits.
This prevents allocating a 40MP RAW frame only to fail the current
full-optical memory/geometry check. It does NOT implement 40MP optical
processing or establish optical engine RAW parity.

The comparison helper now participates in the iPhoneOS target source list
for a real Swift compile gate at the next **combined P1** build. Adding it
to a target does not execute RAW reference comparisons or certify parity.
