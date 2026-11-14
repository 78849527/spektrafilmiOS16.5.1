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


## Build77/03 source RuntimePhotoParams digest batch (2026-11-14)

- Added **ios/scripts/build77_params_digest_reference.py**: executes the ORIGINAL upstream
  \`init_params\` and \`digest_params\` functions, without changing the upstream
  Python tree. Its 360-case reference set covers every 20 filming × 8 printing
  pair, plus all 20 film stocks against the default print stock with preview,
  LUT, deactivated spatial/stochastic, neutral filter database off, source
  stock-specific preset opt-out, combined debug modes, and deliberately
  non-default spatial settings.
- Added **ios/SpektraFilmPort/Build77OriginalParameterDigest.swift**: a
  strict, source-ordered scalar/nested-parameter digest mirror (database neutral
  CMY, preview, film-specific DIR gamma / halation presets, LUT, spatial and
  stochastic switches). A missing field throws instead of silently applying an
  invented default. This module is compiled in the actual iPhone app, but it is
  **not yet connected to the live UI/renderer**.
- Added **ios/tests/Build77OriginalParameterDigestValidation.swift**: runs all
  360 source *inputs* through actual native Swift digest code, exports its own
  results. CI reopens the original Python fixture separately and requires that
  every parameter key, bool, numeric scalar, array and map agree (no skipped
  fields). It does not compare a fixture against itself.
- Expanded **build77-source-contract.yml**: original Python fixture generation,
  independent native Swift host test and strict recursive Python comparison.
  The pipeline includes an iPhoneOS arm64 compile but **NO new IPA packaging
  or Release**. Removed redundant push+PR double runs to reduce CI contention.
- The earlier, explicitly marked experimental **v1.8.52 Build77** IPA remains
  a user-tested baseline. User reports its UI/import/export behavior passed.
  This report is not substituted for original Python vs iPhone numerical proof.

**Current certification boundary:** The source scalar digest mirror can only be
marked as a verified *subtree* on successfully passing its native CI matrix.
It is not a claim of complete RuntimePhotoParams mapping: the iOS production
parameters, UI bindings, user defaults, original seven canonical iPhone taps,
full-graph RNG, scanner gamut, RAW and whole-frame device equivalence still
require implementation and test. Build77 01–05 remains open. Build78 is not
unlocked. No new IPA is requested or emitted for these host-verifiable changes.

### Build77/03 native result and Float64 JSON parser regression

- The first strict comparison correctly rejected the loss of one Float64 ULP: Python 100.12236156288677 became 100.12236156288675 in the Swift Foundation JSONSerialization parser. The original input and zero-tolerance acceptance rule were NOT changed.
- Added ios/SpektraFilmPort/Build77ExactJSONValue.swift using native Swift JSONDecoder, with an explicit bit-pattern regression test for this input value. This repairs source-fixture decoding, not rendering output.
- [GitHub Actions run #43605486020](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43605486020): independent Swift host compile and STRICT 360/360 original Python vs native Swift parameter digest per-field comparison PASSED.
- This establishes only the validated scalar parameter digest subtree. iPhoneOS/macOS compilation, UI production mapping, seven-tap numerical equivalence and full-device image acceptance have separate gates. No new IPA was generated.

## Build77/02 in-production paper stage taps (standard and spatial print diffusion)

- The exact upstream source stage boundary has been checked against
  `src/spektrafilm/runtime/stages/printing.py`: for a negative,
  `PrintingStage.expose` computes photon-domain optical printing,
  optional full-frame diffusion, and `log10(max(raw, 0) + 1e-10)`
  BEFORE `PrintingStage.develop` maps to CMY paper densities.
- Existing `SpectralPhysics.scanFilmDensity` / `paperDensities` now
  expose **actual internal computations** via an optional read-only
  `paperStageObserver`. This covers the ordinary print branch with
  no PSF and supports the source normal paper path.
- Existing `SpectralPhysics.sourceSpatialScanPrintedPhoton` likewise
  exposes the actual log and source H-D values *after* full-frame
  2D original paper diffusion, not an independently recomputed
  diagnostic image.
- `OriginalSourcePhysicalImage.developInPlace` records
  `paperLogExposure` and `paperDevelopedDensity` as independent
  Float64 arrays in both normal and diffusion paths. Direct positive
  scanning must not produce either. Normal export/preview never
  allocates these extra tapes. Diagnostic capture explicitly reserves
  their 48 additional bytes per pixel in the preflight memory budget.
- The explicit `Build77StageTapeRecorder.capturePhysical` guard now
  enforces source-stage order and 3-channel dimensions; it rejects
  missing negative print taps and invented positive print taps.
- The pre-existing real-device path is unchanged unless the optional
  observer is present. `ios/tests/SourcePhysicalImageParity.swift`
  now requires bitwise identity between observable production paper
  stages and the actual functions that produced them, and verifies
  observer-enabled and observer-disabled final RGB are identical.
  `Build77StageTapeRecorderValidation.swift` separately tests
  positive/direct versus negative/print topology violations.
- The Python original `build77_source_contract.py emit-taps` now
  additionally supports `--print-diffusion` to run the actual
  original `PrintingStage.expose` PSF branch. CI retains three
  separate source topologies/conditions: negative default,
  negative with 2D print PSF, and positive direct scan.
- **Scientific limitation:** having correspondingly located stages is
  NOT a Python-vs-iOS numerical match. The real `rgb_pre` original
  preprocessing, high-bit-depth/RAW ICC paths, full production parameter
  binding, exact default RNG and scanner output gamut remain missing
  or not yet independently certified. Do not call Build77 complete.
- CI is **NO IPA** by default: bundled host numerical proofs and
  iPhoneOS arm64 compiler evidence are generated without
  publishing a new installable test build.

### Build77/02 verified no-IPA CI result

- [GitHub Actions #43607270400](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43607270400), tested commit `d4822c4b031a5c8395cc917fa9881b7c18392fb3`: **5/5 CI jobs PASSED**.
- Actual full Swift source spectral numerical suite passed on macOS. Its
  real production tests recorded **741, 1581, 4371, and 360**
  Float64 paper channels for the four fixture images, with
  bitwise-equal normal source scan RGB and unchanged output when
  stage observers are absent; the 2D diffused print case independently
  observed **741 channels** of actual photon→log/H-D→scan stages.
- The existing independent Python→Swift full 2D source/grain/optical
  RGB tests covering **7053 channels** also passed; Python 3.13
  negative-print / negative-diffused-print / direct-positive source tapes,
  28-stock native Double byte audits, native tape topology/NPY checks,
  and strict 360-case digest comparison passed.
- Native `arm64-apple-ios16.5` iPhoneOS Release build and bundle
  version `1.8.52 (77)` passed. **NO IPA** was generated or
  released by this batched CI.
- These checks are stage/local CPU and iPhoneOS compilation evidence,
  NOT complete canonical Python↔iOS seven-tap numerical
  equivalence or a physical iPhone device run. Build77 01–05 is open.

## Build77/02 real Python rgb_pre source preprocessing (sRGB, no crop/rescale)

- The locked Python source `SimulationPipeline._preprocess` calls
  `FilmingStage.auto_exposure` and `ResizingService.crop_and_rescale`
  in that order. Source default parameters use **ProPhoto RGB** and
  `input_cctf_decoding=false`, so source `rgb_pre` is not generally
  identical to decoded mobile sRGB.
- `OriginalSourcePhysicalImage.developInPlace` now emits read-only
  `rgbPre` from the REAL pre-photon input. When source camera metering
  is selected, the stored Double values are those actually given to
  `engine.sourceCameraRaw`; in the no-camera route the stage is an
  identity on the 8-bit sRGB input. Normal rendering does not allocate
  this diagnostic buffer, and the diagnostic path increases its
  preflight memory budget by 24 bytes per pixel.
- The tape recorder's required stage order now includes
  `iosInput → rgbPre → logRaw` in both negative-print and direct-film
  routes. It never relabels the other iOS internals as certified
  original Python seven-tap outputs.
- `ios/scripts/generate_build77_rgb_pre_original.py` executes the
  original upstream Python `SimulationPipeline._preprocess`,
  `FilmingStage.auto_exposure`, `ResizingService.crop_and_rescale`
  and `utils.autoexposure.measure_autoexposure_ev`, **without
  rewriting method bodies**. To avoid importing unrelated RAW
  `exiv2`, only the exact pinned upstream class AST definitions are
  compiled with their original method bodies and a minimal fixture
  environment; original meter utility is run unchanged. All four
  original source Git blob IDs are checked before executing.
- Independent Float64 reference uses `kodak_neutral_fir` 19×13
  encoded sRGB fixture, CCTF decoding enabled, center-weighted
  metering, crop disabled, upscale factor 1.0. Its source file
  `kodak_neutral_fir.rgbPre.f64le` is saved with SHA256 in the
  generated manifest. The original no-auto-exposure branch is also
  checked for full-image identity.
- Actual Swift production runs the identical fixture with selected
  `.centerWeighted` metering, records its pre-photon values,
  numerically compares every channel against the independently
  generated Python source, and requires the final scan RGB to be
  bit-identical with and without any observer.
- **Scope limitation:** this is not full upstream default ProPhoto
  preprocessing, arbitrary crop/skimage rescale, RAW/ICC equivalence,
  stochastic full-frame parity, complete seven-tap iOS equivalence
  or an iPhone device acceptance. Build77 is still IN PROGRESS.
  CI performs no IPA packaging or publication.

### Build77/02 rgb_pre original-to-production exact Float64 CI evidence

- Verified [GitHub Actions run #43609040729](https://github.com/78849527/spektrafilmiOS16.5.1/actions/runs/43609040729)
  at tested source commit `265e2726083aa3d5aee039b54528598134894ead`:
  **all five CI jobs PASS**, including original Python source contract,
  28-stock native profile byte audit, upstream three-branch tape
  generation, strict native Swift 360-case parameter digest parity,
  host numerical source physics and real iPhoneOS ARM64 compilation.
- Direct independently executed original Python
  `SimulationPipeline._preprocess` produced the 19×13×3
  Float64 source stage with SHA256
  `4712578bc7c42771b9caa1bcd4eb310385a3771ad8dcf5261ab8a798ee2c1a11`.
  Original source auto-exposure OFF identity gate also passed.
- Real production `OriginalSourcePhysicalImage.developInPlace`
  `rgbPre` observer compared all **741 channels**:
  **MAE 1.075587081538683e-16**,
  **RMSE 1.2675798405688714e-16**,
  **max abs 2.220446049250313e-16**, **0 above
  5e-11 tolerance**. Observer-off end RGB was bit-identical.
- Xcode iPhoneOS Release build: **BUILD SUCCEEDED**, verified
  bundle identity `1.8.52 (77)`, iOS min 16.5.
- **Certified scope ONLY:** no-crop/no-upscale 8-bit sRGB,
  source `input_cctf_decoding=true`, center-weighted camera
  metering with the tested image. Default upstream ProPhoto RGB,
  arbitrary image resize/crop, high-bit-depth/RAW, source unseeded
  RNG, and complete seven-tap end-to-end production/device
  parity remain outstanding. This does **not** close Build77 01–05.
- This CI is a **no-IPA batch**. No new Test Release or IPA was
  packaged or published; the previously user-tested Build77 IPA
  remains unchanged.
