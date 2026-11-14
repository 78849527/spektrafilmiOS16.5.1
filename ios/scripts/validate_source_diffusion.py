#!/usr/bin/env python3
"""Original unmodified Python diffusion.py vs actual Swift Double FFT source.

Pinned upstream source's exact AST is executed in isolation because package
__init__ imports optional exiv2/RAW bindings. This is not a rewrite of the
reference algorithm. Stage-scoped cases cover all 4 filter families,
per-channel coloured halo, individual overrides and reflect boundaries.
"""
from __future__ import annotations
import ast
import hashlib
import subprocess
import tempfile
from pathlib import Path
from types import SimpleNamespace

import numpy as np
from scipy.signal import fftconvolve

ROOT=Path(__file__).resolve().parents[2]
P=ROOT/"src/spektrafilm/model/diffusion.py"
PINNED_BLOB="cb22136f9d6a65e32ab54fc6f46f64f308e1a4f7"
ASSIGNMENTS={
    "_DIFFUSION_FILTER_SHAPES",
    "_DIFFUSION_FAMILY_TOTAL_GAIN",
    "_DIFFUSION_STRENGTH_BREAKPOINTS",
    "_DIFFUSION_STRENGTH_TOTAL_FRACTION",
    "_HALO_CHANNEL_WARMTH_AXIS",
    "_OVERRIDE_KEYS",
}
FUNCTIONS={
    "_strength_to_scatter","_expand_group","_halo_channel_weights",
    "_resolve_family_cfg","_bloom_max_lambda_um",
    "_overrides_from_params","_radial_components",
    "diffusion_filter_psf","apply_diffusion_filter_um",
}

def load_original():
    raw=P.read_bytes()
    sha=hashlib.sha1(
        b"blob "+str(len(raw)).encode("ascii")+b"\x00"+raw
    ).hexdigest()
    assert sha==PINNED_BLOB,(
        "Original upstream diffusion.py changed. Review source diff before"
        " updating pinned reference. Never auto-rebaseline.",sha,PINNED_BLOB
    )
    module=ast.parse(raw,filename=str(P))
    nodes=[]
    for node in module.body:
        if isinstance(node,ast.FunctionDef) and node.name in FUNCTIONS:
            nodes.append(node)
        elif isinstance(node,ast.Assign):
            if any(isinstance(x,ast.Name) and x.id in ASSIGNMENTS
                   for x in node.targets):
                nodes.append(node)
        elif isinstance(node,ast.AnnAssign):
            if isinstance(node.target,ast.Name) and (
                node.target.id in ASSIGNMENTS
            ):
                nodes.append(node)
    names={
        n.name if isinstance(n,ast.FunctionDef) else (
            n.target.id if isinstance(n,ast.AnnAssign) else
            n.targets[0].id
        ) for n in nodes
    }
    assert names==FUNCTIONS|ASSIGNMENTS, names ^ (FUNCTIONS|ASSIGNMENTS)
    ns={"np":np,"fftconvolve":fftconvolve}
    exec(compile(ast.Module(body=nodes,type_ignores=[]),str(P),"exec"),ns)
    return ns

def source_cases():
    dims=[(11,9),(16,13),(29,21),(24,19)]
    attrs=[
        ("glimmerglass",0.125,1,0,(1,1,1),(1,1,1)),
        ("black_pro_mist",0.5,1.15,0.3,(1.15,0.8,1.3),(1.2,0.9,1.05)),
        ("pro_mist",1,0.85,-0.4,(1,1,1),(1,1,1)),
        ("cinebloom",2,1,0,(1,1,1),(1,1,1)),
    ]
    for k,((w,h),args) in enumerate(zip(dims,attrs)):
        fam,strength,scale,warmth,intensity,size=args
        obj=SimpleNamespace(
            active=True,filter_family=fam,strength=strength,
            spatial_scale=scale,halo_warmth=warmth,
            core_intensity=intensity[0],core_size=size[0],
            halo_intensity=intensity[1],halo_size=size[1],
            bloom_intensity=intensity[2],bloom_size=size[2],
        )
        v=np.arange(w*h*3,dtype=np.int64)
        rgb=(((v*37+11)%251)/251.0+0.001*((v//7)%3)).reshape(
            h,w,3
        ).astype(np.float64)
        yield k,w,h,obj,rgb

def main():
    source=load_original()
    with tempfile.TemporaryDirectory() as td:
        exe=Path(td)/"native-source-diffusion"
        compile_result=subprocess.run([
            "xcrun","swiftc","-O",
            str(ROOT/"ios/SpektraFilmPort/OriginalSourceDiffusion.swift"),
            str(ROOT/"ios/tests/SourceDiffusionNumericValidation.swift"),
            "-o",str(exe),
        ],check=False,capture_output=True,text=True)
        if compile_result.returncode:
            print("Source diffusion native compiler diagnostic:")
            print(compile_result.stdout)
            print(compile_result.stderr)
            raise RuntimeError(
                "Native swiftc compilation failed; original optical "
                "numerical gate remains mandatory"
            )
        proc=subprocess.run([str(exe)],check=True,
                            capture_output=True,text=True)
    parsed={}
    for line in proc.stdout.splitlines():
        row=line.strip().split(",")
        case=int(row[1])
        entry=parsed.setdefault(case,{"results":[]})
        if row[0]=="METADATA":
            entry["w"]=int(row[2])
            entry["h"]=int(row[3])
            entry["radius"]=int(row[4])
        elif row[0]=="RESULT":
            assert len(entry["results"])==int(row[2])
            entry["results"].append(float(row[3]))
        else:
            raise AssertionError("Unexpected Swift output "+line)
    assert set(parsed)==set(range(4))
    maximum=0.0
    for k,w,h,settings,rgb in source_cases():
        got=parsed[k]
        assert (got["w"],got["h"])==(w,h)
        # The source PSF radius is independently calculated by the original
        # filter's shape and its per-image cap, not using Swift's value.
        kernel=source["_DIFFUSION_FILTER_SHAPES"][settings.filter_family]
        overrides=source["_overrides_from_params"](settings)
        lam=source["_bloom_max_lambda_um"](
            settings.filter_family,overrides
        )
        radius=int(np.ceil(max(
            8*lam*settings.spatial_scale/100,5.0
        )))
        radius=min(radius,max(min(h,w)//2-1,1))
        assert got["radius"]==radius,(k,got["radius"],radius)
        expected=source["apply_diffusion_filter_um"](
            rgb,settings,pixel_size_um=100
        ).reshape(-1)
        observed=np.asarray(got["results"],dtype=np.float64)
        assert observed.shape==expected.shape,(k,len(observed),len(expected))
        error=np.max(np.abs(observed-expected))
        assert np.isfinite(observed).all() and error<1e-12,(k,error)
        maximum=max(maximum,float(error))
        print(f"PASS: {settings.filter_family}: {w}x{h}, r={radius}, "
              f"max absolute Double FFT error {error:.3g}")
    print("PASS: four full source Python PSF+reflect+FFT source stages "
          f"on native Swift, max error {maximum:.3g}<1e-12")
if __name__=="__main__":
    main()
