#!/usr/bin/env python3
"""Source ORIGINAL scanner deterministic LINEAR RGB lens/Unsharp truth.

Imports the exact upstream fast_gaussian_filter() used by
model.diffusion.apply_gaussian_blur and apply_unsharp_mask, not a SciPy
approximation. Generates actual Float64 whole-image reference stages.
Stochastic glare and print particle RNG are intentionally out of scope.
"""
from __future__ import annotations
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/"ios/verification/generated-scanner-optics-v1.8.26"
CASES=(
    ("identity",9,7,0.0,0.0,0.0),
    ("FIR_FIR",17,11,1.25,2.2,0.8),
    ("IIR_FIR",13,17,4.0,1.0,1.2),
    ("FIR_IIR",7,5,2.5,5.0,0.45),
    ("IIR_IIR",23,19,7.5,3.0,0.8),
    ("single_column",1,13,5.0,2.1,0.4),
    ("two_pixels",2,1,0.1,0.35,0.5),
    ("boundary_3",31,9,3.0,2.999,1.1),
)

def save(base,name,values):
    data=np.asarray(values,dtype="<f8")
    assert np.isfinite(data).all(),name
    bits=np.ascontiguousarray(data).tobytes()
    (base/name).write_bytes(bits)
    return hashlib.sha256(bits).hexdigest()

def main():
    spec=importlib.util.spec_from_file_location(
        "spektrafilm_original_scanner_gaussian",
        ROOT/"src/spektrafilm/utils/fast_gaussian_filter.py"
    )
    mod=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=mod
    spec.loader.exec_module(mod)
    blur=mod.fast_gaussian_filter
    OUT.mkdir(parents=True,exist_ok=True)
    manifest={
        "scope":"original-source-scanning-linear-RGB-lens-FIR-YVV-unsharp",
        "source":"src/spektrafilm/model/diffusion.py",
        "kernel":"src/spektrafilm/utils/fast_gaussian_filter.py",
        "cases":[],
    }
    for name,w,h,lens,sigma,amount in CASES:
        v=np.arange(w*h*3,dtype=np.float64).reshape(h,w,3)
        input_image=(
            0.35+0.31*np.sin(v*0.213)-0.29*np.cos(v*0.027)
        ).astype(np.float64)
        out=input_image.copy()
        vectors={"input":input_image}
        if lens>0:
            out=blur(out,lens)
            vectors["scannerLensBlur"]=out
        if sigma>0 and amount>0:
            blurred=blur(out,sigma)
            vectors["scannerUnsharpBlur"]=blurred
            out=out+amount*(out-blurred)
        vectors["scannerLinear"]=out
        files={k:save(OUT,name+"."+k+".f64le",m)
               for k,m in vectors.items()}
        manifest["cases"].append({
            "name":name,"width":w,"height":h,
            "lens":lens,"sigma":sigma,"amount":amount,
            "sha256":files,
        })
        print(
            f"PASS original source scanner linear FIR/YVV/Unsharp {name} "
            f"{w}x{h} lens={lens} unsharp={sigma}/{amount}",
            flush=True
        )
    (OUT/"manifest.json").write_text(
        json.dumps(manifest,sort_keys=True,indent=2)+"\n",
        encoding="utf-8"
    )
    print("PASS: original 8 whole-image source scanner deterministic cases.")

if __name__=="__main__":
    main()
