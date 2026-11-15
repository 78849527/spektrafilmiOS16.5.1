#!/usr/bin/env python3
"""Extract and actually execute the unmodified ColorReferenceService math.
Y black/white are injected as scalar results of the reference scanner
optics, bypassing ONLY external spectrum callbacks; no formula is rewritten.
"""
from __future__ import annotations
import ast
import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace
from typing import Any,Callable
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/"src/spektrafilm"
SOURCE_BLOB="ea612f364228eec1e16cc43a1cd57ee855b9e1d8"

def pin(path,expected):
    raw=path.read_bytes()
    actual=hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()
    assert actual==expected, ("SOURCE BLOB DRIFT",path,actual)

def source():
    path=SRC/"runtime/services/color_reference.py"
    pin(path,SOURCE_BLOB)
    tree=ast.parse(path.read_text(encoding="utf8"))
    nodes=[n for n in tree.body if isinstance(n,ast.ClassDef)
           and n.name=="ColorReferenceService"]
    assert len(nodes)==1
    ns={"np":np,"Any":Any,"Callable":Callable}
    exec(compile(ast.fix_missing_locations(ast.Module(
        body=nodes,type_ignores=[])),str(path),"exec"),ns)
    return ns["ColorReferenceService"]

def decode(x):
    return x/12.92 if x<=0.04045 else ((x+0.055)/1.055)**2.4

def make(cls,film_data,mode,black,white,level_black,level_white):
    service=cls.__new__(cls)
    service._black_correction=black
    service._white_correction=white
    service._black_level=decode(level_black)
    service._white_level=decode(level_white)
    service._y_black=np.array([[mode["yBlack"]]],dtype=np.float64)
    service._y_white=np.array([[mode["yWhite"]]],dtype=np.float64)
    service._scan_film=mode["scanFilm"]
    service._film=SimpleNamespace(
        info=SimpleNamespace(type=film_data["info"]["type"]),
        data=SimpleNamespace(
            density_curves=np.asarray(film_data["data"]["density_curves"],
                                      dtype=np.float64),
            base_density=np.asarray(film_data["data"]["base_density"],
                                    dtype=np.float64),
            log_exposure=np.asarray(film_data["data"]["log_exposure"],
                                    dtype=np.float64)))
    service._print=SimpleNamespace(
        info=SimpleNamespace(type=film_data["info"]["type"]),
        data=service._film.data)
    # Only provide previously measured spectral Y values; the source
    # _correction_function/printing/filming/XYZ math executes unchanged.
    service._update_cmy_black_white_references=lambda in_print=False:None
    return service

def main(dest):
    cls=source()
    import subprocess
    profiles=sorted((SRC/"data/profiles").glob("*.json"))
    stock_hashes={}
    cases=[]
    for profile in profiles:
        info=json.loads(profile.read_text())
        condition=(info["info"]["stage"]=="printing" and
                   info["info"]["type"]=="negative") or (
                    info["info"]["stage"]=="filming" and
                    info["info"]["type"]=="positive")
        if not condition: continue
        sha=subprocess.check_output(["git","hash-object",str(profile)],
                                    text=True).strip()
        stock_hashes[info["info"]["stock"]]=sha
        positive=info["info"]["type"]=="positive"
        for black,white in ((False,False),(True,False),(False,True),(True,True)):
            for y_black,y_white in ((0.012,0.8),(0.047,0.92)):
                mode={"scanFilm":positive,"yBlack":y_black,
                      "yWhite":y_white}
                obj=make(cls,info,mode,black,white,0.01,0.98)
                func,mid=obj._correction_fucntion()
                y0=float(func(np.array([[0.067]],dtype=np.float64))[0,0])
                y1=float(func(np.array([[0.6]],dtype=np.float64))[0,0])
                scalar_xyz=np.array([
                    [[0.10,0.067,0.23],[0.63,0.60,0.84],
                     [0.0,0.0,0.0],[2.0,1.15,1.12]]
                ],dtype=np.float64)
                correction=obj.black_white_xyz_correction(scalar_xyz)
                factor=obj.black_white_filming_exposure_correction() \
                    if positive else obj.black_white_printing_exposure_correction()
                assert np.isfinite(correction).all()
                assert np.isfinite(factor).all()
                axis=np.asarray(info["data"]["log_exposure"],dtype=np.float64)
                curve=np.asarray(info["data"]["density_curves"],dtype=np.float64)
                base=np.asarray(info["data"]["base_density"],dtype=np.float64)
                cases.append(dict(stock=info["info"]["stock"],
                    type="positive" if positive else "negative",
                    settings={"blackCorrection":black,"whiteCorrection":white,
                              "blackLevel":0.01,"whiteLevel":0.98},
                    yBlack=y_black,yWhite=y_white,axis=axis.tolist(),
                    curves=curve.reshape(-1).tolist(),
                    base=base.tolist(),
                    mid=float(mid),yCorrected=[y0,y1],
                    sourceXYZ=scalar_xyz.reshape(-1).tolist(),
                    correctedXYZ=correction.reshape(-1).tolist(),
                    exposureFactor=float(factor)))
    assert len(stock_hashes)>=6,len(stock_hashes)
    assert len(cases)==len(stock_hashes)*8
    Path(dest).write_text(json.dumps(dict(cases=cases,pins=stock_hashes),
                            separators=(",",":"),allow_nan=False))
    print("ORIGINAL SOURCE COLOR REFERENCE PASS: ",
          len(stock_hashes),"real print/positive stocks;",
          len(cases),"black-only white-only combined/off scenarios")

if __name__=="__main__":
    main(sys.argv[1])
