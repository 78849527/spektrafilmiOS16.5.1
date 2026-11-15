#!/usr/bin/env python3
"""Pinned upstream grain.py single-layer branch with actual SciPy random draws.
Source AST is used unchanged; Numba wrappers stripped only on FIR/YVV.
"""
import ast
import json
import pathlib
import sys
import numpy as np
import scipy
import scipy.stats
from build84_real_stock_spatial_oracle import (
    ROOT,verify_extra_pins,source_namespace,source_stock_oracle,
    original_gaussian_namespace,
)

GRAIN_SOURCE_BLOB="f2d2b23e3eab4f4a1d919f69bcb4aceb714e024d"

def load_grain():
    from subprocess import check_output
    path=ROOT/"model/grain.py"
    current=check_output(["git","hash-object",str(path)],text=True).strip()
    assert current==GRAIN_SOURCE_BLOB, "SOURCE GRAIN BLOB DRIFT"
    tree=ast.parse(path.read_text(encoding="utf8"))
    functions={"layer_particle_model","apply_grain_to_density"}
    body=[]
    for node in tree.body:
        if isinstance(node,ast.FunctionDef) and node.name in functions:
            node.decorator_list=[]
            body.append(node)
    assert len(body)==2
    ns={"np":np,"scipy":scipy}
    ns["fast_gaussian_filter"]=original_gaussian_namespace()["fast_gaussian_filter"]
    source=ast.fix_missing_locations(ast.Module(body=body,type_ignores=[]))
    exec(compile(source,str(path),"exec"),ns)
    return ns

def main(destination):
    verify_extra_pins()
    films=source_stock_oracle(source_namespace())
    grain=load_grain()
    wanted={
        "kodak_portra_400","kodak_vision3_500t",
        "fujifilm_provia_100f","fujifilm_velvia_100"
    }
    out=[]
    for stock in films:
        if stock["stock"] not in wanted:
            continue
        curves=np.asarray(stock["curves"],dtype=np.float64).reshape(256,3)
        maxima=np.max(curves,axis=0)
        assert np.all(maxima>0)
        for n in (1,3,5):
            for blur in (0.0,0.4,0.65):
                width,height=4,3
                image=np.array([
                    [[0.04+((x+2)*(y+1)*(ch+1)%9)*0.07
                      for ch in range(3)] for x in range(width)]
                    for y in range(height)],dtype=np.float64)
                settings=dict(
                    pixel_size_um=1.8,
                    particle_area_um2=0.2,
                    particle_scale=[1.6,1.6,3.2],
                    density_min=[0.03,0.03,0.03],
                    grain_uniformity=[0.97,0.99,0.97],
                    grain_blur=blur,n_sub_layers=n
                )
                output=grain["apply_grain_to_density"](
                    image.copy(),
                    density_max_curves=maxima,
                    **settings
                )
                out.append(dict(
                    stock=stock["stock"],width=width,height=height,
                    maximum=maxima.tolist(),n=n,blur=blur,
                    input=image.reshape(-1).tolist(),
                    output=output.reshape(-1).tolist()
                ))
    assert len(out)==36
    pathlib.Path(destination).write_text(
        json.dumps(out,allow_nan=False,separators=(",",":")),
        encoding="utf8"
    )
    print("PASS ORIGINAL SOURCE GRAIN.PY AST: 4 measured film profiles, "
          "36 full RGB cases, SciPy Poisson-Binomial, n_sub_layers=1/3/5, "
          "FIR threshold=0/0.4/0.65, Git source pins pass")

if __name__=="__main__":
    main(sys.argv[1])
