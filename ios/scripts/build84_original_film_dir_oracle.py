#!/usr/bin/env python3
"""Build84: execute pinned original Python AST, not a rewritten oracle.

Only this source-root Python code can authorize numerical-equivalence claims.
Source contract: src/spektrafilm/model/{couplers,density_curves}.py,
runtime/params_schema.py and utils/fast_interp.py at the branch's
fixed upstream snapshot. Tests avoid installing the full application.
"""
import ast
import json
import pathlib
import sys
from dataclasses import dataclass

import numpy as np
from opt_einsum import contract


ROOT = pathlib.Path(__file__).resolve().parents[2] / "src/spektrafilm"

import subprocess

SOURCE_BLOBS = {
    "model/couplers.py": "148570aea33b77b57a14efca7577121631e4d2bc",
    "model/density_curves.py": "84256f303f2fb898071a5c09593b870df16b80e9",
    "runtime/params_schema.py": "bbbc257024906b30162c5151c1a293c31c8f8098",
    "utils/fast_interp.py": "bddcef872b1280fab2d9b9a1157ecc943d990fb2",
}


def verify_fixed_source():
    for path, expected in SOURCE_BLOBS.items():
        actual = subprocess.check_output(
            ["git", "hash-object", str(ROOT / path)],
            text=True
        ).strip()
        assert actual == expected, (
            "Original source changed, explicitly rebaseline: " + path
        )


def load_original(path, names, namespace):
    tree = ast.parse((ROOT / path).read_text(encoding="utf-8"), filename=path)
    found = [node for node in tree.body
             if isinstance(node, (ast.ClassDef, ast.FunctionDef))
             and node.name in names]
    assert {node.name for node in found} == set(names), (path, names)
    # Remove only runtime wrappers: execute the original Python function
    # bodies with NumPy arrays and range in place of Numba prange.
    for node in found:
        node.decorator_list = []
    fragment = ast.Module(body=found, type_ignores=[])
    ast.fix_missing_locations(fragment)
    exec(compile(fragment, path, "exec"), namespace)


class NumPyNumbaShim:
    prange = range


def main(output_path):
    verify_fixed_source()
    ns = {
        "np": np, "contract": contract, "dataclass": dataclass,
        "numba": NumPyNumbaShim(),
    }
    load_original("runtime/params_schema.py", ["DirCouplersParams"], ns)
    load_original("utils/fast_interp.py", ["fast_interp"], ns)
    load_original("model/density_curves.py",
                  ["interpolate_exposure_to_density"], ns)
    load_original("model/couplers.py", [
        "compute_dir_couplers_matrix",
        "compute_density_curves_before_dir_couplers",
        "compute_exposure_correction_dir_couplers",
    ], ns)

    p = ns["DirCouplersParams"]()
    matrix = ns["compute_dir_couplers_matrix"](p)
    log_axis = np.array([-2., -1., 0., 1., 2.], dtype=np.float64)
    curves = np.array([
        [.02, .08, .19],
        [.20, .40, .61],
        [.70, 1.00, 1.12],
        [1.30, 1.55, 1.60],
        [1.80, 2.00, 1.98],
    ], dtype=np.float64)
    raw = np.array([[[-2.5, -1.0, -0.5],
                     [0.0, 0.25, 1.3],
                     [2.2, -0.75, 0.6]]], dtype=np.float64)
    gamma = np.array([0.8, 1.0, 1.2], dtype=np.float64)
    output = {
        "logAxis": log_axis.tolist(),
        "densityCurves": curves.reshape(-1).tolist(),
        "matrix": matrix.reshape(-1).tolist(),
        "raw": raw.reshape(-1).tolist(),
        "gamma": gamma.tolist(),
        "hd": ns["interpolate_exposure_to_density"](
            raw, curves, log_axis, gamma).reshape(-1).tolist(),
    }
    dmax = np.nanmax(curves, axis=0)
    d = curves[2].reshape(1, 1, 3)
    zero = np.zeros((1, 1, 3), dtype=np.float64)
    for positive, label in ((False, "negative"), (True, "positive")):
        output["beforeDIR_" + label] = (
            ns["compute_density_curves_before_dir_couplers"](
                curves, log_axis, matrix, positive=positive
            ).reshape(-1).tolist()
        )
        for shift, suffix in ((0.0, ""), (0.2, "_highShift")):
            corrected = ns["compute_exposure_correction_dir_couplers"](
                zero, d, dmax, matrix, diffusion_size_pixel=0,
                high_exposure_couplers_shift=shift, positive=positive
            )
            output["inhibitors_" + label + suffix] = (
                -corrected).reshape(-1).tolist()
    pathlib.Path(output_path).write_text(
        json.dumps(output, separators=(",", ":"), allow_nan=False),
        encoding="utf-8")
    print("SOURCE PYTHON AST PASS: 2 film polarities, 2 shift modes, "
          "5x3 curve nodes, per-channel gamma, spatial-off branch")


if __name__ == "__main__":
    main(sys.argv[1])
