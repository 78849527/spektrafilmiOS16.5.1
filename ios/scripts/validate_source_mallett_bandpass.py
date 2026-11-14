#!/usr/bin/env python3
"""Source Mallett 2019 / UV-IR filter per-stage numerical crosscheck.

Upstream pinned source is the only reference. Native Swift's *production*
filter transmittance is compiled and compared against scipy.special.erf,
while film-sensitive matrix multiplication is independently compared to
the original spektrafilm.utils.spectral_upsampling.rgb_to_raw_mallett2019.

This is NOT a certification of Hanatos-with-UV/IR (not ported), stochastic
grain, full-size image RGB, or end-to-end iPhone Float64 parity.
"""
from __future__ import annotations
import json
import os
import subprocess
import tempfile
from pathlib import Path
import numpy as np
import colour
from scipy.special import erf

ROOT = Path(__file__).resolve().parents[2]
SHAPE=colour.SpectralShape(380,780,5)
WL=np.arange(380,781,5,dtype=np.float64)

def run_native() -> None:
    with tempfile.TemporaryDirectory() as td:
        executable=Path(td)/"source-bandpass"
        subprocess.run([
            "xcrun","swiftc","-O",
            str(ROOT/"ios/SpektraFilmPort/OriginalSourceCameraBandpass.swift"),
            str(ROOT/"ios/tests/SourceCameraBandpassNumericValidation.swift"),
            "-o",str(executable),
        ],check=True,capture_output=True,text=True)
        result=subprocess.run([str(executable)],check=True,
                              capture_output=True,text=True)
    samples={}
    for line in result.stdout.splitlines():
        group, wavelength, transmission=line.split(",")
        samples[(int(group),int(wavelength))]=float(transmission)
    assert len(samples)==4*81, len(samples)
    settings=[
        ((0.0,410.0,8.0),(0.0,675.0,15.0)),
        ((1.0,410.0,8.0),(0.0,675.0,15.0)),
        ((0.0,410.0,8.0),(1.0,675.0,15.0)),
        ((0.75,420.0,12.0),(0.4,680.0,17.0)),
    ]
    for k,(uv,ir) in enumerate(settings):
        au,cu,wu=uv
        ai,ci,wi=ir
        ref=(1-au+au*(erf((WL-cu)/wu)*0.5+0.5))*(
             1-ai+ai*(erf((WL-ci)/(-wi))*0.5+0.5))
        observed=np.array([samples[(k,int(w))] for w in WL])
        error=np.max(np.abs(ref-observed))
        assert error < 5e-15,(k,error)
        if k==0:
            assert np.array_equal(observed,np.ones(81))
    print("PASS: source Swift UV/IR passband 4×81 samples <5e-15 vs scipy.special.erf")

def validate_source_mallett() -> None:
    from spektrafilm.model.illuminants import standard_illuminant
    from spektrafilm.model.color_filters import compute_band_pass_filter
    from spektrafilm.utils.spectral_upsampling import (
        MALLETT2019_BASIS,rgb_to_raw_mallett2019,
    )
    basis=np.asarray(MALLETT2019_BASIS[:],dtype=np.float64)
    assert basis.shape==(81,3)
    paths=sorted((ROOT/"src/spektrafilm/data/profiles").glob("*.json"))
    films=[]
    for p in paths:
        raw=json.loads(p.read_bytes())
        if raw["info"]["stage"]=="filming":
            films.append((p.name,raw["info"],raw["data"]))
    assert len(films)==20,len(films)
    assert {x[1]["reference_illuminant"] for x in films} == {"D55","T"}
    colors=np.array([
        [0.184,0.184,0.184],
        [0.65,0.10,0.04],
        [0.05,0.35,0.77],
    ],dtype=np.float64)
    amount=0
    for name,info,data in films:
        illum=standard_illuminant(info["reference_illuminant"])
        sens=np.nan_to_num(10.0**np.asarray(data["log_sensitivity"],
                                         dtype=np.float64))
        assert sens.shape==(81,3)
        variants=[((0,410,8),(0,675,15))]
        if info["reference_illuminant"]=="T":
            variants.append(((1,410,8),(0.4,675,15)))
        else:
            variants.append(((0.75,410,8),(1,675,15)))
        for uv,ir in variants:
            band=compute_band_pass_filter(filter_uv=list(uv),filter_ir=list(ir))
            norm=np.sum(sens*band[:,None]*illum[:,None],axis=0)/np.sum(
                sens*illum[:,None],axis=0)
            effective=sens*band[:,None]/norm
            matrix=np.einsum("lk,l,lm->mk",basis,illum,effective)
            mid=np.einsum("k,km->m",illum*0.184,effective)
            matrix/=mid[1]
            for color in colors:
                predicted=matrix@color
                source=rgb_to_raw_mallett2019(
                    color[None,None,:], effective,
                    color_space="sRGB",
                    apply_cctf_decoding=False,
                    reference_illuminant=info["reference_illuminant"],
                )[0,0]
                error=np.max(np.abs(predicted-source))
                assert error < 5e-11,(name,uv,ir,error)
                amount+=1
    print(f"PASS: {amount} original source Mallett 2019 RGB vectors across 20 stocks, D55/T, UV/IR; matrix stage <5e-11")
if __name__=="__main__":
    run_native()
    validate_source_mallett()
