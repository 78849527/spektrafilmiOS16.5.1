#!/usr/bin/env python3
"""Unmodified SciPy 1.15.3 -> NumPy 1.26.4 RandomState Poisson/Binomial.

Verify the TWO-array consumption order of upstream grain.py; including
intermediate MT stream positions, not only statistical moments. The Swift
sampler is checked against all values and the next MT integer after
Poisson and after Binomial. Never silently replace SciPy with thinning.
"""
from __future__ import annotations

from pathlib import Path
import numpy as np
import scipy
import scipy.stats

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "ios/SpektraFilmPort/GeneratedOriginalSciPyRNGReference.swift"


def float_list(items):
    a = np.asarray(items, dtype=np.float64).ravel()
    assert np.all(np.isfinite(a))
    return "[" + ",".join(format(float(v), ".17g") for v in a) + "]"


def integer_list(items):
    a = np.asarray(items, dtype=np.int64).ravel()
    return "[" + ",".join(str(int(v)) for v in a) + "]"


def one(seed: int, rates, probabilities):
    rates = np.asarray(rates, dtype=np.float64)
    probabilities = np.asarray(probabilities, dtype=np.float64)
    assert rates.shape == probabilities.shape
    assert np.all(rates >= 0)
    assert np.all((probabilities > 0) & (probabilities < 1))
    np.random.seed(seed)
    original_poisson = scipy.stats.poisson.rvs(rates)
    after_poisson = np.random.get_state()
    last_after_poisson = np.random.randint(
        0, 2**32, dtype=np.uint32
    )
    # Restore the exact original state, then run second complete array.
    np.random.set_state(after_poisson)
    original_binomial = scipy.stats.binom.rvs(
        original_poisson, probabilities
    )
    after_binomial = np.random.get_state()
    last_after_binomial = np.random.randint(
        0, 2**32, dtype=np.uint32
    )
    # Direct NumPy RandomState verification: SciPy must be the same source
    # stream for the tested distributions / argument shapes.
    rng = np.random.RandomState(seed)
    direct_poisson = rng.poisson(rates)
    assert np.array_equal(original_poisson, direct_poisson), (
        "SciPy poisson.rvs differs from NumPy RandomState.poisson"
    )
    assert rng.get_state()[2] == after_poisson[2] and np.array_equal(
        rng.get_state()[1], after_poisson[1]
    ), "Poisson stream differs from source"
    direct_binomial = rng.binomial(direct_poisson, probabilities)
    assert np.array_equal(original_binomial, direct_binomial), (
        "SciPy binom.rvs differs from NumPy RandomState.binomial"
    )
    assert rng.get_state()[2] == after_binomial[2] and np.array_equal(
        rng.get_state()[1], after_binomial[1]
    ), "Binomial stream differs from source"
    return (
        rates, probabilities, original_poisson, original_binomial,
        int(last_after_poisson), int(last_after_binomial)
    )


def main():
    cases = []
    # Small lambda Knuth; large lambda NumPy PTRS; binomial inversion and
    # BTPE including p>0.5 mirror, with different scalar probabilities.
    cases.append(("scalar_thresholds", 8888, *one(
        8888,
        [0, .00001, .25, 1, 2.7, 9.999, 10, 10.001, 22.7, 29.99,
         30, 55, 96, 101, 150, 250, 800, 1200],
        [.01, .15, .2, .31, .49, .501, .7, .84, .3, .5,
         .99, .25, .51, .43, .49, .65, .87, .57]
    )))
    # Mixed realistic grain p and seed array. 216 draws cover multi-twist.
    rng = np.random.RandomState(173)
    p = rng.uniform(.01, .99, 216)
    rates = rng.uniform(1, 320, 216)
    cases.append(("heterogeneous216", 11, *one(11, rates, p)))
    # Uniform rates are important, as NumPy's array dispatch may reuse
    # cached binomial BTPE constants (n,p), unlike ad-hoc scalar testing.
    cases.append(("homogeneous192", 8888, *one(
        8888,
        np.full(192, 115.0),
        np.full(192, 0.48)
    )))
    cases.append(("near_boundary128", 20, *one(
        20, np.linspace(8, 300, 128),
        np.linspace(.995, .005, 128)
    )))
    # Actual upstream layer_particle_model: Poisson λ=n/sat, then binomial
    # with p from native density, per-channel seed.
    densities = np.linspace(.06, 1.86, 77)
    maximum = 2.2
    n_per_pixel = 40
    source_p = np.clip(densities / maximum, 1e-6, 1 - 1e-6)
    saturation = 1 - source_p * .97 * (1 - 1e-6)
    rate = n_per_pixel / saturation
    cases.append(("grain_layer77", 8888, *one(
        8888, rate, source_p
    )))
    lines = [
        "// Generated from unmodified scipy.stats poisson/binom using NumPy legacy RandomState.",
        "// Counts, draw ORDER and next MT32 words are exact stream checks.",
        f'// numpy={np.__version__}, scipy={scipy.__version__}.',
        "enum GeneratedOriginalSciPyRNGReference {",
        "    struct Case {",
        "        let name: String",
        "        let seed: UInt32",
        "        let rates: [Double]",
        "        let probabilities: [Double]",
        "        let poisson: [Int64]",
        "        let binomial: [Int64]",
        "        let nextAfterPoisson: UInt32",
        "        let nextAfterBinomial: UInt32",
        "    }",
        "    static let cases: [Case] = [",
    ]
    for name, seed, rates, probabilities, raw, developed, nextp, nextb in cases:
        lines.extend([
            "        Case(",
            f'            name: "{name}", seed: {seed},',
            f"            rates: {float_list(rates)},",
            f"            probabilities: {float_list(probabilities)},",
            f"            poisson: {integer_list(raw)},",
            f"            binomial: {integer_list(developed)},",
            f"            nextAfterPoisson: {nextp},",
            f"            nextAfterBinomial: {nextb}",
            "        ),",
        ])
    lines.extend(["    ]", "}"])
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"PASS: {len(cases)} source SciPy Poisson->Binomial 2-phase "
        "fixture arrays with native NumPy equality and final MT words"
    )


if __name__ == "__main__":
    main()
