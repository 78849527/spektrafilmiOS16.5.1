#!/usr/bin/env python3
"""Build83 pinned Python ORIGINAL camera RAW boost/log and photographic diffusion.

This runs actual upstream Python boost_highlights and diffusion_filter_psf /
apply_diffusion_filter_um. Test vectors cross camera EV, post-optics reference
scaling, zero/negative photon log10, 4 source optical diffusion families,
reflect padded FFT and boundary PSFs. Outputs source numerical fixtures.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import subprocess
import sys
import types
from pathlib import Path
from types import SimpleNamespace

import numpy as np

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"src"))
# Import the *real pinned module files* without executing the top-level
# spektrafilm/__init__.py, which eagerly imports unrelated exiv2/LibRaw.
# This retains the actual upstream diffusion and Numba boost algorithms.
for pkg,path in [
    ("spektrafilm","src/spektrafilm"),
    ("spektrafilm.utils","src/spektrafilm/utils"),
    ("spektrafilm.model","src/spektrafilm/model"),
]:
    wrapper=types.ModuleType(pkg)
    wrapper.__path__=[str(ROOT/path)]
    sys.modules[pkg]=wrapper
BLOBS={
    "src/spektrafilm/runtime/stages/filming.py":"b58759160dfa9dd45b5528b09b24ffafb5493b66",
    "src/spektrafilm/utils/numba_boost_hightlights.py":"61cb5ca89163762335674279a9743801e13e0e8f",
    "src/spektrafilm/model/diffusion.py":"cb22136f9d6a65e32ab54fc6f46f64f308e1a4f7",
}
for rel,sha in BLOBS.items():
    got=subprocess.check_output(["git","hash-object",rel],
                                cwd=ROOT,text=True).strip()
    if got!=sha:
        raise RuntimeError(f"Source blob drift: {rel}: {got}")
from spektrafilm.utils.numba_boost_hightlights import boost_highlights
from spektrafilm.model.diffusion import (
    diffusion_filter_psf,apply_diffusion_filter_um,
    _strength_to_scatter,_bloom_max_lambda_um
)


def raw_input(shape,kind):
    t=np.arange(np.prod(shape),dtype=np.float64).reshape(shape)
    if kind=="zeros":return t*0
    if kind=="negative":return -0.002*t-0.0001
    if kind=="range":
        return np.sin(t*0.71)*0.09 + t*0.031
    return np.exp(np.clip(np.sin(t*0.41)*3.0,-8,8))*0.184


def exposure_cases():
    specs=[
        ("range",0.0,0.0,0.3,4.0,1.0),
        ("range",1.8,1.5,0.3,0.0,0.8),
        ("range",-2.0,0.6,0.75,0.0,2.4),
        ("zeros",4.0,3.0,0.1,4.0,1.0),
        ("negative",0.0,0.0,0.3,4.0,1.0),
        ("hdr",-1.0,2.1,0.5,0.0,1.125)
    ]
    cases=[]
    for kind,ev,boost,brange,protect,correction in specs:
        frame=raw_input((3,5,3),kind)
        exposed=frame*(2.0**ev)
        result=boost_highlights(exposed,boost_ev=boost,
                                boost_range=brange,protect_ev=protect)
        corrected=result*correction
        # Exact pinned FilmingStage.expose terminal photon equation.
        log=np.log10(np.fmax(corrected,0.0)+1e-10)
        if not np.all(np.isfinite(log)):
            raise RuntimeError(f"Nonfinite original camera log: {kind}")
        cases.append({
            "kind":kind,"ev":ev,"boost_ev":boost,
            "boost_range":brange,"protect_ev":protect,
            "reference_scale":correction,
            "input":frame.reshape(-1).tolist(),
            "exposed":exposed.reshape(-1).tolist(),
            "boosted":result.reshape(-1).tolist(),
            "log":log.reshape(-1).tolist(),
        })
    return cases


def diffusion_cases():
    h,w=17,19
    t=np.arange(h*w*3,dtype=np.float64).reshape(h,w,3)
    source=(np.sin(t*0.027)+1.25)*0.071+t*0.000009
    result=[]
    for family in ["glimmerglass","black_pro_mist","pro_mist","cinebloom"]:
        pixel_um=1500.0
        strength=0.5
        spatial=1.0
        warmth=0.15
        params=SimpleNamespace(active=True,filter_family=family,
            spatial_scale=spatial,halo_warmth=warmth,
            strength=strength,
            core_intensity=1.0,halo_intensity=1.0,bloom_intensity=1.0,
            core_size=1.0,halo_size=1.0,bloom_size=1.0)
        r=int(np.ceil(max(
            8.0*_bloom_max_lambda_um(family,None)*spatial/pixel_um,5.0
        )))
        r=min(r,max(min(h,w)//2-1,1))
        psf=diffusion_filter_psf((2*r+1,2*r+1),family=family,
            spatial_scale=spatial,pixel_size_um=pixel_um,
            halo_warmth=warmth)
        image=apply_diffusion_filter_um(
            source,params,pixel_size_um=pixel_um
        )
        if psf.shape!=(2*r+1,2*r+1,3):
            raise RuntimeError("Original source PSF radius invalid")
        if not np.all(np.isfinite(image)):
            raise RuntimeError("Original source photographic diffraction failed")
        result.append({
            "family":family,"width":w,"height":h,
            "pixel_um":pixel_um,"strength":strength,
            "spatial_scale":spatial,"halo_warmth":warmth,
            "radius":r,"scatter_fraction":float(
                _strength_to_scatter(strength,family)),
            "source_rgb":source.reshape(-1).tolist(),
            "psf":psf.reshape(-1).tolist(),
            "output_rgb":image.reshape(-1).tolist()
        })
    return result


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--output",required=True,type=Path)
    args=p.parse_args()
    out={"source_blobs":BLOBS,"numpy_version":np.__version__,
         "exposure":exposure_cases(),
         "diffusion":diffusion_cases(),
         "source_sha":"3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(out,separators=(",",":")),
                           encoding="utf8")
    print(f"PASS Build83 original Python: {len(out['exposure'])} RAW photon "
          f"boost/log/EV vectors and {len(out['diffusion'])} "
          "four-family original full-image reflect FFT optical PSFs")


if __name__=="__main__":
    main()
