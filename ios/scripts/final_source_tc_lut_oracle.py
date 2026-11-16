#!/usr/bin/env python3
"""Python original Hanatos TC LUT gamut remap, independent end-to-end 2D proof.

Execute the pinned original gamut_compression.remap_tc_lut_for_compression
function, with pinned original _quad2tri/_tri2quad AST functions injected
as its import dependencies. No generated expected values from Swift.
"""
from __future__ import annotations
import ast,hashlib,importlib.util,json,sys,types,warnings
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
GAMUT=ROOT/"src/spektrafilm/utils/gamut_compression.py"
SPECTRAL=ROOT/"src/spektrafilm/utils/spectral_upsampling.py"
GAMUT_PIN="9783e7fcfc2909c4acdf2da53595c5404645dde9"
SPECTRAL_PIN="bb75f8a00d00eb02ba571c6cfdbec88a8c0194cb"

def pin(path):
    data=path.read_bytes()
    return hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()

def isolate_original_coord_functions(path):
    tree=ast.parse(path.read_text(),filename=str(path))
    chosen=[n for n in tree.body if isinstance(n,ast.FunctionDef)
            and n.name in {"_quad2tri","_tri2quad"}]
    assert len(chosen)==2
    tmp=types.ModuleType("spektrafilm.utils.spectral_upsampling")
    ns=tmp.__dict__
    ns["np"]=np
    exec(compile(ast.fix_missing_locations(
        ast.Module(body=chosen,type_ignores=[])),str(path),"exec"),ns)
    sys.modules["spektrafilm"]=types.ModuleType("spektrafilm")
    sys.modules["spektrafilm.utils"]=types.ModuleType("spektrafilm.utils")
    sys.modules[tmp.__name__]=tmp

def main(out):
    assert pin(GAMUT)==GAMUT_PIN, "gamut source drift"
    assert pin(SPECTRAL)==SPECTRAL_PIN, "spectral coordinate source drift"
    isolate_original_coord_functions(SPECTRAL)
    spec=importlib.util.spec_from_file_location("pinned_original_remap",GAMUT)
    source=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=source
    spec.loader.exec_module(source)
    cases=[]
    for side in [12,23]:
        # Deliberately nontrivial 2D Float64 RGB spectral TC LUT input:
        # test exact source tc→xy→gamut→tc→nearest-edge bilinear.
        i=np.arange(side*side*3,dtype=float).reshape(side,side,3)
        image=0.06+np.cos(i*0.033)*0.18+i*0.00031
        for algo in ["xy","oklch"]:
            cfg=source.InputGamutCompressSpec(active=True,algorithm=algo)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore",RuntimeWarning)
                actual=source.remap_tc_lut_for_compression(
                    image,np.asarray([0.3127,0.3290]),cfg
                )
            assert actual.shape==image.shape and np.isfinite(actual).all()
            cases.append({
                "name":f"{side}_{algo}",
                "algorithm":algo,
                "side":side,
                "referenceXY":[0.3127,0.3290],
                "original":image.reshape(-1).tolist(),
                "expected":actual.reshape(-1).tolist(),
            })
    Path(out).write_text(json.dumps({
        "gamutBlob":GAMUT_PIN,
        "spectralBlob":SPECTRAL_PIN,
        "cases":cases,
        "sourceGamutFullProductionCertified":False
    },allow_nan=False,separators=(",",":")),encoding="utf8")
    print("PASS actual pinned Python remap_tc_lut_for_compression: ",
          "2 sizes x 2 input gamut algorithms = 4 2D source table cases")

if __name__=="__main__":
    main(sys.argv[1])
