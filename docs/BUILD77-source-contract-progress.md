# Build77 · 01–05 implementation and remaining acceptance gates

**State: partial implementation, NOT Build77 acceptance.**
This work is based on the immutable [master roadmap](MASTER-PORTING-ROADMAP-ios16.5.1.md).
The last app baseline remains v1.8.51 Build76, commit f00383059882efe9b9a09151898b5dadaa2906f9.

## Fixed source contract

- Original Python commit: 3bb2c2d2801ff68b92019cf1dbcbb133d60832bc.
- Git tree for all Python package source and shipped data (including all stock profiles, filters, ICC, spectral LUTs and licenses): 9f0e2510d5af46b51eabd8096ae9bb1591ea81c9.
- 28-profile subtree: fa9262d2440903262dd302b52739162c939e153e.
- pyproject.toml blob: eb782eb444bdd76f34b645511039dec2fd9185d5.
- The CI uses Python 3.13 to execute the original pipeline. It installs numerical libraries in line with pyproject constraints, not a modified alternative algorithm.
- The source tree is checked against pinned Git identities. No upstream auto-update occurs.

## Work items 01–05

| Item | Implemented evidence | Remaining, NOT certified |
|---|---|---|
| 01 source and dependencies | Strict tree/file Git identities; parsed upstream Python requirements/dependencies; distinct SHA256 and Git blob IDs for 28 JSON profiles. | iOS/Swift dependency and device full equivalence |
| 02 processing taps | AST-driven checks of actual source Node labels and both pipeline branches. Python fixture files captured from one real pipeline traversal. | Seven corresponding iOS production tap observations with matching semantics and exact stage boundaries |
| 03 defaults and digest | Original RuntimePhotoParams dataclass defaults and default_factory expressions extracted into JSON. Source builder and schema files locked within the source tree. | Per-control iOS production binding checks; neutral-print database, stock-specific DIR/halation presets, preview/LUT/debug digest branches |
| 04 all 28 profiles | Checks 20 filming and 8 printing stocks; 81 wavelength axis; 81×3 sensitivity/channel density; 256×3 curves; sample validity and license/source metadata, preserving null measurements. | End-to-end byte-by-byte 28-stock Float64 arrays and all masks compared with iPhoneOS bundled data, including generated and loaded values |
| 05 fixtures and comparison | Original negative-print and reversal/direct-scan execution on one tiny synthetic input; stage-wise little-endian Float64 NPY, shapes, byte SHA256, finite masks and elapsed time; a numerical MAE/RMSE/max comparator. | Independent Swift tap exports, numerical acceptance limits per device/tap, randomized distribution comparisons, color error, edges and large-image memory/latency reports |

The above does not upgrade an algorithm module to 完整移植 or 数值等价. Existing module status must remain tied to independent source-and-device evidence; visual similarity is not proof.

## Original source topology

Source: src/spektrafilm/runtime/pipeline.py, SimulationPipeline._build_topology.

Negative → paper → scan:
  rgb_in → rgb_pre → log_e_film → cmy_film → log_e_print → cmy_print → rgb_out

Direct film scan when io.scan_film=True:
  rgb_in → rgb_pre → log_e_film → cmy_film → rgb_out

- Python rgb_pre contains auto-exposure and crop/resize, not merely image decode.
- Python cmy_film includes the film development chain and grain. An iOS observation before grain must not be mislabeled as this tap.
- Current iOS OriginalSourcePhysicalImage has fine-grained callbacks including logRaw, initial, density, printed and various grain stages. Some paper/scan computations are fused; missing matching paper taps must be added rather than forged.
- Direct scan does not have print taps. They are inapplicable, not zero-filled.
- Default source randomness is unseeded. Two independent runs need not match per-pixel, so distribution parity must be tested separately from controlled deterministic seeds.

## Reproduce

At repo root, with Python 3.13:

    python ios/scripts/build77_source_contract.py self-test
    python ios/scripts/build77_source_contract.py verify --report build77-evidence/source-contract.json

For numerical original source tapes, install its Python math dependencies and supply H×W×3 RGB NumPy input:

    python ios/scripts/build77_source_contract.py emit-taps --input sample.npy --output build77-evidence/negative --film kodak_portra_400 --paper kodak_portra_endura
    python ios/scripts/build77_source_contract.py emit-taps --input sample.npy --output build77-evidence/direct --film fujifilm_provia_100f --paper kodak_portra_endura --scan-film

Future iPhoneOS app tap exports must have the same numeric shape, dtype and semantic placement:

    python ios/scripts/build77_source_contract.py compare-taps --reference build77-evidence/negative --candidate PATH_TO_IOS_TAP_FILES --atol 0

The default zero absolute tolerance means this tool does not silently certify approximations. A scientifically justified nonzero tolerance must be documented per stage, hardware, mode and input range. The basic comparator does NOT yet implement Delta E, edge seams or stochastic distribution checks.

## Actual CI

- Actions run 43600403889: pinned source tree/schema/profile verification passed.
- Actions run 43600631639: source contract AND real original Python negative-print and direct-scan tap generation passed. Two retained artifacts: build77-source-contract and build77-python-original-taps-not-swift-certified.
- Stage tape artifacts are source-side references. The comparator's reference-versus-itself smoke test does NOT establish Python/Swift parity.
- No new iOS IPA produced; no iPhoneOS compilation or iOS 16.5.1 device test in this Build77 work.

**Stop gate**: remain at Build77 until all 01–05 work items and their missing iOS parameter/tap/Float64 parity evidence pass. Do not advance to Build78 or publish a newly certified IPA.

## Build77 follow-up: real Swift Double tapes and 28-stock native byte checks

- Added ios/SpektraFilmPort/Build77StageTapeRecorder.swift: explicit opt-in recording of actual production Float64 stage callbacks. It preserves Double bit patterns and non-finite values in NPY. iOS internal callbacks are NOT mislabeled as canonical Python taps.
- Added ios/tests/Build77StageTapeRecorderValidation.swift: native Swift host compiler/readback validated by independent NumPy. This is format integrity, not Python/Swift numerical pipeline parity.
- Strict Python candidate comparator additionally rejects non-Float64 stage tapes, SHA256 reference drift, nonfinite value class/mask mismatches.
- Added independent original JSON source 28-stock manifest and native Swift stock data-byte audit, including original 256x3x3 measurements in film and paper profiles. The independent F64/F32 source-byte audit job passed in CI #43601771176. This is data integrity, not device pixel parity.
- iPhoneOS compilation initially FAILED in CI #43601324457 because missing source-generated Swift data caused unresolved Generated* names. The job now materializes original baseline generated references before compiling; a later build result is required before any claim of success.
- Source version is still v1.8.51 Build76. Build77 remains unaccepted; no new version, IPA or Release. Complete digest and canonical seven-tap iOS scientific parity remain open.

## Build77 28-stock host cross-language byte evidence (2026-11-14)

- Production SpectralPhysics.Profile now rejects a source-mode material unless the ORIGINAL six concatenated little-endian Float64 data arrays match the generated source SHA-256. Legacy mobile Float32 and the Build76 app identity remain unchanged.
- Source JSON inspection confirmed that all 28 stock files, including eight print media, contain 256×3×3 density_curves_layers measurements. An initial validator incorrectly restricted this to filming stocks; all source checks and the production guard were corrected to preserve all 28.
- ios/scripts/build77_measured_manifest.py computes source JSON identity, independent original Float64 and mobile Float32 per-field SHA-256, all three null-mask digests, and the concatenated original payload SHA, without reading generated Swift.
- ios/tests/Build77MeasuredProfileAudit.swift compiles as a standalone native macOS consumer of the production Swift generated material data and fails CI on any field or mask mismatch.
- [Actions #43601775221](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43601775221): the independent 28-material Swift byte audit, locked upstream source contract, and original Python pipeline fixture jobs passed. This does not certify iPhone device profile loading or optical, colour, stochastic or seven-tap numerical equivalence.
- The Build77StageTapeRecorder preserves actual iOS callback labels, not fabricated Python tap names. A host NPY test is not a full matching iPhoneOS tap observation.

Remaining Build77 work: device execution of the production material loader, mapping and live observation of all original Python taps, original RuntimePhotoParams/digest/UI binding parity, and full device numerical acceptance. No new IPA is certified or released.
