#!/usr/bin/env python3
"""Independent original JSON versus EMBEDDED Swift Float64 byte-level guard.

This reads the SOURCE JSON again, separately from the generators, and checks
that all 28 profiles' original Float64 IEEE-754 words appear byte-for-byte
in GeneratedSpectralData.swift (and fast Float32 arrays remain unchanged).
It also directly recomputes 20 original pre-DIR curves from the original
Float64 source; compare with both generated source and mobile data.

No numerical thresholds, appearance tests, silent downcasting or network.
"""
from __future__ import annotations
import base64
import hashlib
import json
import re
import struct
from pathlib import Path

import numpy as np

ROOT=Path(__file__).resolve().parents[2]
PROFILES=ROOT/"src/spektrafilm/data/profiles"
EMBEDDED=(ROOT/"ios/SpektraFilmPort/GeneratedSpectralData.swift").read_text()
DIR_SWIFT=(ROOT/"ios/SpektraFilmPort/GeneratedDIRData.swift").read_text()

FIELDS=[
    ("log_sensitivity","logSensitivity","sourceLogSensitivityF64",243),
    ("channel_density","channelDensity","sourceChannelDensityF64",243),
    ("base_density","baseDensity","sourceBaseDensityF64",81),
    ("log_exposure","logExposure","sourceLogExposureF64",256),
    ("density_curves","densityCurves","sourceDensityCurvesF64",768),
    ("density_curves_layers","densityCurvesLayers","sourceDensityCurvesLayersF64",2304),
]

def flatten(v):
    if isinstance(v,list):
        for x in v:
            yield from flatten(x)
    else:
        yield 0.0 if v is None else float(v)


def extract(line,key):
    pattern=r'\b'+re.escape(key)+r': "([^"]*)"'
    m=re.search(pattern,line)
    if not m: raise ValueError("Missing "+key)
    return m.group(1)


def packed(v,format):
    data=list(flatten(v))
    return struct.pack("<"+format*len(data),*data)


def record_line(source,stock):
    # The source file is one record per line, even when base64 is large.
    pattern=r'^\s*'+re.escape(json.dumps(stock))+r': Record\('
    for line in source.splitlines():
        if re.search(pattern,line):
            return line
    raise ValueError("Missing material "+stock)


def main():
    import importlib.util
    import sys
    spec=importlib.util.spec_from_file_location(
        "source_dir_generator",ROOT/"ios/scripts/generate_dir.py"
    )
    module=importlib.util.module_from_spec(spec)
    sys.modules[spec.name]=module
    spec.loader.exec_module(module)

    total=0
    changed=0
    dircount=0
    layerstocks=0
    for p in sorted(PROFILES.glob("*.json")):
        doc=json.loads(p.read_text())
        stock=doc["info"]["stock"]
        data=doc["data"]
        line=record_line(EMBEDDED,stock)
        double_payload=b""
        for src,fast,exact,count in FIELDS:
            original = data.get(src)
            source_field=extract(line,exact)
            fast_field=extract(line,fast)
            if original is None:
                assert source_field==fast_field=="", (stock,src)
                continue
            x=list(flatten(original))
            assert len(x)==count, (stock,src,len(x),count)
            precise=struct.pack("<"+"d"*count,*x)
            mobile=struct.pack("<"+"f"*count,*x)
            actual_source=base64.b64decode(source_field)
            actual_fast=base64.b64decode(fast_field)
            assert actual_source==precise, (stock,src,"source Float64 bytes not equal")
            assert actual_fast==mobile, (stock,src,"fast/mobile Float32 bytes changed")
            double_payload+=actual_source
            changed+=sum(
                float(np.float32(v)) != float(v) for v in x
            )
            total+=count
            if src=="density_curves_layers" and doc["info"]["stage"]=="filming":
                layerstocks+=1
        assert extract(line,"sourceFloat64SHA256")==hashlib.sha256(
            double_payload
        ).hexdigest(),stock

        if doc["info"]["stage"]=="filming":
            le=np.asarray(data["log_exposure"],dtype=np.float64)
            curve=np.asarray(data["density_curves"],dtype=np.float64)
            curve-=np.min(curve,axis=0)
            positive=doc["info"]["type"]=="positive"
            mat=module.matrix(stock,positive)
            expected=module.prepare_curves(le,curve,mat,positive)
            expected64=expected.astype("<f8").tobytes()
            expected32=expected.astype("<f4").tobytes()
            dirline=record_line(DIR_SWIFT,stock)
            assert base64.b64decode(extract(
                dirline,"sourceCorrectedCurvesF64"
            ))==expected64,stock+" exact DIR discrepancy"
            assert base64.b64decode(extract(
                dirline,"correctedCurves"
            ))==expected32,stock+" legacy DIR discrepancy"
            assert extract(
                dirline,"sourceCorrectedSHA256"
            )==hashlib.sha256(expected64).hexdigest(),stock
            dircount+=1
    assert dircount==20 and layerstocks==20 and changed>0
    print(
        f"PASS: all 28 ORIGINAL JSON arrays exact f64 bytes vs Swift embeds; "
        f"{total} measured samples ({changed} changed by old f32 quantization); "
        f"{layerstocks} full 3x3 256-node layer stocks; "
        f"{dircount} original 768-point Float64 pre-DIR curves."
    )

if __name__=="__main__":
    main()
