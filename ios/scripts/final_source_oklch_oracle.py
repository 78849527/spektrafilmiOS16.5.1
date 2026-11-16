#!/usr/bin/env python3
"""Independent pinned original Python Oklch INPUT spectral-locus oracle.

Original gamut_compression.py: xyY Y=1 -> Oklab L/C/h -> 64x720x18
Matplotlib spectral-locus Cmax -> bilinear -> Reinhard knee -> xy.
No Swift results are used to generate expected values.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import sys
import warnings
from pathlib import Path

import colour
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/"src/spektrafilm/utils/gamut_compression.py"
BLOB="9783e7fcfc2909c4acdf2da53595c5404645dde9"

def source_blob(path:Path)->str:
    raw=path.read_bytes()
    return hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--output",required=True,type=Path)
    args=p.parse_args()
    assert source_blob(SOURCE)==BLOB,"original source drift"
    assert colour.__version__=="0.4.6",colour.__version__
    spec=importlib.util.spec_from_file_location("source_input_oklch_exact",SOURCE)
    module=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=module
    spec.loader.exec_module(module)

    # Direct Python-original default and non-default branches.
    assert module.InputGamutCompressSpec().algorithm=="xy"
    assert module._OKLCH_CMAX_TABLE_N_L==64
    assert module._OKLCH_CMAX_TABLE_N_H==720
    assert module._OKLCH_CMAX_TABLE_N_BISECT==18

    points=np.asarray([
        [0.3127,0.3290],[0.30,0.30],[0.55,0.32],[0.64,0.33],
        [0.15,0.06],[0.18,0.44],[0.22,0.68],[0.67,0.22],
        [0.03,0.55],[0.62,0.10],[0.11,0.82],[0.34,0.42],
        [0.10,0.20],[0.41,0.55],[0.49,0.28],[0.28,0.24],
    ],dtype=np.float64)
    loci=[
        ("source_cie1931",module.spectral_locus_xy()),
        ("explicit_closed_square",np.asarray([
            [0.0,0.0],[0.7,0.0],[0.7,0.7],[0.0,0.7],[0.0,0.0],
        ],dtype=np.float64))
    ]
    cases=[]
    for name,locus in loci:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore",RuntimeWarning)
            grid=module._get_oklch_c_max_table(locus)
        assert len(grid)==3 and grid[2].shape==(64,720)
        assert np.isfinite(grid[2]).all()
        # Two knee profiles for default CIE; one for custom closed locus.
        knees=[(0.0,1.0,6.0),(0.25,1.0,2.5)]
        for knee in knees if name=="source_cie1931" else knees[:1]:
            opts=module.InputGamutCompressSpec(
                active=True,algorithm="oklch",knee=knee
            )
            with warnings.catch_warnings():
                warnings.simplefilter("ignore",RuntimeWarning)
                actual=module.compress_xy(
                    points,np.asarray([0.3127,0.3290]),opts,locus=locus
                )
            assert actual.shape==points.shape
            assert np.isfinite(actual).all()
            identity=module.compress_xy(
                points,np.asarray([0.3127,0.3290]),
                module.InputGamutCompressSpec(
                    active=False,algorithm="oklch",knee=knee
                ),locus=locus
            )
            assert np.array_equal(points,identity)
            cases.append({
                "name":name,
                "knee":list(knee),
                "locus":locus.tolist(),
                "input":points.tolist(),
                "expected":actual.tolist(),
                "inactive":identity.tolist(),
            })
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps({
        "sourceBlob":BLOB,
        "colourVersion":colour.__version__,
        "grid":[64,720,18],
        "caseCount":len(cases),
        "cases":cases,
        "fullPythonOriginalCertified":False,
    },allow_nan=False,separators=(",",":")),encoding="utf8")
    print("PASS ORIGINAL INPUT Oklch Python oracle",
          len(cases),"knee/locus scenarios",len(points),"pixels each",
          "64x720x18 ORIGINAL source; no Swift-generated references")

if __name__=="__main__":
    main()
