#!/usr/bin/env python3
"""Real source 20-stock customized DIR/gamma/zero-spatial oracle.
All arithmetic is run by the pinned original Python AST functions.
"""
import json
import pathlib
import sys
from types import SimpleNamespace
import numpy as np
from build84_real_stock_spatial_oracle import (
    verify_extra_pins,source_namespace,source_stock_oracle
)

def main(path):
    verify_extra_pins()
    ns=source_namespace()
    films=source_stock_oracle(ns)
    scenarios=[
        dict(amount=1.0,same=1.0,inter=1.0,gamma=[1,1,1],
             shift=0.0,active=True,spatial=False),
        dict(amount=0.72,same=0.75,inter=1.24,gamma=[0.86,1.0,1.14],
             shift=0.0,active=True,spatial=False),
        dict(amount=1.19,same=1.30,inter=0.44,gamma=[1.17,0.92,1.04],
             shift=0.13,active=True,spatial=False),
        dict(amount=0.93,same=1.0,inter=1.0,gamma=[1,1,1],
             shift=0.0,active=False,spatial=False),
    ]
    result=[]
    for film in films:
        stock=film["stock"]
        positive=film["positive"]
        x=np.asarray(film["logAxis"],dtype=np.float64)
        dc=np.asarray(film["curves"],dtype=np.float64).reshape(256,3)
        source_base=np.asarray(film["matrix"],dtype=np.float64).reshape(3,3)
        raw=np.array([[[
            x[0]-0.23,x[38]+0.001,x[111]
        ],[
            x[255]+0.42,x[205],x[94]-0.004
        ],[
            x[126],x[0]-1.0,x[253]
        ]]],dtype=np.float64)
        for config in scenarios:
            args=config
            params=ns["DirCouplersParams"]()
            params.amount=args["amount"]
            params.inhibition_samelayer=args["same"]
            params.inhibition_interlayer=args["inter"]
            fake=SimpleNamespace(
                film=SimpleNamespace(
                    is_positive=positive,is_negative=not positive,
                    info=SimpleNamespace(stock=stock)),
                film_render=SimpleNamespace(dir_couplers=params))
            ns["_apply_film_specifics"](fake)
            M=ns["compute_dir_couplers_matrix"](params)*params.amount
            expected_matrix=source_base.copy()
            for donor in range(3):
                for receiver in range(3):
                    expected_matrix[donor,receiver]*=(
                        args["same"] if donor==receiver else args["inter"]
                    )*args["amount"]
            assert np.max(np.abs(M-expected_matrix))<1e-15
            if args["active"]:
                before=ns["compute_density_curves_before_dir_couplers"](
                    dc,x,M,positive=positive)
            else:
                before=dc
            gamma=np.asarray(args["gamma"],dtype=np.float64)
            initial=ns["interpolate_exposure_to_density"](raw,dc,x,gamma)
            if args["active"]:
                corrected_raw=ns["compute_exposure_correction_dir_couplers"](
                    raw,initial,np.max(dc,axis=0),M,
                    diffusion_size_pixel=0,
                    high_exposure_couplers_shift=args["shift"],
                    positive=positive)
            else:
                corrected_raw=raw
            final=ns["interpolate_exposure_to_density"](
                corrected_raw,before,x,gamma)
            result.append(dict(
                stock=stock,positive=positive,settings=args,
                logAxis=film["logAxis"],curves=film["curves"],
                matrix=M.reshape(-1).tolist(),
                beforeDIR=before.reshape(-1).tolist(),
                raw=raw.reshape(-1).tolist(),
                initial=initial.reshape(-1).tolist(),
                correctedRaw=corrected_raw.reshape(-1).tolist(),
                final=final.reshape(-1).tolist()
            ))
    assert len(result)==80
    pathlib.Path(path).write_text(
        json.dumps(result,separators=(",",":"),allow_nan=False),
        encoding="utf8"
    )
    print("PASS: 20 real stocks x 4 dynamic source modes = 80 vectors; "
          "matrix amount, same/interlayer, gamma, positive, shift, off "
          "from ORIGINAL Python code; reference SHA pins verified")

if __name__=="__main__":
    main(sys.argv[1])
