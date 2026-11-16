# Build114 | Four separate certification gates (iOS 16.5.1)

## A. 13 MP Float64 physical optics
- Previous budget: 120 B/pixel * 13M = 1560 MB, above 1500 MB cap.
- Optimized whole-image DIR retains original full-frame reflect FIR/YVV and Float64, processing one channel and accumulating back into the input inhibitor RGB buffer. No source optical approximation or silent fallback.
- New base estimate 112 B/pixel * 13M = 1456 MB; all optional modules add their existing independent budget and may be refused.
- Build114 requires strict all-channel Double bit-pattern parity against the retained old DIR implementation over 7 tests.
- New opt-in actual 5000x2600 iPhone test uses the production pipeline, 25ms RSS sampling, and crash-surviving checkpoint.
- NOT YET CERTIFIED: real 13MP device test, Jetsam high-watermark, real ImageIO import and enabled grain/FFT combinations.

## B. Python original whole-image numerical parity
- Existing Python upstream fixtures: 4 controlled small 8-bit sRGB images, 12 original stages each including final RGB.
- iPhone controlled 28+20 stage evidence previously passed.
- Build114 adds bit-exact old/new DIR algebra and same full-image boundaries.
- NOT YET CERTIFIED: independent original Python 1MP/2MP/13MP full final output for matching input, parameters and optional optical branches. Small fixtures cannot prove arbitrary full-size images.

## C. RAW / 16-bit / ICC
- Existing: native Fuji LibRaw 0.22 RAF and 16-bit RGB48, tagged 16-bit sRGB PNG/TIFF, float TIFF ingress, ColorSync explicit P3-to-sRGB copy, native ICC/bit-depth container tests.
- Real camera RAF/DNG -> original rawpy white balance/demosaic -> physical source -> ICC/metadata must be compared against a shared real source fixture.
- NOT YET CERTIFIED: full RAW-to-Python-source numerical parity. Do not silently demote depth or relabel ICC.

## D. Original unseeded parallel Numba
- Existing: one-worker seeded source NumPy/Numba random grain parity in both Python original and iOS.
- Build114 runs actual unmodified Python fast_stats.py on 4 unseeded workers, 65,536 samples per distribution, tests theoretical Poisson/binomial/lognormal moments and non-identical repeat draws.
- NOT YET CERTIFIED: iOS matching unseeded per-worker RNG statistics/stream lifecycle. Unseeded output cannot be expected to match pixel-for-pixel between different runs.

## Rules
- Four distinct gates. CI tests narrower features, not the whole pipeline.
- Do not convert partial success into certification; report first failure and missing evidence.
- Keep iOS 16.5.1 and preserve original precision, parameters, mode snapshots and defaults.
- A new unsigned iPhoneOS IPA is issued only on actual GitHub Actions build success; device tests remain an additional independent gate.
