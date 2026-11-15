#!/usr/bin/env python3
"""Unmodified original 2D print diffusion FFT in all four filter families.

Execute source model/diffusion.py functions/constant definitions from AST:
source FFT, np.pad(reflect), PSF and family multipliers are NOT rewritten.
Test 1x1, 1xN, 2xN and standard small RGB images, including original
all-zero intensity fallback and spatial_scale<1e-6 radial floor.
"""
import ast
import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import numpy as np
import scipy
from scipy.signal import fftconvolve

ROOT=Path(__file__).resolve().parents[2]
PATH=ROOT/"src/spektrafilm/model/diffusion.py"
PIN="cb22136f9d6a65e32ab54fc6f46f64f308e1a4f7"

FUNCTIONS={
    "_strength_to_scatter","_expand_group","_halo_channel_weights",
    "_resolve_family_cfg","_bloom_max_lambda_um",
    "_overrides_from_params","_radial_components",
    "diffusion_filter_psf","apply_diffusion_filter_um"
}
CONSTANTS={
    "_DIFFUSION_FILTER_SHAPES","_DIFFUSION_FAMILY_TOTAL_GAIN",
    "_DIFFUSION_STRENGTH_BREAKPOINTS",
    "_DIFFUSION_STRENGTH_TOTAL_FRACTION",
    "_HALO_CHANNEL_WARMTH_AXIS","_OVERRIDE_KEYS"
}

def original():
    content=PATH.read_bytes()
    blob=hashlib.sha1(
        b"blob "+str(len(content)).encode()+b"\0"+content
    ).hexdigest()
    assert blob==PIN,("Upstream 2D source changed",blob)
    parsed=ast.parse(content)
    nodes=[]
    for node in parsed.body:
        if isinstance(node,ast.FunctionDef) and node.name in FUNCTIONS:
            node.decorator_list=[]
            nodes.append(node)
        elif isinstance(node,(ast.Assign,ast.AnnAssign)):
            targets=node.targets if isinstance(node,ast.Assign) else [node.target]
            if any(isinstance(t,ast.Name) and t.id in CONSTANTS for t in targets):
                nodes.append(node)
    assert len(nodes)==len(FUNCTIONS)+len(CONSTANTS),(
        len(nodes),len(FUNCTIONS),len(CONSTANTS))
    scope={"np":np,"scipy":scipy,"fftconvolve":fftconvolve}
    exec(compile(ast.fix_missing_locations(ast.Module(
        body=nodes,type_ignores=[])),str(PATH),"exec"),scope)
    return scope

def main(destination):
    lib=original()
    families=("glimmerglass","black_pro_mist","pro_mist","cinebloom")
    sizes=((1,1),(1,7),(7,1),(2,2),(2,6),(6,2),
           (3,7),(6,5),(9,9))
    patterns=[
      dict(strength=0.5,spatial_scale=1.0,halo_warmth=0.0,
           core_intensity=1.0,halo_intensity=1.0,bloom_intensity=1.0,
           core_size=1.0,halo_size=1.0,bloom_size=1.0),
      dict(strength=1.3,spatial_scale=0.7,halo_warmth=-0.5,
           core_intensity=0.6,halo_intensity=1.35,bloom_intensity=1.6,
           core_size=1.25,halo_size=0.85,bloom_size=1.7),
      dict(strength=0.75,spatial_scale=1e-7,halo_warmth=2.0,
           core_intensity=0.0,halo_intensity=0.0,bloom_intensity=0.0,
           core_size=1.33,halo_size=0.63,bloom_size=1.87),
    ]
    cases=[]
    for family in families:
        for width,height in sizes:
            p=np.arange(width*height*3,dtype=np.float64)
            image=(
                (np.sin(p*0.31)+1.27)*0.22+
                (p%13.0)*0.037
            ).reshape(height,width,3)
            image[0,0,:]=[1.65,0.81,0.33]
            for mode,setting in enumerate(patterns):
                obj=SimpleNamespace(active=True,filter_family=family,**setting)
                overrides=lib["_overrides_from_params"](obj)
                lambda_max=lib["_bloom_max_lambda_um"](family,overrides)
                pixel_um=220.0
                max_lambda=lambda_max*setting["spatial_scale"]/pixel_um
                radius=int(np.ceil(max(8.0*max_lambda,5.0)))
                radius=min(radius,max(min(height,width)//2-1,1))
                shape=(radius*2+1,radius*2+1)
                psf=lib["diffusion_filter_psf"](
                    shape,family=family,
                    spatial_scale=setting["spatial_scale"],
                    pixel_size_um=pixel_um,
                    halo_warmth=setting["halo_warmth"],
                    overrides=overrides
                )
                result=lib["apply_diffusion_filter_um"](
                    image.copy(),obj,pixel_size_um=pixel_um
                )
                f=lib["_strength_to_scatter"](
                    setting["strength"],family
                )
                assert psf.shape==(shape[0],shape[1],3)
                assert np.isfinite(psf).all()
                assert np.isfinite(result).all()
                for ch in range(3):
                    assert abs(psf[:,:,ch].sum()-1.0)<1e-12
                cases.append(dict(
                    family=family,mode=mode,width=width,height=height,
                    pixelUM=pixel_um,settings=setting,
                    input=image.reshape(-1).tolist(),
                    radius=radius,sourceFraction=float(f),
                    sourcePSF=psf.reshape(-1).tolist(),
                    output=result.reshape(-1).tolist()
                ))
    assert len(cases)==4*9*3==108
    Path(destination).write_text(json.dumps(
        dict(sourceBlob=PIN,cases=cases),
        separators=(",",":"),allow_nan=False),encoding="utf8")
    print("ORIGINAL PYTHON FFT PRINT DIFFUSION PASS: ",
          len(cases),"actual source 2D reflect FFT frames,",
          "4 families, narrow axes, custom PSF overrides,",
          "intensities-zero fallback and spatial_scale=1e-7.")

if __name__=="__main__":
    main(sys.argv[1])
