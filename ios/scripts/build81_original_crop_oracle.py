#!/usr/bin/env python3
"""Build81: run exactly the pinned original Python crop_image AST.

Source: src/spektrafilm/utils/crop_resize.py. No rewritten geometry oracle.
Creates deterministic Float64 RGB test arrays; no camera RAW/ICC assumptions.
"""
from __future__ import annotations

import argparse
import ast
import json
import subprocess
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/utils/crop_resize.py"
BLOB_SHA = "4737b922c34f5cf77f66f8bb022b0625e4e37dd1"


def original():
    blob = subprocess.check_output(
        ["git", "hash-object", str(SOURCE)], cwd=ROOT, text=True
    ).strip()
    if blob != BLOB_SHA:
        raise RuntimeError(f"Source crop changed: {blob} != {BLOB_SHA}")
    module = ast.parse(SOURCE.read_text("utf8"), filename=str(SOURCE))
    func = next(
        (node for node in module.body
         if isinstance(node, ast.FunctionDef) and node.name == "crop_image"), None
    )
    if func is None:
        raise RuntimeError("Pinned original crop_image absent")
    isolated = ast.fix_missing_locations(
        ast.Module(body=[func], type_ignores=[])
    )
    namespace = {"np": np}
    exec(compile(isolated, str(SOURCE), "exec"), namespace)
    return namespace["crop_image"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fn = original()
    cases = [
        ("default", 5, 7, (.5,.5), (.1,.1)),
        ("top-left", 6, 4, (0.,0.), (.5,.5)),
        ("bottom-right", 4, 6, (1.,1.), (.5,.5)),
        ("ties-to-even", 7, 7, (.5,.5), (.5,.5)),
        ("odd-even", 9, 4, (.75,.18), (.3,.55)),
        ("long-side", 8, 13, (.5,.5), (.23,.5)),
        ("non-square", 11, 9, (.31,.83), (.4,.4)),
        ("quarter", 12, 12, (.5,.5), (.25,.25)),
        ("near-border", 15, 10, (.97,.08), (.2,.2)),
        ("oversize-x", 5, 3, (.5,.5), (.8,.4)),
        ("small-long-axis", 3, 15, (.9,.2), (.14,.14)),
        ("asymmetric", 17, 11, (.15,.85), (.23,.29)),
        ("empty-source-slice", 1, 2, (.5,.5), (.1,.1)),
    ]
    results = []
    for name,h,w,center,size in cases:
        rgb = (np.arange(h*w*3, dtype=np.float64)+1.0).reshape(h,w,3)/8.0
        result = fn(rgb, center=center, size=size)
        assert result.dtype == rgb.dtype
        results.append({
            "name": name,
            "width": w,
            "height": h,
            "center": center,
            "size": size,
            "expected_width": int(result.shape[1]),
            "expected_height": int(result.shape[0]),
            "expected_rgb": result.reshape(-1).tolist(),
        })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({
        "source_git_blob_sha": BLOB_SHA,
        "source_function": "spektrafilm.utils.crop_resize.crop_image",
        "cases": results,
        "scope": "source crop geometry/Float64 bit-preservation only",
    }, indent=2), encoding="utf8")
    print(f"PASS original Python crop oracle: {len(results)} source cases, "
          f"including ties-to-even, edges, oversize and empty; NOT resize/RAW")


if __name__ == "__main__":
    main()
