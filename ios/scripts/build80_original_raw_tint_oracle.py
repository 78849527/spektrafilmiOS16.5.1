#!/usr/bin/env python3
"""Run the pinned original Python RAW tint function, not a reimplementation.

The exact function AST comes from src/spektrafilm/utils/raw_file_processor.py.
This source-only oracle is used for Swift Float32 bit-pattern comparison.
It is not full rawpy decoding, whitepoint adaptation or RAW image parity.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/utils/raw_file_processor.py"
SOURCE_BLOB_SHA = "97e34feb80fe47a6a3b36fcb93bef626d397135a"


def original_source_function():
    blob = subprocess.check_output(
        ["git", "hash-object", str(SOURCE)], cwd=ROOT, text=True
    ).strip()
    if blob != SOURCE_BLOB_SHA:
        raise RuntimeError(
            f"PINNED upstream RAW source changed: {blob} != {SOURCE_BLOB_SHA}"
        )
    module = ast.parse(SOURCE.read_text("utf-8"), filename=str(SOURCE))
    f = next(
        (node for node in module.body
         if isinstance(node, ast.FunctionDef)
         and node.name == "_apply_tint_adjustment"), None
    )
    if f is None:
        raise RuntimeError("Original _apply_tint_adjustment missing")
    isolated = ast.fix_missing_locations(ast.Module(body=[f], type_ignores=[]))
    namespace = {"np": np}
    exec(compile(isolated, str(SOURCE), "exec"), namespace)
    return namespace["_apply_tint_adjustment"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fn = original_source_function()
    bits = np.array([
        0x3E99999A, 0x3E4CCCCD, 0x3FC00000,
        0x00000001, 0x80000000, 0x3F800000,
        0xBFC00000, 0x3F000000, 0x41200000,
        0x3F800000, 0xBF000000, 0x3EAAAAAB,
        0x3F4CCCCD, 0x00000000, 0x3F666666,
        0x40800000, 0x3DCCCCCD, 0x80000001,
    ], dtype=np.uint32)
    image = bits.view(np.float32).reshape(2, 3, 3)
    cases = []
    for tint in (None, 1.0, 1.000005, 1.2, 0.75, -1.0):
        actual = fn(image.copy(), tint)
        if actual.dtype != np.dtype("float32"):
            raise RuntimeError("Original RAW tint changed expected Float32")
        cases.append({
            "tint": tint,
            "expected_bits": actual.reshape(-1).view(np.uint32).tolist(),
        })
    result = {
        "source_git_blob_sha": SOURCE_BLOB_SHA,
        "input_bits": bits.tolist(),
        "cases": cases,
        "scope": "original Python _apply_tint_adjustment only; not rawpy parity",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"PASS original Python RAW tint oracle: {len(cases)} cases; "
          f"{len(bits)} Float32 samples each, pinned blob {SOURCE_BLOB_SHA}")


if __name__ == "__main__":
    main()
