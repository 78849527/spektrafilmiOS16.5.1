#!/usr/bin/env python3
"""Build81 original-Python AST source oracle, NOT invented image reference.

Exactly executes crop_image, resize_for_preview, reinhard_knee,
_ray_polygon_distance, compress_xy_radial, and compress_xy from source.
Uses an explicit closed xy locus for deterministic ray-polygon tests.
Default CIE gamut polygon and Oklch branch remain unverified separately.
"""
from __future__ import annotations

import argparse
import ast
import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import skimage
from skimage.transform import resize

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/utils"
PIN = {
    "crop_resize.py": "4737b922c34f5cf77f66f8bb022b0625e4e37dd1",
    "preview.py": "985c4099c775c6b3fc6fe660a0b467175d62f91f",
    "gamut_compression.py": "9783e7fcfc2909c4acdf2da53595c5404645dde9",
}


def extract(filename: str, names: set[str]) -> dict:
    path = SOURCE / filename
    sha = subprocess.check_output(
        ["git", "hash-object", str(path)], cwd=ROOT, text=True
    ).strip()
    if sha != PIN[filename]:
        raise RuntimeError(f"Original source drift in {filename}: {sha}")
    parsed = ast.parse(path.read_text(encoding="utf8"), filename=str(path))
    selected = [node for node in parsed.body
                if isinstance(node, ast.FunctionDef) and node.name in names]
    if len(selected) != len(names):
        raise RuntimeError(f"Original source functions missing in {filename}")
    ns = {"np": np, "resize": resize, "__name__": "__main__"}
    compiled = ast.fix_missing_locations(ast.Module(body=selected, type_ignores=[]))
    exec(compile(compiled, str(path), "exec"), ns)
    return ns


def exact_input(w: int, h: int) -> np.ndarray:
    n = np.arange(h*w*3, dtype=np.float64).reshape(h,w,3)
    # Deterministic noninteger, negative, subpixel-range test values.
    return np.sin(n*0.137) * 0.611 + n*0.00047 - 0.15


def flat_bits(x: np.ndarray) -> list[str]:
    z = np.ascontiguousarray(x, dtype=np.float64).reshape(-1)
    return [f"{int(v):016x}" for v in z.view(np.uint64)]


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--output",required=True,type=Path)
    args=parser.parse_args()
    if skimage.__version__ != "0.25.2":
        raise RuntimeError(
            f"Source preview oracle pins skimage 0.25.2, got {skimage.__version__}")
    crop=extract("crop_resize.py",{"crop_image"})["crop_image"]
    preview=extract("preview.py",{"resize_for_preview"})["resize_for_preview"]
    gamut=extract("gamut_compression.py",{
        "reinhard_knee","_ray_polygon_distance","compress_xy_radial","compress_xy"
    })

    crop_cases=[]
    # (w,h,cx,cy,sx,sy): source long-side fractional crop, banker half,
    # all four corners, portrait/landscape and oversized shorter dimension.
    for w,h,cx,cy,sx,sy in [
        (8,6,0.5,0.5,0.4,0.4),
        (8,6,0,0,0.3,0.4),
        (8,6,1,1,0.4,0.3),
        (7,11,0.5,0.5,0.5,0.5),
        (11,7,0.25,0.75,0.37,0.33),
        (6,8,0.85,0.15,0.25,0.8),
        (5,5,0.5,0.5,0.1,0.1),
        (6,3,0.3,0.5,0.9,0.9),
        (2,9,0.3,0.7,0.95,0.9),
        (9,1,0.5,0.5,0.1,0.9),
        (12,10,0.5,0.5,0.25,0.15),
    ]:
        src=exact_input(w,h)
        out=crop(src,center=(cx,cy),size=(sx,sy))
        crop_cases.append({
            "width":w,"height":h,"center":[cx,cy],"size":[sx,sy],
            "output_size":[int(out.shape[1]),int(out.shape[0])],
            "input_bits":flat_bits(src),
            "expected_bits":flat_bits(out),
        })

    preview_cases=[]
    for w,h,max_size in [
        (11,9,5),(7,12,4),(16,6,6),(8,5,10),
        (5,5,3),(17,11,8),(4,16,6),(12,7,11),
    ]:
        src=exact_input(w,h)
        out=preview(src,max_size)
        preview_cases.append({
            "width":w,"height":h,"max_size":max_size,
            "output_size":[int(out.shape[1]),int(out.shape[0])],
            "input_bits":flat_bits(src),
            "expected":np.ascontiguousarray(out).reshape(-1).tolist(),
            "zero_copy":bool(max(w,h) <= max_size),
        })

    square=[[0.0,0.0],[0.7,0.0],[0.7,0.7],[0.0,0.7],[0.0,0.0]]
    xy=np.array([
        [0.3,0.3],[0.6,0.4],[0.25,0.2],[0.72,0.1],
        [0.25,0.25],[0.3000000001,0.3],[0.1,0.63],
        [0.6,0.65],[0.42,0.4]
    ],dtype=np.float64)
    white=np.array([0.3,0.3],dtype=np.float64)
    gamut_cases=[]
    for knee in [(0.0,1.0,6.0),(0.25,1.0,2.5),(0.0,1.5,6.0)]:
        spec=SimpleNamespace(active=True,algorithm="xy",knee=knee)
        result=gamut["compress_xy"](xy,white,spec,locus=np.array(square))
        if not np.all(np.isfinite(result)):
            raise RuntimeError("Nonfinite original gamut oracle fixture")
        distances=np.array([0.0,0.05,0.2,0.3,0.75,1.2,2.0,4.0])
        knee_output=gamut["reinhard_knee"](
            distances,threshold=knee[0],limit=knee[1],power=knee[2]
        )
        gamut_cases.append({
            "knee":list(knee),
            "input":xy.tolist(),
            "output":result.tolist(),
            "knee_input":distances.tolist(),
            "knee_expected":knee_output.tolist(),
        })
    inactive=gamut["compress_xy"](
        xy,white,SimpleNamespace(active=False,algorithm="xy",knee=(0.0,1.0,6.0)),
        locus=np.array(square)
    )
    if not np.array_equal(inactive,xy):
        raise RuntimeError("Source gamut inactive should not change coordinates")

    result={
        "pinned_blobs":PIN,
        "skimage_version":skimage.__version__,
        "scope":"Pinned original AST geometry + preview Float64 + xy gamut with explicit polygon",
        "crop":crop_cases,"preview":preview_cases,
        "gamut":{"white":white.tolist(),"locus":square,
                 "cases":gamut_cases,"inactive":inactive.tolist()},
    }
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,separators=(",",":")),
                           encoding="utf8")
    print(
        f"PASS Build81 Python source oracle: "
        f"{len(crop_cases)} crop, {len(preview_cases)} preview, "
        f"{len(gamut_cases)} gamut knee; Float64 source fixtures generated"
    )


if __name__=="__main__":
    main()
