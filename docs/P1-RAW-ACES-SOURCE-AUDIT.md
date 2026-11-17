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
