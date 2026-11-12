#!/usr/bin/env python3
"""Generate bit-exact NumPy RandomState MT19937 / random_sample fixtures.

This tests only the original uniform MT core, NOT SciPy Poisson/Binomial
sampling order nor independent Numba fast_lognormal state. Do not claim
source-grain pixel parity from uniform-bitstream matches.
"""
from __future__ import annotations
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "ios/SpektraFilmPort/GeneratedSourceMT19937Reference.swift"


def doubles(a):
    return "[" + ",".join(format(float(v), ".17g") for v in a) + "]"


def main():
    lines = [
        "// Directly generated from numpy.random.RandomState seeded legacy MT.",
        "// Exact uniform core only; not an exact scipy.stats distribution engine.",
        "enum GeneratedSourceMT19937Reference {",
        "    struct Case {",
        "        let seed: UInt32",
        "        let uint32: [UInt32]",
        "        let uniform53: [Double]",
        "    }",
        "    static let cases: [Case] = [",
    ]
    for seed in (0, 1, 8888, 4294967295):
        integer_rng = np.random.RandomState(seed)
        uint32 = integer_rng.randint(
            0, 2**32, size=660, dtype=np.uint32
        ).tolist()
        uniform_rng = np.random.RandomState(seed)
        uniform53 = uniform_rng.random_sample(40).tolist()
        lines.extend([
            "        Case(",
            f"            seed: {seed},",
            "            uint32: [" + ",".join(str(v) for v in uint32) + "],",
            f"            uniform53: {doubles(uniform53)}",
            "        ),",
        ])
    lines.extend(["    ]", "}"])
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("PASS: generated NumPy legacy MT19937 first 660 words / 40 double uniforms for four seeds")


if __name__ == "__main__":
    main()
