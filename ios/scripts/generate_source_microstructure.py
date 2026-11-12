#!/usr/bin/env python3
"""Source-derived deterministic microstructure transform fixture.

Only the deterministic part is covered: grain.py add_micro_structure() and
fast_stats.py fast_lognormal_from_mean_std(). The upstream Numba PRNG uses
independent thread state, so we inject known N(0,1) samples at the RNG
boundary. Do NOT call it a source Numba random-stream equivalence test.
"""
from __future__ import annotations

import hashlib
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GRAIN = ROOT / "src/spektrafilm/model/grain.py"
FAST = ROOT / "src/spektrafilm/utils/fast_stats.py"
DEST = ROOT / "ios/SpektraFilmPort/GeneratedSourceMicrostructureReference.swift"
NORMALS = [-2.5, 0.0, 1.25, -0.75, 2.0, -1.1, 0.4, 1.8, -1.9]


def swift(a):
    return "[" + ",".join(format(float(x), ".17g") for x in a) + "]"


def main():
    grain = GRAIN.read_text(encoding="utf-8")
    fast = FAST.read_text(encoding="utf-8")
    # Pin source statements. This does not rewrite or approximate their math.
    for token in (
        "grain_micro_structure_blur_pixel = micro_structure[0]/pixel_size_um",
        "grain_micro_structure_sigma = micro_structure[1]*0.001/pixel_size_um",
        "if grain_micro_structure_sigma > 0.05:",
        "if grain_micro_structure_blur_pixel>0.4:",
    ):
        assert token in grain, "Original microstructure gating has changed!"
    for token in (
        "sigma2 = np.log(1.0 + (s * s) / (m * m))",
        "flat_sigma[i] = sqrt(sigma2)",
        "flat_mu[i] = np.log(m) - sigma2 / 2.0",
        "flat_result[i] = exp(mu_val + sigma_val * z)",
    ):
        assert token in fast, "Original Numba mean/std transform has changed!"

    lines = [
        "// Derived from the pinned source fast_stats.py and grain.py.",
        "// Deterministic Gaussian input supplied at the RNG boundary.",
        "// DOES NOT claim original Numba random thread-state equivalence.",
        "enum GeneratedSourceMicrostructureReference {",
        f'    static let grainSHA = "{hashlib.sha256(GRAIN.read_bytes()).hexdigest()}"',
        f'    static let fastStatsSHA = "{hashlib.sha256(FAST.read_bytes()).hexdigest()}"',
        "    struct Case {",
        "        let pixelUM: Double",
        "        let microStd: Double",
        "        let microBlur: Double",
        "        let enabled: Bool",
        "        let normals: [Double]",
        "        let expected: [Double]",
        "    }",
        "    static let cases: [Case] = [",
    ]
    for pixel in (9.0, 0.6, 0.4, 0.2, 0.05):
        std = 30 * 0.001 / pixel
        blur = 0.2 / pixel
        enabled = std > 0.05
        if enabled:
            # Source uses np.log(1 + s*s), NOT log1p(s*s).
            sigma2 = math.log(1 + std * std)
            mu = -sigma2 / 2
            sigma = math.sqrt(sigma2)
            values = [math.exp(mu + sigma * z) for z in NORMALS]
        else:
            values = [1.0] * len(NORMALS)
        lines.extend([
            "        Case(",
            f"            pixelUM: {pixel:.17g},",
            f"            microStd: {std:.17g},",
            f"            microBlur: {blur:.17g},",
            f"            enabled: {str(enabled).lower()},",
            f"            normals: {swift(NORMALS)},",
            f"            expected: {swift(values)}",
            "        ),",
        ])
    lines.extend(["    ]", "}"])
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("PASS: source-pinned grain.py/fast_stats.py deterministic lognormal 5 cases; independent Numba RNG excluded")


if __name__ == "__main__":
    main()
