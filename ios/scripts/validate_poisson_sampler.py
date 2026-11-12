#!/usr/bin/env python3
"""Non-GPU check for the precise Metal low-rate Poisson convergence fix.

The native shader remains the authority for actual hardware pass/fail.
This is a numerical reproducibility and distribution regression test;
passing it MUST NOT be labeled native Metal parity or SciPy RNG equality.
"""
from __future__ import annotations

import math
from pathlib import Path
import numpy as np
from scipy.stats import poisson

ROOT = Path(__file__).resolve().parents[2]
METAL = ROOT / "ios/SpektraFilmPort/OriginalGrainKernels.metal"


def float32_cdf_sum(rate: float) -> np.float32:
    """Reproduce the known old failure mechanism (for regression context)."""
    prob = np.float32(math.exp(-rate))
    total = prob
    for k in range(1, 512):
        prob = np.float32(prob * np.float32(rate) / np.float32(k))
        total = np.float32(total + prob)
    return total


def knuth_poisson_vectorized(rate: float, n: int, seed: int) -> np.ndarray:
    """Exact-law product sampler with Float32 multiplication, no CDF sum.

    Use independent 24-bit *open interval* uniforms like the shader. This
    test checks numeric behavior and moments, NOT the shader's hash RNG.
    """
    rng = np.random.default_rng(seed)
    product = np.ones(n, np.float32)
    active = np.ones(n, dtype=bool)
    samples = np.full(n, -1, dtype=np.int32)
    threshold = np.float32(math.exp(-rate))
    for k in range(512):
        count = int(active.sum())
        if count == 0:
            break
        integer_random = rng.integers(0, 2**24, size=count, dtype=np.uint32)
        u = (
            integer_random.astype(np.float32) + np.float32(0.5)
        ) / np.float32(2**24)
        u = np.clip(
            u, np.float32(2**-24), np.float32(1 - 2**-23)
        )
        product[active] = np.float32(product[active] * u)
        finished = active & (product <= threshold)
        samples[finished] = k
        active[finished] = False
    assert np.all(samples >= 0), (
        "Knuth sampler did not converge within 512 independent draws"
    )
    return samples


def main():
    src = METAL.read_text(encoding="utf-8")
    start = src.index("if (lambda < 30.0f)")
    end = src.index("float root=sqrt(lambda);", start)
    low = src[start:end]
    assert "product *= filmUniform" in low
    assert "product <= threshold" in low
    assert "float cum=prob" not in low and "prob *= lambda" not in low
    assert "atomic_fetch_add_explicit(errors" in low, (
        "Real sampler failure must not silently fall back or return a mean"
    )
    # Float32 CDF cannot represent some high-probability tails; reproduce
    # a known concrete failure at lambda~22.71, which can occur in real
    # color/sublayer counts at the 4K full-resolution pixel scale.
    old_cdf = float32_cdf_sum(22.71)
    u = np.float32(0.9999998807907104)
    assert old_cdf < u, (
        "Known old CDF saturation fixture no longer reproduces; "
        "update evidence before changing the fix"
    )

    for index, rate in enumerate((0.1, 1.0, 7.29, 22.71, 29.9)):
        size = 24_000
        values = knuth_poisson_vectorized(rate, size, 8888 + index)
        actual_mean = float(values.mean())
        actual_variance = float(values.var())
        # Conservative independent sampling tolerance of ~7 sigma.
        mean_limit = 7 * math.sqrt(rate / size) + 0.025
        variance_limit = 12 * math.sqrt(2.0 / size) + 0.03
        assert abs(actual_mean - rate) <= mean_limit, (
            f"Poisson mean deviates: lambda={rate}, mean={actual_mean}"
        )
        assert abs(actual_variance - rate) / rate <= variance_limit, (
            f"Poisson variance deviates: lambda={rate}, "
            f"variance={actual_variance}"
        )
        # Check the probability of zero independently against SciPy.
        zero_empirical = float(np.mean(values == 0))
        zero_exact = float(poisson.pmf(0, rate))
        zero_margin = 7 * math.sqrt(
            max(zero_exact * (1 - zero_exact), 0) / size
        ) + 0.003
        assert abs(zero_empirical - zero_exact) <= zero_margin
        print(
            f"PASS: source-law lambda={rate:.2f} "
            f"mean={actual_mean:.5f}, variance={actual_variance:.5f}, "
            f"zero_p={zero_empirical:.7f}"
        )

    print(
        "PASS: Float32 CDF false nonconvergence reproduced; "
        "Knuth exact-law low-rate sampler passes independent statistical "
        "checks. Actual on-device Metal and SciPy stream parity remain UNVERIFIED."
    )


if __name__ == "__main__":
    main()
