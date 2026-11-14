#!/usr/bin/env python3
"""Unmodified upstream grain.py full-image 3x3 source reference.

Executes EXACT upstream grain.py::apply_grain_to_density_layers, upstream
fast_stats.py and fast_gaussian_filter.py; SciPy legacy whole-plane seeded
Poisson→Binomial, source per-layer dye clouds, Numba single-worker
microstructure (if enabled) and source final FIR/YVV.
We only wrap source add_micro_structure to OBSERVE before/after outputs;
its original implementation runs unmodified. None of this certifies
the default unseeded multi-worker Numba prange RNG.
"""
from __future__ import annotations
import hashlib
import importlib.util
import json
import os
import sys
import types
from pathlib import Path

import numpy as np
import numba
from numba import njit, prange

ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/"src/spektrafilm"
OUT=ROOT/"ios/verification/generated-source-grain-v1.8.48"
BLOBS={
    "model/grain.py":"f2d2b23e3eab4f4a1d919f69bcb4aceb714e024d",
    "utils/fast_stats.py":"9e80d29ce6b9f7820ae70f5c09da15edfaa70a0d",
    "utils/fast_gaussian_filter.py":"8918c673ea0fb3f5d9ae820ca85bf6db4aba457a",
}
CASES=(
    # name, width, height, pixel um, dye blur parameter, final blur,
    # micro blur um, micro std nm
    ("fir_micro_below_threshold",9,7,1.8,1.0,0.65,0.2,30.0),
    ("yvv_micro_active",12,10,0.35,3.2,3.2,0.2,30.0),
    ("no_cloud_no_final_blur",7,6,1.2,0.0,0.0,0.2,30.0),
)
MAXIMA=np.array([[0.55,0.65,0.75],
                 [0.75,0.85,0.95],
                 [1.05,1.15,1.25]],dtype=np.float64)

def gitblob(path:Path)->str:
    data=path.read_bytes()
    return hashlib.sha1(
        b"blob "+str(len(data)).encode("ascii")+b"\0"+data
    ).hexdigest()

def load(name:str,path:Path):
    spec=importlib.util.spec_from_file_location(name,path)
    assert spec and spec.loader
    module=importlib.util.module_from_spec(spec)
    sys.modules[name]=module
    spec.loader.exec_module(module)
    return module

@njit(parallel=True)
def seed_numba_one_worker(seed):
    for i in prange(1):
        np.random.seed(seed)

def save_array(name:str,part:str,x)->str:
    x=np.asarray(x,dtype="<f8")
    assert np.isfinite(x).all(),(name,part,"nonfinite original source result")
    content=np.ascontiguousarray(x).tobytes()
    (OUT/f"{name}.{part}.f64le").write_bytes(content)
    return hashlib.sha256(content).hexdigest()

def main():
    assert os.environ.get("NUMBA_NUM_THREADS")=="1", "requires controlled Numba single worker"
    assert os.environ.get("NUMBA_THREADING_LAYER")=="workqueue", "requires controlled source workqueue"
    for k,v in BLOBS.items():
        assert gitblob(SRC/k)==v, f"UPSTREAM CHANGED {k}: stop, re-audit original"

    numba.set_num_threads(1)
    assert numba.get_num_threads()==1
    for name in ("spektrafilm","spektrafilm.utils","spektrafilm.model","spektrafilm.runtime"):
        m=types.ModuleType(name)
        m.__path__=[str(SRC)]
        sys.modules[name]=m
    layer_helper=types.ModuleType("spektrafilm.model.density_curves")
    def unused_interp(*a,**kw):
        raise AssertionError("grain fixture already supplies the measured 3x3 sublayers")
    layer_helper.interp_density_cmy_layers=unused_interp
    sys.modules[layer_helper.__name__]=layer_helper
    params=types.ModuleType("spektrafilm.runtime.params_schema")
    params.GrainParams=type("GrainParams",(),{})
    sys.modules[params.__name__]=params

    load("spektrafilm.utils.fast_stats",SRC/"utils/fast_stats.py")
    load("spektrafilm.utils.fast_gaussian_filter",SRC/"utils/fast_gaussian_filter.py")
    grain=load("spektrafilm.model.grain",SRC/"model/grain.py")
    original_micro=grain.add_micro_structure

    # JIT warm-up before explicitly seeding the original Numba worker.
    seed_numba_one_worker(8888)
    grain.apply_grain_to_density_layers(
        np.full((2,2,3,3),0.2,dtype=np.float64),
        density_max_layers=MAXIMA.copy(),pixel_size_um=2.0,
        grain_blur=0.0,grain_blur_dye_clouds_um=0,
        grain_micro_structure=(0.0,0.0),
        particle_scale=(1.6,1.6,3.2),
        particle_scale_layers=(2.0,1.0,0.5),
        density_min=(0.03,0.03,0.03),
        grain_uniformity=(0.97,0.99,0.97),
        use_fast_stats=False,
    )

    OUT.mkdir(parents=True,exist_ok=True)
    manifest={"scope":"ACTUAL unmodified original grain.py: 9 SciPy layers + dye cloud Gaussian + single worker Numba micro + final blur",
              "source_sha":BLOBS,"numba_seed":8888,
              "cases":[]}
    for name,w,h,pixel_um,dye,final,micro_um,micro_nm in CASES:
        density=np.empty((h,w,3),dtype=np.float64)
        for y in range(h):
            for x in range(w):
                p=y*w+x
                for ch in range(3):
                    density[y,x,ch]=0.12+0.015*((p+ch*4)%9)
        frac=MAXIMA/MAXIMA.sum(axis=0)
        layers=density[:,:,None,:]*frac[None,None,:,:]
        # The Python function MUTATES the sublayer input; supply a copy.
        stages={}
        def captured(density_cmy_out,micro_structure,pixel_size_um):
            stages["dyeClouds"]=density_cmy_out.copy()
            result=original_micro(density_cmy_out,micro_structure,pixel_size_um)
            stages["microstructure"]=result.copy()
            return result
        grain.add_micro_structure=captured
        # Source Numba worker is separate from NumPy/SciPy global RandomState.
        seed_numba_one_worker(8888)
        result=grain.apply_grain_to_density_layers(
            layers.copy(),density_max_layers=MAXIMA.copy(),
            pixel_size_um=pixel_um,
            particle_area_um2=0.2,
            particle_scale=(1.6,1.6,3.2),
            particle_scale_layers=(2.0,1.0,0.5),
            density_min=(0.03,0.03,0.03),
            grain_uniformity=(0.97,0.99,0.97),
            grain_blur=final,
            grain_blur_dye_clouds_um=dye,
            grain_micro_structure=(micro_um,micro_nm),
            use_fast_stats=False,
        )
        grain.add_micro_structure=original_micro
        assert "dyeClouds" in stages and "microstructure" in stages
        stage_sha={
            "sublayers":save_array(name,"sublayers",layers),
            "dyeClouds":save_array(name,"dyeClouds",stages["dyeClouds"]),
            "microstructure":save_array(name,"microstructure",stages["microstructure"]),
            "final":save_array(name,"final",result),
        }
        enabled=micro_nm*0.001/pixel_um>0.05
        manifest["cases"].append({
            "name":name,"width":w,"height":h,"pixelUM":pixel_um,
            "dyeBlur":dye,"finalBlur":final,"microUM":micro_um,
            "microNM":micro_nm,"maxima":MAXIMA.ravel().tolist(),
            "microEnabled":enabled,"sha256":stage_sha,
        })
        print(f"UPSTREAM {name} {w}x{h} {w*h*3} CMY: "
              f"micro={enabled} dye+micro+final source SHA {stage_sha['final']}")
    (OUT/"manifest.json").write_text(
        json.dumps(manifest,indent=2,ensure_ascii=False)+"\n",encoding="utf-8"
    )
    print("PASS: three Python grain.py whole-image numeric source cases, pinned blobs, explicit 1-worker seed")
    print("NOT CERTIFIED: default unseeded Numba prange, RAW or complete RGB photo")

if __name__=="__main__":
    main()
