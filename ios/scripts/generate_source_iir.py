#!/usr/bin/env python3
"""Reference vectors from the UNMODIFIED upstream source YVV IIR implementation.

Source: src/spektrafilm/utils/fast_gaussian_filter.py
No SciPy convolution substituted: source large-sigma path is recursive YVV,
not the ideal Gaussian and not the small-sigma FIR.
"""
from pathlib import Path
import sys
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "src"))
from spektrafilm.utils.fast_gaussian_filter import (  # noqa: E402
    fast_gaussian_filter, _yvv_coeffs,
)

DEST = ROOT / "ios/SpektraFilmPort/GeneratedSourceIIRReference.swift"


def doubles(values):
    return "[" + ",".join(format(float(x), ".17g") for x in np.ravel(values)) + "]"


def main():
    result = [
        "// Generated directly from upstream fast_gaussian_filter (Numba YVV).",
        "// Exact PRNG alignment is outside the scope of this deterministic test.",
        "enum GeneratedSourceIIRReference {",
        "  struct Case {",
        "    let name: String",
        "    let width: Int",
        "    let height: Int",
        "    let sigmas: [Double]",
        "    let input: [Double]",
        "    let expected: [Double]",
        "  }",
        "  static let cases: [Case] = [",
    ]
    h, w = 7, 13
    impulse = np.zeros((h, w, 3), dtype=np.float32)
    impulse[0, 0, :] = [1.0, 0.3, 0.8]
    yy, xx = np.mgrid[0:h, 0:w]
    gradient = np.stack(
        [(xx + yy * 2) / 30, (12 - xx + yy) / 22,
         (xx * yy + 3) / 90], axis=2
    ).astype(np.float32)
    cases = [
        ("corner-impulse", impulse, [3.0, 5.0, 7.5]),
        ("color-gradient", gradient, [3.2, 3.4, 4.1]),
    ]
    for name, source, sigmas in cases:
        original = fast_gaussian_filter(
            source, np.array(sigmas, dtype=np.float64)
        )
        assert original.shape == source.shape and np.all(np.isfinite(original))
        result += [
            "    Case(",
            f'      name: "{name}", width: {w}, height: {h},',
            f"      sigmas: {doubles(sigmas)},",
            f"      input: {doubles(source)},",
            f"      expected: {doubles(original)}",
            "    ),",
        ]
    result += ["  ]",
               "  static let coefficients: [[Double]] = ["]
    for sigma in [3.0, 5.0, 7.5, 3.2, 3.4, 4.1]:
        result.append(f"    {doubles(_yvv_coeffs(sigma))},")
    result.extend(["  ]", "}"])
    DEST.write_text("\n".join(result) + "\n", encoding="utf-8")
    print("PASS: source YVV Float32/Numba arrays, corner impulse, gradient, and Float64 coefficients.")


if __name__ == "__main__":
    main()
