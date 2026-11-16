# Build115 | original Numba unseeded multiworker grain

Target iOS 16.5.1, version 1.8.81 Build115. This is the **default Python RNG architecture** being ported, *not* a claim of bit-for-bit identity across arbitrary unseeded runs.

## Source behavior verified by reading pinned Python files
- `grain.py` has `use_fast_stats=False` by default: independent SciPy Poisson/binomial particle layers remain seeded by channel + 10*sublayer.
- Numba `fast_lognormal_from_mean_std` is `parallel=True` and consumes unseeded worker RNGs **only when** `30nm/pixelUM > 0.05`.
- Optional `use_fast_stats=True` activates Numba `fast_poisson` and `fast_binomial` for particle layers. They share the continuous worker-local MT19937/Normal stream with subsequent lognormal microstructure.
- Original `np.random` NumPy layer seeds do not seed Numba worker states. Parallel results are not reproducible from `seed=8888` and thread scheduling is unspecified.

## Implemented in this round
1. Separate `OriginalSourceNumbaParallelWorkers.swift`, independent OS-entropy initialized MT19937 per worker, GCD concurrent flat contiguous partitions and persistent worker state, 2–8 workers.
2. Numba source Poisson/normal-approximation, binomial/direct/inversion/normal-approximation and lognormal source equations reused in Float64; *no* Core Image/Metal Gaussian replacement.
3. Integrated into actual `OriginalSourcePhysicalGrain.apply` for original 3×3 measured sublayers, in film-density domain before optical print. Existing seeded single-worker and seeded SciPy fixtures are retained unchanged.
4. `工艺 → 胶片` two independent toggles: unseeded multiworker, and the separately optional original Numba fast_stats particles. Both are opt-in until real iPhone statistical acceptance.
5. Predecode, production and export memory ledgers account for extra 56 B/pixel worker buffers; failure never triggers an implicit downgrade.

## CI test matrix
- Pinned upstream *actual Python* Numba on 4 unseeded workqueue workers, 65,536 samples per distribution.
- Real compiled Swift 4-worker source algorithm independent OS entropy + deterministic diagnostic worker-state replay + 65,536 Poisson/ binomial samples and 196,608 lognormal outputs.
- Theoretical expected compound thinning Poisson(lambda 8) + Binomial(p .4): mean=variance=3.2. Lognormal mean 1 std .3: variance=.09. Tolerances recorded in machine-readable original and Swift independent reports.
- Source Python-vs-Swift independent moment comparisons. This is **statistical** equivalence, *not* per-pixel/worker-schedule bit identity.
- Existing Build114 13MP basic Float64 in-place DIR test, 28+20 source fixtures and old single-worker grain parity remain separate regressions.

## On-device acceptance
1. Install the Build115 **signed** IPA and confirm 1.8.81 / 115 / iOS 16.5.1 / exact compiled SHA.
2. In a supported tagged sRGB photo activate `工艺 → 胶片 → 原版三亚层颗粒 → Numba 默认多线程`. Source fast_stats optional and independent. Original seeded mode should remain available.
3. In `高级 → 验证状态`, run `Build115：默认 Numba 多线程颗粒真机统计＋生产整合` and export the paired LOG+JSON.
4. Both `originalSublayersWithSciPyPass` and `originalSublayersWithFastStatsPass`, `unseededIndependentDrawsDiffer` and `sourceStatisticalChecksPassedOnTarget` must be true, with SHA matching the IPA. Otherwise preserve the first failure.
5. Compare same-image visually on/off while verifying both 3×3 source-grain branches process *before* film-to-paper scan. Do not expect two unseeded exports to match pixel-for-pixel.
6. No claim about 13MP **with** source grain (memory budget 272 + 56 B/pixel additional), real RAW, Python full-size image, or unconstrained worker scheduling exact bitstream.

## Status policy
- Code committed != macOS cross-distribution PASS != real iPhone statistical PASS != original Python default prange per-thread bit identity.
- The last exact bitwise guarantee cannot be made for an unseeded arbitrary Python prange execution; its correct acceptance goal is source distribution and imaging stage behavior.
- Leave the old default seeded single-worker path unchanged until the new production evidence is collected.
