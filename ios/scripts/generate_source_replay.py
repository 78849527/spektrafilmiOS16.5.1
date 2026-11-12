#!/usr/bin/env python3
"""v1.8.2 source replay: isolate original spatial/float parity from RNG.

Run UNMODIFIED upstream grain.py (AST) with real seeded SciPy
Poisson -> Binomial particle fields (nine 2-D streams). Only intercept the
random raw particle boundary and, where Numba microstructure is activated,
supply a fixed explicit lognormal input; every deterministic blur, density
sum, multiply and subtract still executes original upstream functions.
No claim is made that a Metal hash PRNG matches SciPy or Numba RNG.
"""
from __future__ import annotations
import hashlib
import json
import os
import tempfile
from pathlib import Path

# The source functions are imported from AST under a dynamic module. Numba
# cache pickles for that dynamically named module are not portable between
# independent reference generators. Use a clean cache per generator process
# rather than changing the source's @njit/fastmath algorithms.
os.environ["NUMBA_CACHE_DIR"] = tempfile.mkdtemp(prefix="spektra-source-replay-")

import numpy as np
from generate_original_source_rng import original_functions
from generate_original_metal_grain import ROOT, PROFILES

DEST = ROOT / "ios/SpektraFilmPort/GeneratedSourceReplayReference.swift"
MAXIMA_PATH = PROFILES / "kodak_portra_400.json"
HEIGHT, WIDTH = 7, 11
DENSITY_MIN = np.array([0.03, 0.03, 0.03], dtype=np.float64)
SCALES = np.array([1.6, 1.6, 3.2], dtype=np.float64)
LAYER_SCALES = np.array([2.0, 1.0, 0.5], dtype=np.float64)
UNIFORMITY = np.array([0.97, 0.99, 0.97], dtype=np.float64)


def swift_numbers(array):
    a = np.asarray(array, dtype=np.float64).ravel(order="C")
    assert np.all(np.isfinite(a))
    return "[" + ",".join(format(float(v), ".17g") for v in a) + "]"


def main():
    ns, grain_sha = original_functions()
    gaussian = ns["fast_gaussian_filter"]
    source_layer = ns["layer_particle_model"]
    original_full = ns["apply_grain_to_density_layers"]
    original_clump = ns["fast_lognormal_from_mean_std"]

    profile = json.loads(MAXIMA_PATH.read_text(encoding="utf-8"))
    maxima = np.nanmax(
        np.asarray(profile["data"]["density_curves_layers"], dtype=np.float64),
        axis=0,
    )
    assert maxima.shape == (3, 3) and np.all(maxima > 0)
    fraction = maxima / maxima.sum(axis=0, keepdims=True)
    yy, xx = np.mgrid[:HEIGHT, :WIDTH]
    gradient = 0.10 + xx * (0.55 / WIDTH) + yy * (0.12 / HEIGHT)
    layer_input = (
        gradient[:, :, None, None] * maxima[None, None, :, :]
    ).copy()

    lines = [
        "// SOURCE REPLAY only: deterministic source SciPy draw fields are injected.",
        "// Original Numba micro-randomness is replaced with a recorded input.",
        "// Validates downstream Float32 Metal blur / composition vs Float64 upstream.",
        "// DOES NOT certify source SciPy/Numba PRNG parity or final RGB parity.",
        "enum GeneratedSourceReplayReference {",
        f'    static let grainSHA256 = "{grain_sha}"',
        "    struct Case {",
        "        let name: String",
        "        let width: Int",
        "        let height: Int",
        "        let pixelUM: Double",
        "        let maxima: [Double]",
        "        let dyeSigmas: [Double]",
        "        let microSigma: Double",
        "        let microBlur: Double",
        "        let particlesBySublayer: [[Double]]",
        "        let microstructureInput: [Double]",
        "        let expectedDensity: [Double]",
        "    }",
        "    static let cases: [Case] = [",
    ]
    for pixel_um in (9.0, 0.4):
        n = pixel_um ** 2 * fraction / (
            0.2 * SCALES[None, :] * LAYER_SCALES[:, None]
        )
        full_max = maxima + DENSITY_MIN[None, :] * fraction
        dye_sigma = np.sqrt(full_max / n)
        micro_sigma = 0.03 / pixel_um
        micro_blur = 0.2 / pixel_um
        raw = {}
        for sl in range(3):
            for ch in range(3):
                density = (
                    layer_input[:, :, sl, ch] +
                    fraction[sl, ch] * DENSITY_MIN[ch]
                )
                raw[(sl, ch)] = source_layer(
                    density.copy(),
                    density_max=float(full_max[sl, ch]),
                    n_particles_per_pixel=float(n[sl, ch]),
                    grain_uniformity=float(UNIFORMITY[ch]),
                    seed=ch + sl * 10,
                    blur_particle=0.0,
                    method="poisson_binomial",
                    use_fast_stats=False,
                )

        fields = [
            np.stack([raw[(sl, ch)] for ch in range(3)], axis=-1)
            for sl in range(3)
        ]
        if micro_sigma > 0.05:
            rng = np.random.RandomState(8888)
            log_variance = np.log1p(micro_sigma * micro_sigma)
            clump = np.exp(
                -0.5 * log_variance +
                np.sqrt(log_variance) * rng.standard_normal(
                    (HEIGHT, WIDTH, 3)
                )
            )
        else:
            clump = np.ones((HEIGHT, WIDTH, 3), dtype=np.float64)

        def supplied_particles(
            density, density_max=2.2, n_particles_per_pixel=10,
            grain_uniformity=0.98, seed=None, blur_particle=0.0,
            method="poisson_binomial", use_fast_stats=False,
        ):
            assert seed is not None and seed in range(23)
            ch, sl = seed % 10, seed // 10
            assert 0 <= ch < 3 and 0 <= sl < 3
            assert np.allclose(
                density, layer_input[:, :, sl, ch] +
                fraction[sl, ch] * DENSITY_MIN[ch],
                rtol=0, atol=2e-15,
            ), "Source layer input changed"
            assert abs(density_max - full_max[sl, ch]) < 2e-14
            assert abs(n_particles_per_pixel - n[sl, ch]) < 2e-14
            assert abs(grain_uniformity - UNIFORMITY[ch]) < 1e-14
            assert not use_fast_stats and method == "poisson_binomial"
            radius = blur_particle * np.sqrt(density_max / n_particles_per_pixel)
            return gaussian(raw[(sl, ch)], radius) if radius > 0 else raw[(sl, ch)].copy()

        def supplied_micro(mean, std):
            assert mean.shape == (HEIGHT, WIDTH, 3)
            assert np.all(mean == 1)
            assert np.allclose(std, micro_sigma)
            return clump.copy()

        kwargs = dict(
            density_max_layers=maxima.copy(),
            pixel_size_um=pixel_um,
            particle_area_um2=0.2,
            particle_scale=SCALES.tolist(),
            particle_scale_layers=LAYER_SCALES.tolist(),
            density_min=DENSITY_MIN.tolist(),
            grain_uniformity=UNIFORMITY.tolist(),
            grain_blur=0.65,
            grain_blur_dye_clouds_um=1.0,
            grain_micro_structure=(0.2, 30),
            fixed_seed=None,
            use_fast_stats=False,
        )
        ns["layer_particle_model"] = supplied_particles
        ns["fast_lognormal_from_mean_std"] = supplied_micro
        expected = original_full(layer_input.copy(), **kwargs)
        assert expected.shape == (HEIGHT, WIDTH, 3)
        assert np.all(np.isfinite(expected))
        # With the lognormal path disabled, seeded replay must reproduce
        # the *unmodified* upstream all the way through source final blur.
        if micro_sigma <= 0.05:
            ns["layer_particle_model"] = source_layer
            ns["fast_lognormal_from_mean_std"] = original_clump
            direct = original_full(layer_input.copy(), **kwargs)
            assert np.max(np.abs(expected - direct)) < 1e-12, (
                "Source-replay injection diverged from real original RNG path"
            )
        lines.extend([
            "        Case(",
            f'            name: "pixel_um_{str(pixel_um).replace(".", "_")}",',
            f"            width: {WIDTH}, height: {HEIGHT},",
            f"            pixelUM: {format(pixel_um, '.17g')},",
            f"            maxima: {swift_numbers(maxima)},",
            f"            dyeSigmas: {swift_numbers(dye_sigma)},",
            f"            microSigma: {format(micro_sigma, '.17g')},",
            f"            microBlur: {format(micro_blur, '.17g')},",
            "            particlesBySublayer: [",
            *(f"                {swift_numbers(field)}," for field in fields),
            "            ],",
            f"            microstructureInput: {swift_numbers(clump)},",
            f"            expectedDensity: {swift_numbers(expected)}",
            "        ),",
        ])
        ns["layer_particle_model"] = source_layer
        ns["fast_lognormal_from_mean_std"] = original_clump
    lines.extend(["    ]", "}"])
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    assert hashlib.sha256((ROOT / "src/spektrafilm/model/grain.py").read_bytes()).hexdigest() == grain_sha
    print(
        "PASS: unmodified upstream grain.py 9-stream SciPy replay; "
        "pixel 9um direct path + pixel 0.4um controlled microstructure; "
        "no native RNG or Float64 equivalence claimed"
    )


if __name__ == "__main__":
    main()
