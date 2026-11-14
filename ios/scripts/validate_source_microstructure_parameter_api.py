#!/usr/bin/env python3
"""Execute pinned upstream grain.py microstructure function unchanged.

Only the random/lognormal output and Gaussian implementation are instrumented
at their call boundaries. This checks the source's parameter units, activation
thresholds, blur dispatch, and mutation without asserting Numba RNG equivalence.
"""
from __future__ import annotations
import ast
import hashlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/model/grain.py"
PINNED_GIT_BLOB = "f2d2b23e3eab4f4a1d919f69bcb4aceb714e024d"
CASES = [
    (9.0, 0.2, 30.0),
    (0.6, 0.2, 30.0),
    (0.4, 0.2, 30.0),
    (0.1, 0.0, 50.0),
    (0.05, 0.3, 0.0),
    (0.05, 0.001, 10.0),
    (0.02, 1.0, 5.0),
]


def load_upstream():
    raw = SOURCE.read_bytes()
    blob = hashlib.sha1(
        b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw
    ).hexdigest()
    assert blob == PINNED_GIT_BLOB, (
        "Upstream grain.py changed: review source diff, do not rebaseline",
        blob,
        PINNED_GIT_BLOB,
    )
    tree = ast.parse(raw, filename=str(SOURCE))
    selected = [
        node for node in tree.body
        if isinstance(node, ast.FunctionDef)
        and node.name == "add_micro_structure"
    ]
    assert len(selected) == 1, "Source microstructure function changed"
    instrumented = []
    def lognormal(mean, std):
        instrumented.append(("lognormal", float(np.max(std))))
        assert np.all(mean == 1), "Unexpected original mean input"
        return np.ones_like(mean)
    def gaussian(value, sigma):
        instrumented.append(("gaussian", float(sigma)))
        return value
    ns = {
        "np": np,
        "fast_lognormal_from_mean_std": lognormal,
        "fast_gaussian_filter": gaussian,
    }
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(SOURCE), "exec"), ns)
    return ns["add_micro_structure"], instrumented


def main():
    upstream, calls = load_upstream()
    base = np.linspace(0.1, 2.0, 12, dtype=np.float64).reshape(2, 2, 3)
    for pixel, blur_um, strength_nm in CASES:
        calls.clear()
        output = upstream(base.copy(), (blur_um, strength_nm), pixel)
        sigma = strength_nm * 0.001 / pixel
        blur = blur_um / pixel
        expected = []
        if sigma > 0.05:
            expected.append(("lognormal", sigma))
            if blur > 0.4:
                expected.append(("gaussian", blur))
        assert len(calls) == len(expected), (pixel, calls, expected)
        for (kind, value), (kind_ref, expected_value) in zip(calls, expected):
            assert kind == kind_ref
            assert abs(value - expected_value) <= 1e-14 * (
                1 + abs(expected_value)
            ), (pixel, kind, value, expected_value)
        # Injected identity random/blur functions must not change density.
        np.testing.assert_array_equal(output, base)
        print(
            f"PASS: upstream microstructure pixelUM={pixel:.8g} "
            f"blurUM={blur_um:.8g} strengthNM={strength_nm:.8g} "
            f"source sigma={sigma:.8g} blurPixel={blur:.8g} "
            f"calls={[kind for kind, _ in calls]}"
        )
    print("PASS: 7 source AST μm/nm parameter dispatch cases; "
          "Numba parallel random stream NOT CERTIFIED")


if __name__ == "__main__":
    main()
