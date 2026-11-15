#!/usr/bin/env python3
"""Run actual source ColorReferenceService then add_glare, same scan XYZ order.

This is precisely the ScanningStage._density_to_rgb sequence AFTER spectral
XYZ: 10**log_xyz -> B/W correction -> add_glare -> XYZ to linear RGB.
It tests the first two true operations with independent seeded source Numba
worker. Does not claim default UNSEEDED multiworker parity.
"""
import json, os, sys, types
from pathlib import Path
import numpy as np
import numba
from build87_original_color_reference_oracle import (
    source as load_source_reference,decode
)
from generate_source_scanner_glare import load,seed_one_worker,ROOT,SRC,BLOBS,git_blob

def original():
    assert os.environ.get("NUMBA_NUM_THREADS")=="1"
    assert os.environ.get("NUMBA_THREADING_LAYER")=="workqueue"
    for path,sha in BLOBS.items():
        assert git_blob(SRC/path)==sha,(path,"source changed")
    numba.set_num_threads(1)
    assert numba.get_num_threads()==1
    for module in ("spektrafilm","spektrafilm.utils","spektrafilm.model"):
        mod=types.ModuleType(module)
        mod.__path__=[str(SRC)]
        sys.modules[module]=mod
    load("spektrafilm.utils.fast_stats",SRC/"utils/fast_stats.py")
    load("spektrafilm.utils.fast_gaussian_filter",
         SRC/"utils/fast_gaussian_filter.py")
    glare=load("spektrafilm.model.glare",SRC/"model/glare.py")
    ref=load_source_reference()
    # JIT warmup BEFORE pinning each diagnostic random stream.
    glare.compute_random_glare_amount(0.03,0.7,0.5,(2,2))
    return ref,glare

def main(destination):
    cls,src_glare=original()
    settings=[
        dict(active=True,percent=0.0,roughness=0.7,blur=0.4),
        dict(active=True,percent=0.035,roughness=0.65,blur=0.4),
        dict(active=True,percent=0.11,roughness=1.4,blur=3.4),
    ]
    images=((7,5,8888),(4,6,123456))
    output=[]
    for w,h,seed in images:
        src=np.array([[
            [0.02+((p*7+c*3)%19)*0.043 for c in range(3)]
            for p in range(y*w,(y+1)*w)
        ] for y in range(h)],dtype=np.float64)
        light=np.array([0.942,1.0,1.087],dtype=np.float64)
        for yblack,ywhite in ((0.025,0.89),(0.067,0.74)):
            for black,white in ((False,False),(True,False),
                                (False,True),(True,True)):
                obj=cls.__new__(cls)
                obj._black_correction=black
                obj._white_correction=white
                obj._black_level=decode(0.01)
                obj._white_level=decode(0.98)
                obj._y_black=np.array([[yblack]],dtype=np.float64)
                obj._y_white=np.array([[ywhite]],dtype=np.float64)
                obj._update_cmy_black_white_references=lambda in_print=False:None
                corrected=obj.black_white_xyz_correction(src.copy())
                for glare_settings in settings:
                    glare_param=types.SimpleNamespace(**glare_settings)
                    seed_one_worker(seed)
                    after=src_glare.add_glare(
                        corrected.copy(),light,glare_param
                    )
                    assert after.shape==(h,w,3)
                    assert np.isfinite(after).all()
                    output.append(dict(
                        width=w,height=h,seed=seed,
                        black=black,white=white,
                        yBlack=yblack,yWhite=ywhite,
                        percent=glare_param.percent,
                        roughness=glare_param.roughness,
                        blur=glare_param.blur,
                        lamp=light.tolist(),
                        xyz=src.reshape(-1).tolist(),
                        afterBlackWhite=corrected.reshape(-1).tolist(),
                        afterGlare=after.reshape(-1).tolist()
                    ))
    assert len(output)==48
    Path(destination).write_text(json.dumps(
        dict(cases=output,blobs=BLOBS,scope="Original independent Python "
             "ColorReferenceService.black_white_xyz_correction followed by "
             "glare.add_glare, controlled single worker ONLY"),
        allow_nan=False,separators=(",",":")),encoding="utf8")
    print("ORIGINAL PYTHON COMBINED SCAN XYZ PASS: 48 true Python "
          "color reference -> stochastic glare frames, 4 black/white "
          "modes, three glare strengths, seeded one-worker source only.")

if __name__=="__main__":
    main(sys.argv[1])
