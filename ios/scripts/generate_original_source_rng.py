#!/usr/bin/env python3
"""Extract and execute UNMODIFIED upstream SpektraFilm grain functions.

This creates frozen SciPy NumPy legacy-RNG source reference vectors for
future Swift/Metal verification. A distribution-equivalent Poisson-thinning
draw does NOT reproduce the source random sequence; never label that
implementation pixel-equivalent based only on statistical tests.

The three source functions are compiled directly from the original
src/spektrafilm/model/grain.py AST. The original fast_gaussian_filter and
fast_stats helpers are imported directly from their source files to avoid
unrelated GUI/RAW dependencies in package __init__.
"""
from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import numpy as np
import scipy
import scipy.stats

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/model/grain.py"
PROFILE = ROOT / "src/spektrafilm/data/profiles/kodak_portra_400.json"
DEST = ROOT / "ios/SpektraFilmPort/GeneratedOriginalSourceRNGReference.swift"


def direct_import(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def original_functions():
    source = SOURCE.read_bytes()
    parsed = ast.parse(source, filename=str(SOURCE))
    desired = {
        "layer_particle_model",
        "add_micro_structure",
        "apply_grain_to_density_layers",
    }
    definitions = [
        node for node in parsed.body
        if isinstance(node, ast.FunctionDef) and node.name in desired
    ]
    assert {node.name for node in definitions} == desired, (
        "Upstream grain function names changed; do not substitute local math"
    )
    fast = direct_import(
        ROOT / "src/spektrafilm/utils/fast_gaussian_filter.py",
        "source_gaussian_for_rng_reference",
    )
    stats = direct_import(
        ROOT / "src/spektrafilm/utils/fast_stats.py",
        "source_fast_stats_for_rng_reference",
    )
    ns = {
        "np": np,
        "scipy": scipy,
        "fast_gaussian_filter": fast.fast_gaussian_filter,
        "fast_binomial": stats.fast_binomial,
        "fast_poisson": stats.fast_poisson,
        "fast_lognormal_from_mean_std": stats.fast_lognormal_from_mean_std,
    }
    module = ast.fix_missing_locations(
        ast.Module(body=definitions, type_ignores=[])
    )
    exec(compile(module, str(SOURCE), "exec"), ns)
    return ns, hashlib.sha256(source).hexdigest()


def swift_doubles(array) -> str:
    flat = np.asarray(array, dtype=np.float64).ravel(order="C")
    assert np.all(np.isfinite(flat))
    return "[" + ",".join(format(float(v), ".17g") for v in flat) + "]"


def main():
    source, digest = original_functions()
    density = np.linspace(0.06, 1.86, 7 * 11, dtype=np.float64).reshape(7, 11)
    cases = []
    for particles in (8.0, 40.0, 800.0):
        args = dict(
            density_max=2.2,
            n_particles_per_pixel=particles,
            grain_uniformity=0.97,
            seed=8888,
            blur_particle=0.0,
            method="poisson_binomial",
            use_fast_stats=False,
        )
        result = source["layer_particle_model"](density.copy(), **args)
        repeat = source["layer_particle_model"](density.copy(), **args)
        assert np.array_equal(result, repeat), (
            "Original SciPy seeded particle output is not repeatable"
        )
        assert result.shape == density.shape and np.all(np.isfinite(result))
        cases.append((particles, result))

    # Statistical law is checked separately from exact SciPy PRNG sequence.
    p = 0.46
    maximum = 2.2
    n = 120.0
    uniformity = 0.97
    flat = np.full((160, 160), maximum * p, dtype=np.float64)
    draw = source["layer_particle_model"](
        flat, density_max=maximum, n_particles_per_pixel=n,
        grain_uniformity=uniformity, seed=8888,
        blur_particle=0.0, method="poisson_binomial", use_fast_stats=False
    )
    saturation = 1 - p * uniformity * (1 - 1e-6)
    expected_mean = maximum * p
    expected_variance = maximum * maximum * p * saturation / n
    measured_mean = float(np.mean(draw))
    measured_variance = float(np.var(draw))
    assert abs(measured_mean - expected_mean) < 0.01, (
        "Original source sample mean deviates from Poisson/Binomial law"
    )
    assert abs(measured_variance / expected_variance - 1) < 0.12, (
        "Original source sample variance deviates from Poisson/Binomial law"
    )

    # Full source nine-sublayer grain path, including actual dye clouds and
    # final reflect blur. Pixel=9um intentionally keeps microstructure off:
    # original fast_lognormal uses independent Numba RNG state, which cannot
    # be truthfully represented as NumPy/SciPy deterministic stream parity.
    stock = json.loads(PROFILE.read_text(encoding="utf-8"))
    maxima = np.nanmax(
        np.asarray(stock["data"]["density_curves_layers"], np.float64), axis=0
    )
    assert maxima.shape == (3, 3) and np.all(np.isfinite(maxima))
    yy, xx = np.mgrid[0:7, 0:11]
    gradient = (0.10 + (xx / 11.0) * 0.55 + (yy / 7.0) * 0.12)
    layer_input = np.broadcast_to(
        gradient[:, :, None, None] * maxima[None, None, :, :],
        (7, 11, 3, 3),
    ).copy()
    full_kwargs = dict(
        density_max_layers=maxima.copy(),
        pixel_size_um=9.0,
        particle_area_um2=0.2,
        particle_scale=[1.6, 1.6, 3.2],
        particle_scale_layers=[2.0, 1.0, 0.5],
        density_min=[0.03, 0.03, 0.03],
        grain_uniformity=[0.97, 0.99, 0.97],
        grain_blur=0.65,
        grain_blur_dye_clouds_um=1.0,
        grain_micro_structure=(0.2, 30),
        fixed_seed=None,
        use_fast_stats=False,
    )
    full = source["apply_grain_to_density_layers"](
        layer_input.copy(), **full_kwargs
    )
    repeat = source["apply_grain_to_density_layers"](
        layer_input.copy(), **full_kwargs
    )
    assert full.shape == (7, 11, 3) and np.all(np.isfinite(full))
    assert np.array_equal(full, repeat), (
        "Original full-chain SciPy seeded optical density is not repeatable"
    )

    lines = [
        "// Generated from unmodified upstream SpektraFilm grain.py AST.",
        "// SciPy PRNG stream reference; native Metal hash RNG is NOT equivalent.",
        "// No claims of GPU parity or complete original algorithm certification.",
        "enum GeneratedOriginalSourceRNGReference {",
        f'    static let grainSHA256 = "{digest}"',
        f'    static let numpyVersion = "{np.__version__}"',
        f'    static let scipyVersion = "{scipy.__version__}"',
        "    static let width = 11",
        "    static let height = 7",
        f"    static let sourceDensity: [Double] = {swift_doubles(density)}",
        "    struct ParticleCase {",
        "        let particlesPerPixel: Double",
        "        let expected: [Double]",
        "    }",
        "    static let particleCases: [ParticleCase] = [",
    ]
    for particles, sample in cases:
        lines.extend([
            "        ParticleCase(",
            f"            particlesPerPixel: {format(particles, '.17g')},",
            f"            expected: {swift_doubles(sample)}",
            "        ),",
        ])
    lines.extend([
        "    ]",
        f"    static let fullChainMaxima: [Double] = {swift_doubles(maxima)}",
        f"    static let fullChainInput: [Double] = {swift_doubles(layer_input)}",
        f"    static let fullChainExpected: [Double] = {swift_doubles(full)}",
        f"    static let sourceParticleMean = {format(measured_mean, '.17g')}",
        f"    static let sourceParticleVariance = {format(measured_variance, '.17g')}",
        f"    static let analyticParticleMean = {format(expected_mean, '.17g')}",
        f"    static let analyticParticleVariance = {format(expected_variance, '.17g')}",
        "}",
    ])
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        "PASS: original unmodified grain.py SciPy seed=8888 vectors "
        "(3 particle rates), 9-sublayer dye-cloud/full-chain reference, "
        "and analytic Poisson/Binomial moments; "
        "no Metal RNG pixel parity claimed."
    )


if __name__ == "__main__":
    main()
