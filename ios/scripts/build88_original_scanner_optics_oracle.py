#!/usr/bin/env python3
"""ORIGINAL Python scanner lens/unsharp source AST vs Swift production.

Uses the exact pinned source diffusion.py function bodies and original
fast_gaussian_filter.py FIR/YVV; no hand-written Gaussian replacement.
Negative sigmas and nonpositive amounts exercise source skip branches.
"""
import ast
import json
from pathlib import Path
import sys
import numpy as np
from build84_real_stock_spatial_oracle import (
    ROOT, original_gaussian_namespace
)

DIFFUSION_SHA="cb22136f9d6a65e32ab54fc6f46f64f308e1a4f7"
FILTER_SHA="8918c673ea0fb3f5d9ae820ca85bf6db4aba457a"

def original():
    from subprocess import check_output
    for path,sha in (("model/diffusion.py",DIFFUSION_SHA),
                     ("utils/fast_gaussian_filter.py",FILTER_SHA)):
        assert check_output(
            ["git","hash-object",str(ROOT/path)],text=True
        ).strip()==sha,(path,"original source drift")
    tree=ast.parse((ROOT/"model/diffusion.py").read_text())
    wanted={"apply_gaussian_blur","apply_unsharp_mask"}
    nodes=[n for n in tree.body
           if isinstance(n,ast.FunctionDef) and n.name in wanted]
    assert len(nodes)==2
    filters=original_gaussian_namespace()
    scope={"np":np,"fast_gaussian_filter":filters["fast_gaussian_filter"]}
    exec(compile(ast.fix_missing_locations(ast.Module(
        body=nodes,type_ignores=[])),str(ROOT/"model/diffusion.py"),
        "exec"),scope)
    return scope

def main(dest):
    src=original()
    shapes=((1,1),(1,7),(7,1),(7,5),(11,9))
    configs=[
        (0.0,0.0,0.0),(-2.0,-1.0,1.0),
        (0.2,0.0,0.0),(3.25,0.4,1.2),
        (0.0,7.25,3.3),(51.0,0.0,0.0),
        (1.0,4.0,-0.2),(0.0,0.0,4.0),
        (2.99,3.0,0.4),(3.0,2.99,2.4),
        (0.7,1.4,0.8),(6.8,-4.0,2.0),
    ]
    cases=[]
    for w,h in shapes:
        image=np.array(
            [[[0.07 + ((x*7+y*3+ch*11)%17)*0.081
               for ch in range(3)] for x in range(w)]
             for y in range(h)],dtype=np.float64)
        image[0,0,:]=[1.7,0.12,-0.16]
        for lens,sigma,amount in configs:
            blurred=src["apply_gaussian_blur"](image.copy(),lens)
            if sigma>0 and amount>0:
                unsharpBlur=src["apply_gaussian_blur"](blurred.copy(),sigma)
                final=src["apply_unsharp_mask"](
                    blurred.copy(),sigma=sigma,amount=amount
                )
            else:
                unsharpBlur=None
                final=blurred
            assert np.isfinite(final).all()
            cases.append(dict(
                width=w,height=h,lens=lens,sigma=sigma,
                amount=amount,
                input=image.reshape(-1).tolist(),
                lensStage=blurred.reshape(-1).tolist() if lens>0 else None,
                unsharpBlur=unsharpBlur.reshape(-1).tolist()
                    if unsharpBlur is not None else None,
                final=final.reshape(-1).tolist()
            ))
    assert len(cases)==60
    Path(dest).write_text(json.dumps(
        dict(cases=cases,sourceBlob=DIFFUSION_SHA,
             filterBlob=FILTER_SHA),separators=(",",":"),allow_nan=False
    ),encoding="utf8")
    print("SOURCE SCANNER FIR/YVV AST PASS: 60 full RGB images; "
          "σ=0.2/2.99/3/3.25/7.25/51, amount=-0.2 to 4, "
          "1×1 and narrow mirror images, 2 original sources SHA pinned.")

if __name__=="__main__":
    main(sys.argv[1])
