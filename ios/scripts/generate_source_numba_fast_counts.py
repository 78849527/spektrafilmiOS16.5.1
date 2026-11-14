#!/usr/bin/env python3
"""Execute pinned upstream Numba fast_poisson/fast_binomial on ONE seeded CPU worker.

The original grain.py use_fast_stats=True branch runs two separate whole-array
passes. This script compares that order without changing fast_stats.py.
The source's unseeded multi-worker prange states remain unverified.
"""
from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path

import numba
import numpy as np
from numba import njit

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/utils/fast_stats.py"
GRAIN = ROOT / "src/spektrafilm/model/grain.py"
DEST = ROOT / "ios/SpektraFilmPort/GeneratedSourceNumbaFastCountsReference.swift"
FAST_BLOB = "9e80d29ce6b9f7820ae70f5c09da15edfaa70a0d"
GRAIN_BLOB = "f2d2b23e3eab4f4a1d919f69bcb4aceb714e024d"


def git_blob(path: Path) -> str:
    raw = path.read_bytes()
    return hashlib.sha1(
        b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw
    ).hexdigest()


@njit
def seed_numba(seed):
    np.random.seed(seed)


@njit
def next_source_uniform():
    return np.random.rand()


def swift_doubles(values):
    return "[" + ", ".join(format(float(v), ".17g") for v in values) + "]"


def swift_ints(values):
    return "[" + ", ".join(str(int(v)) for v in values) + "]"


def main():
    assert git_blob(SOURCE) == FAST_BLOB, "fast_stats.py changed: explicit re-audit required"
    assert git_blob(GRAIN) == GRAIN_BLOB, "grain.py changed: explicit re-audit required"
    source_text = GRAIN.read_text(encoding="utf8")
    assert "poisson_rvs = fast_poisson" in source_text
    assert "binom_rvs = fast_binomial" in source_text
    assert source_text.index("seeds = poisson_rvs(") < source_text.index(
        "grain = binom_rvs("
    ), "source phase order changed"
    spec = importlib.util.spec_from_file_location("pinned_numba_fast_stats", SOURCE)
    assert spec is not None and spec.loader is not None
    upstream = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upstream)

    numba.set_num_threads(1)
    # Warm the Numba jit before establishing the explicit RNG seed.
    upstream.fast_poisson(np.asarray([1.0, 35.0], dtype=np.float64))
    upstream.fast_binomial(
        np.asarray([5, 50], dtype=np.int64),
        np.asarray([0.5, 0.5], dtype=np.float64),
    )
    seed_numba(0)
    next_source_uniform()
    chain_rates_base = np.asarray(
        [0.0, -1.0, 0.01, 0.5, 7.29, 22.71, 29.9, 30.0,
         30.1, 52.0, 120.0, 500.0], dtype=np.float64
    )
    chain_probs_base = np.asarray(
        [0.0, 1.0, 1e-6, 0.02, 0.3, 0.5, 0.7, 0.98,
         0.9999, 0.1, 0.9, 0.4], dtype=np.float64
    )
    rates = np.tile(chain_rates_base, 5)
    probs = np.tile(chain_probs_base, 5)
    # Keep p in a source-valid range, but exercise both bounded and
    # unbounded parameter branches (the source clamps none of them here).
    fixed_ns = np.tile(
        np.asarray([0, 1, 24, 25, 26, 50, 80, 500, 1000, 30, 12, 120],
                   dtype=np.int64), 5
    )
    fixed_ps = np.tile(
        np.asarray([0, 1, 1e-6, 0.01, 0.2, 0.3, 0.5, 0.8,
                    0.99, 0.999999, 0.9, 0.4], dtype=np.float64), 5
    )
    seeds = [0, 8888, 123456]
    lines = [
        "// Executed original upstream fast_stats.py, NumPy2.4/Numba0.64.",
        "// One explicitly seeded prange worker ONLY; not production RNG parity.",
        "enum GeneratedSourceNumbaFastCountsReference {",
        '    static let fastStatsBlob = "' + FAST_BLOB + '"',
        '    static let grainBlob = "' + GRAIN_BLOB + '"',
        "    struct Case {",
        "        let seed: UInt32",
        "        let rates: [Double]",
        "        let probabilities: [Double]",
        "        let poisson: [Int64]",
        "        let binomial: [Int64]",
        "        let afterPoisson: Double",
        "        let afterBinomial: Double",
        "        let fixedNs: [Int64]",
        "        let fixedPs: [Double]",
        "        let fixedBinomial: [Int64]",
        "        let afterFixedBinomial: Double",
        "    }",
        "    static let cases: [Case] = [",
    ]

    for seed in seeds:
        seed_numba(seed)
        p_source = upstream.fast_poisson(rates)
        b_source = upstream.fast_binomial(p_source, probs)
        after_binomial = float(next_source_uniform())

        # Non-consuming probe: reset/replay the upstream Poisson pass, then
        # inspect the next uniform. The main production chain never performs
        # this extra draw.
        seed_numba(seed)
        p_replay = upstream.fast_poisson(rates)
        assert np.array_equal(p_replay, p_source)
        after_poisson = float(next_source_uniform())

        fixed_seed = seed + 1
        seed_numba(fixed_seed)
        b_fixed = upstream.fast_binomial(fixed_ns, fixed_ps)
        after_fixed = float(next_source_uniform())

        direct = 0
        normal = 0
        inversion = 0
        skipped = 0
        for n, p in zip(fixed_ns, fixed_ps):
            if p <= 0 or p >= 1:
                skipped += 1
            elif n < 25:
                direct += 1
            elif n * p * (1-p) > 10:
                normal += 1
            else:
                inversion += 1
        assert min(direct, normal, inversion, skipped) > 0, (
            "missing a Numba fast_binomial branch in fixtures"
        )
        assert (p_source < 0).sum() == 0
        lines.extend([
            "        Case(",
            f"            seed: {seed},",
            f"            rates: {swift_doubles(rates)},",
            f"            probabilities: {swift_doubles(probs)},",
            f"            poisson: {swift_ints(p_source)},",
            f"            binomial: {swift_ints(b_source)},",
            f"            afterPoisson: {after_poisson:.17g},",
            f"            afterBinomial: {after_binomial:.17g},",
            f"            fixedNs: {swift_ints(fixed_ns)},",
            f"            fixedPs: {swift_doubles(fixed_ps)},",
            f"            fixedBinomial: {swift_ints(b_fixed)},",
            f"            afterFixedBinomial: {after_fixed:.17g}",
            "        ),",
        ])
        print(
            f"PASS: pinned fast_stats.py seed={seed} single worker: "
            f"{len(p_source)} Poisson, {len(b_source)} two-phase Binomial, "
            f"{len(b_fixed)} boundary Binomial; "
            f"branch counts direct={direct}, normal={normal}, "
            f"inversion={inversion}, skipped={skipped}"
        )
    lines.extend(["    ]", "}"])
    DEST.write_text("\n".join(lines) + "\n", encoding="utf8")
    print("NOT CERTIFIED: unseeded Numba prange threads, GPU, full-frame RGB.")


if __name__ == "__main__":
    main()
