#!/usr/bin/env python3
"""Pinned original SpektraFilm RAW whitepoint and ACES CAT02 adaptation oracle.

Execute the actual upstream Python function AST, with original colour-science
0.4.6 dependency. This does NOT assert rawpy/libraw decoder or lensfun parity.
"""
from __future__ import annotations

import argparse
import ast
import json
import subprocess
from pathlib import Path

import colour
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/utils/raw_file_processor.py"
BLOB_SHA = "97e34feb80fe47a6a3b36fcb93bef626d397135a"


def pinned_original():
    git_blob = subprocess.check_output(
        ["git", "hash-object", str(SOURCE)], cwd=ROOT, text=True
    ).strip()
    if git_blob != BLOB_SHA:
        raise RuntimeError(f"RAW Python source drift: {git_blob} != {BLOB_SHA}")
    if colour.__version__ != "0.4.6":
        raise RuntimeError(
            f"Colour-science reference must be pinned to 0.4.6, got {colour.__version__}"
        )
    parsed = ast.parse(SOURCE.read_text("utf8"), filename=str(SOURCE))
    names = {
        "_whitepoint_xyz_from_temperature",
        "_apply_white_balance_adaptation",
    }
    selected = [
        x for x in parsed.body if isinstance(x, ast.FunctionDef) and x.name in names
    ]
    if len(selected) != len(names):
        raise RuntimeError("Missing source whitepoint/adaptation method")
    m = ast.fix_missing_locations(ast.Module(body=selected, type_ignores=[]))
    ns = {
        "np": np,
        "colour": colour,
        "_ACES_COLOURSPACE": colour.RGB_COLOURSPACES["ACES2065-1"],
    }
    exec(compile(m, str(SOURCE), "exec"), ns)
    return ns


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = pinned_original()
    whitepoint = source["_whitepoint_xyz_from_temperature"]
    adapt = source["_apply_white_balance_adaptation"]

    # Input is real Float32 ACES AP0 values, not a rendered Apple sRGB pixel.
    bits = np.array([
        0x3E99999A, 0x3E4CCCCD, 0x3FC00000,
        0x00000001, 0x80000000, 0x3F800000,
        0xBFC00000, 0x3F000000, 0x41200000,
        0x3F800000, 0xBF000000, 0x3EAAAAAB,
        0x3F4CCCCD, 0x00000000, 0x3F666666,
        0x40800000, 0x3DCCCCCD, 0x80000001,
    ], dtype=np.uint32)
    image = bits.view(np.float32).reshape(2, 3, 3)
    target = whitepoint(6504.0)
    cases = []
    for temp in [2000.0, 2850.0, 3999.0, 4000.0,
                 6504.0, 7000.0, 9000.0, 25000.0]:
        source_white = whitepoint(temp)
        actual = adapt(image.copy(), source_white, target)
        if actual.dtype != np.float32 or actual.shape != image.shape:
            raise RuntimeError("Original ACES adaptation altered image dtype/shape")
        if not np.all(np.isfinite(actual)):
            raise RuntimeError("Original adaptation produced nonfinite for fixtures")
        cases.append({
            "temperature": temp,
            "whitepoint_xyz": [float(v) for v in source_white],
            "expected_bits": actual.reshape(-1).view(np.uint32).tolist(),
        })

    output = {
        "source_git_blob_sha": BLOB_SHA,
        "colour_science": colour.__version__,
        "method": "original colour.chromatic_adaptation(method=Von Kries, default CAT02)",
        "rgb_space": "ACES2065-1/linear/AP0/float32",
        "target_whitepoint_xyz": [float(v) for v in target],
        "input_bits": bits.tolist(),
        "cases": cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2), encoding="utf8")
    print(f"PASS pinned original RAW CIE D + Kang2002 + CAT02 Python "
          f"oracle: {len(cases)} temperatures, 18 channels each; not LibRaw")


if __name__ == "__main__":
    main()
