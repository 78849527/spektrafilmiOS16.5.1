#!/usr/bin/env python3
"""Execute ORIGINAL pinned utils/io.py::save_image_oiio AST directly
using an in-memory OIIO recording backend (no native OpenImageIO install).
This executes original format/quantization branches, not a copied formula.
EXR Float16/32 and TIFF Float32 preserve under-black and super-white.
"""
from pathlib import Path
import ast,hashlib,json,sys
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
PATH=ROOT/"src/spektrafilm/utils/io.py"
PIN="3c1a8787cac39bd5d3e6652c6e34a111a2565f3c"

class TypeDesc:
    def __init__(self,value):self.value=value
class Spec:
    def __init__(self,w,h,n,desc):
        self.w=w;self.h=h;self.n=n;self.dtype=desc.value
        self.attributes={}
    def attribute(self,key,value,*args):self.attributes[key]=value
class Writer:
    def __init__(self,registry):self.registry=registry
    def open(self,name,spec):self.spec=spec
    def write_image(self,data):
        self.registry["pixels"]=np.asarray(data).copy()
        self.registry["dtype"]=self.spec.dtype
        self.registry["attributes"]=self.spec.attributes.copy()
    def close(self):pass
class Output:
    def __init__(self,registry):self.registry=registry
    def create(self,name):return Writer(self.registry)
class OIIO:
    def __init__(self,registry):
        self.TypeDesc=TypeDesc
        self.ImageSpec=Spec
        self.ImageOutput=Output(registry)

def gitblob(data):
    return hashlib.sha1(
        b"blob "+str(len(data)).encode()+b"\0"+data
    ).hexdigest()

def main(out):
    source=PATH.read_bytes()
    assert gitblob(source)==PIN,"Source io.py changed"
    tree=ast.parse(source)
    functions=[s for s in tree.body if isinstance(
        s,ast.FunctionDef
    ) and s.name=="save_image_oiio"]
    assert len(functions)==1
    # original AST unmodified, no production OIIO binding required;
    # the fake output just records exact arrays and dtype.
    astModule=ast.Module(body=functions,type_ignores=[])
    registry={}
    ns={
        "np":np,"oiio":OIIO(registry),
        "_load_icc_profile":lambda *_:None
    }
    exec(compile(astModule,str(PATH),"exec"),ns)
    save=ns["save_image_oiio"]
    rng=np.random.default_rng(4090)
    sample=[
        [-3.0,-1e-6,-0.0],
        [0,0,0],
        [0.0004,1/255-1e-10,1/255+1e-10],
        [0.125,0.18,0.29],
        [0.49999,0.5,0.500001],
        [1-1e-8,1.,1+1e-8],
        [2.0,1.5,-2.3],
        [0.007,0.93,1.62],
    ]
    sample.extend(rng.uniform(-1.7,2.3,size=(32,3)).tolist())
    pixel=np.asarray(sample,dtype=np.float64).reshape(1,-1,3)
    choices=[
        ("jpg",16),("jpeg",8),("png",32),
        ("tif",8),("tiff",16),("tif",32),
        ("exr",16),("exr",32),
    ]
    cases=[]
    for ext,bit in choices:
        registry.clear()
        save("build90-source."+ext,pixel,bit_depth=bit)
        actual=registry["pixels"]
        assert actual.shape==(1,len(sample),3)
        assert np.isfinite(actual).all()
        cases.append(dict(format=ext,bitDepth=bit,
            dtype=registry["dtype"],
            input=sample,expected=actual.reshape(-1,3).tolist(),
            # source float16 is binary16 exactly, avoid JSON's dtype.
            expectedBits=actual.astype(np.float32).view(np.uint32).reshape(-1,3).tolist()
        ))
    assert len(cases)==8
    Path(out).write_text(json.dumps(
        dict(sourceBlob=PIN,cases=cases,pixels=len(sample),
             sourceFunction="save_image_oiio"),
        separators=(",",":"),allow_nan=False
    ))
    print("PASS ORIGINAL SOURCE OIIO numeric output AST",
          len(cases),"formats,",len(sample),"pixels each;",
          len(cases)*len(sample)*3,"source quantized channel values.")
if __name__=="__main__":
    main(sys.argv[1])
