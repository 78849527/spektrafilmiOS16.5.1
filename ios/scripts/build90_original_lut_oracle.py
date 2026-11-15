#!/usr/bin/env python3
"""Execute pinned ORIGINAL fast_interp_lut.py Numba PCHIP+Mitchell,
NOT a Python rewrite oracle. Original 1,2,5,7 node LUTs, independent
per-channel domains, clamped high/low and reflective outer boundaries.
"""
from pathlib import Path
import hashlib,importlib.util,json,sys
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/"src/spektrafilm/utils/fast_interp_lut.py"
PIN="a98208467c42af5b7661246b4c3409f2945ad3ed"
def sha_blob(path):
    b=path.read_bytes()
    return hashlib.sha1(b"blob "+str(len(b)).encode()+b"\0"+b).hexdigest()

def main(output):
    assert sha_blob(SOURCE)==PIN,"LUT source changed; re-audit"
    spec=importlib.util.spec_from_file_location("build90_source_numba_lut",SOURCE)
    mod=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=mod
    spec.loader.exec_module(mod)
    rng=np.random.default_rng(9000)
    probes=np.asarray([
        [-0.8,-0.4,-0.05],[-0.000001,0,0],
        [0,0,0],[1,1,1],[0,1,0],[1,0,1],
        [0.5,0.5,0.5],[0.11,0.23,0.42],
        [0.9999,0.89,0.001],[1.7,0.65,2.0],
        [0.24,-0.8,1.3],[1.001,0.4,0.7],
        [0.51,0.51,0.51],[0.125,0.99,0.2],
        [0.03,0.8,0.72],[0.35,0.29,0.64],
    ],dtype=np.float64)
    records=[]
    for size in [1,2,5,7]:
        for kind in ["smooth","nonmonotone"]:
            grid=np.linspace(0,1,size,dtype=np.float64)
            X,Y,Z=np.meshgrid(grid,grid,grid,indexing="ij")
            if kind=="smooth":
                lut=np.stack((
                    0.04+0.82*X**2+0.13*Y-0.03*Z,
                    0.12+0.7*Y**3+0.05*X+0.09*Z,
                    0.05+0.56*Z**2+0.16*X+0.11*Y
                ),axis=-1)
            else:
                lut=np.stack((
                    np.sin(6*X+1.4*Y)-0.32*Z,
                    np.cos(7*Y-0.8*Z)+0.13*X,
                    np.sin(10*Z+3*X+2*Y)
                ),axis=-1)
            lut=np.asarray(lut,dtype=np.float64)
            if kind=="smooth":
                limits=[-0.5,0.2,1.2],[2.,2.3,1.9]
            else:
                limits=[-2.,-0.4,0.15],[1.5,1.4,1.75]
            mi=np.asarray(limits[0])
            ma=np.asarray(limits[1])
            source_points=probes*(ma-mi)+mi
            with np.errstate(invalid="ignore"):
                import warnings
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore",RuntimeWarning)
                    if size == 1:
                        try:
                            mod.apply_lut_3d(
                                lut,probes.reshape(1,-1,3)
                            )
                        except ValueError as exc:
                            assert "zero-size array" in str(exc),str(exc)
                        else:
                            raise AssertionError(
                                "Original source 1-node PCHIP no longer raises"
                            )
                        pchip=np.empty((0,3),dtype=np.float64)
                    else:
                        pchip=mod.apply_lut_3d(
                            lut,probes.reshape(1,-1,3)
                        )[0]
                    if size==1:
                        # Scalar source explicitly handles constant n=1;
                        # the separate bulk Mitchell kernel has no safe
                        # constant fastpath, so do not claim full-frame
                        # 1-node Mitchell certification.
                        single=mod.cubic_interp_lut_at_3d(
                            lut,0.0,0.0,0.0
                        )
                        mitchell=np.tile(single,(len(probes),1))
                    else:
                        mitchell=mod.apply_lut_3d(
                            lut,probes.reshape(1,-1,3),method="mitchell"
                        )[0]
            assert np.isfinite(pchip).all() and np.isfinite(mitchell).all()
            records.append(dict(size=size,kind=kind,
                pchipUnsupported=size==1,
                minimum=mi.tolist(),maximum=ma.tolist(),
                samples=lut.flatten().tolist(),
                input=source_points.tolist(),
                pchip=pchip.tolist(),mitchell=mitchell.tolist()))
    assert len(records)==8
    n=(8+6)*16*3
    Path(output).write_text(json.dumps(dict(
        sourceBlob=PIN,records=records,
        checkedRGBChannels=n,methods=["pchip","mitchell"]),
        separators=(",",":"),allow_nan=False
    ),encoding="utf8")
    print("PASS SOURCE original Numba PCHIP+Mitchell",
          len(records),"source LUT tables,",
          "8 Mitchell + 6 PCHIP source tables,",
          n,"total compared channels expected.")
if __name__=="__main__":
    main(sys.argv[1])
