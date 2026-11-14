#!/usr/bin/env python3
"""Independent TH-KG3-L original source illuminant parity.

No package __init__/exiv2 imports: compile exactly the pinned original
AST nodes standard_illuminant, black_body_spectrum and GenericFilter.
This checks the produced Swift Float64 lamp spectrum, not full printing
or any approximation of the diffusion-filter FFT.
"""
from __future__ import annotations
import ast
import base64
import hashlib
import re
from pathlib import Path

import colour
import numpy as np
from scipy.interpolate import Akima1DInterpolator

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/"src/spektrafilm"
WL=np.arange(380,781,5,dtype=np.float64)
SHAPE=colour.SpectralShape(380,780,5)
BLOBS={
    "model/illuminants.py":"5feacaec729f371eea48ea5e69da3291bcf7123e",
    "model/color_filters.py":"73849be82f7e32e21cd9bf3e116ba244a931188b",
}

def load_node(path,kind,name,globals_):
    p=SOURCE/path
    raw=p.read_bytes()
    sha=hashlib.sha1(
        b"blob "+str(len(raw)).encode()+b"\x00"+raw
    ).hexdigest()
    assert sha==BLOBS[path],(path,sha,BLOBS[path])
    parsed=ast.parse(raw,filename=str(p))
    nodes=[n for n in parsed.body if isinstance(n,kind) and n.name==name]
    assert len(nodes)==1,(path,name)
    exec(compile(ast.Module(body=nodes,type_ignores=[]),str(p),"exec"),
         globals_)
    return globals_[name]

def measured(name,scale=1.0):
    if name=="KG3":
        path=SOURCE/"data/filters/heat_absorbing/schott/KG3.csv"
    else:
        path=SOURCE/(
            "data/filters/lens_transmission/canon/canon_24_f28_is.csv"
        )
    data=np.loadtxt(path,delimiter=",",dtype=np.float64)
    index=np.unique(data[:,0],return_index=True)[1]
    return np.asarray(Akima1DInterpolator(
        data[index,0],data[index,1]/scale
    )(WL),dtype=np.float64)

def main():
    ns={"np":np,"colour":colour,"SPECTRAL_SHAPE":SHAPE}
    GF=load_node("model/color_filters.py",ast.ClassDef,"GenericFilter",ns)
    def build_filter(values):
        obj=object.__new__(GF)
        obj.transmittance=values
        return obj
    ns["schott_kg3_heat_filter"]=build_filter(measured("KG3"))
    ns["generic_lens_transmission"]=build_filter(
        measured("Canon",scale=100.0)
    )
    load_node("model/illuminants.py",ast.FunctionDef,
              "black_body_spectrum",ns)
    original=load_node("model/illuminants.py",ast.FunctionDef,
                       "standard_illuminant",ns)
    reference=np.asarray(original("TH-KG3-L"),dtype=np.float64)
    assert reference.shape==(81,)
    assert abs(reference.mean()-1)<1e-13
    swift=(ROOT/"ios/SpektraFilmPort/GeneratedOriginalOptics.swift").read_text()
    pattern=r'^\s*static let sourceF64_enlargerSourceLens = "([^"]+)"'
    m=re.search(pattern,swift,re.M)
    assert m,"Generated Float64 TH-KG3-L lamp missing"
    observed=np.frombuffer(base64.b64decode(m.group(1)),dtype="<f8")
    assert observed.shape==(81,)
    error=np.max(np.abs(observed-reference))
    assert error < 1e-10,error
    neutral=original("TH-KG3")
    assert np.max(np.abs(observed-neutral))>1e-6
    print(f"PASS: original TH-KG3-L 81-point Float64 lamp vs pinned Python standard_illuminant max={error:.3g}, real Canon lens and Schott KG3, not stock neutral filter fallback")

if __name__=="__main__":
    main()
