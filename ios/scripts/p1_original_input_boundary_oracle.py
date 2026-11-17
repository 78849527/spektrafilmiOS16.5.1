#!/usr/bin/env python3
"""Run frozen ORIGINAL Python input-range boundary oracle; no iOS pass claim."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/utils/spectral_upsampling.py"
sys.path.insert(0, str(ROOT / "src"))

# Negative, superwhite, zero, out-of-gamut and ordinary inputs.
# Keep values verbatim; source only bounds final TC LUT lookup, not raw RGB.
CASES = np.asarray(
    [
        [-0.125, 0.25, 0.65],
        [1.35, 0.20, 0.10],
        [0.0, 0.0, 0.0],
        [1.5, 1.5, 1.5],
        [-0.35, -0.20, -0.10],
        [0.184, 0.184, 0.184],
        [0.01, 1.75, 0.01],
    ], dtype=np.float64
).reshape(1, 7, 3)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    from spektrafilm.utils.spectral_upsampling import _rgb_to_tc_b
    cases = []
    for color_space, cctf in [
        ("sRGB", True),
        ("sRGB", False),
        ("ACES2065-1", False),
        ("ProPhoto RGB", False),
    ]:
        tc, brightness = _rgb_to_tc_b(
            CASES,
            color_space=color_space,
            apply_cctf_decoding=cctf,
            reference_illuminant="D55",
        )
        assert tc.shape == (1, 7, 2)
        assert brightness.shape == (1, 7)
        assert np.isfinite(tc).all(), f"nonfinite original TC: {color_space}"
        assert np.isfinite(brightness).all(), f"nonfinite original Y: {color_space}"
        assert np.logical_and(tc >= 0.0, tc <= 1.0).all()
        cases.append({
            "color_space": color_space,
            "apply_cctf_decoding": cctf,
            "reference_illuminant": "D55",
            "input_rgb": CASES[0].tolist(),
            "tc": tc[0].tolist(),
            "brightness": brightness[0].tolist(),
        })
    result = {
        "source": "src/spektrafilm/utils/spectral_upsampling.py::_rgb_to_tc_b",
        "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "note": "Original Python TC/brightness oracle only. No iOS stage or whole-image equivalence claimed.",
        "cases": cases,
    }
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(encoded)
    print("PASS original Python negative/superwhite/OOG TC+brightness reference computation")
    print(f"cases={len(cases)} rgb_samples={len(CASES[0])}")
    if not args.out:
        print(encoded)


if __name__ == "__main__":
    main()
