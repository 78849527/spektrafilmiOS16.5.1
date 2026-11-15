#!/usr/bin/env python3
"""Build92/45. Strict original-Python source optical frame-tape audit.

Consumes ONLY files generated in current CI from upstream actual Hanatos /
film H-D / spatial DIR / paper / scanner + seeded single-worker Numba grain.
Validates the original SHA256 for all 12 stages on all four images; computes
per-stage full-frame min/max/mean/RMS, edge residual proxies, grain changes
and 3-channel distributions. The separate *production* native Swift
SourcePhysicalImageParity.evaluate is compiled into the iPhone app and
runs ONLY on the hardware when the diagnostic is selected. These Python
reference metrics NEVER masquerade as measured Swift or iPhone results.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

STAGES=(
    "logRaw","initial","inhibitors","diffused","correctedLog",
    "density","printed","grainSublayers","grainDyeClouds",
    "grainMicrostructure","grainDensity","grainPrinted"
)
SCOPE="original-source-nonlinear-hanatos-spatial-dir-paper-aces-8bit"
LIMITATIONS=(
    "not RAW/LibRaw/AppleRAW numerical equivalence",
    "not 16/32-bit input",
    "not Display P3/Rec2020 full physical file pipeline",
    "not unseeded Numba multiworker equivalence",
    "not source full-size 13MP iPhone frame",
    "not physical iPhone measured stage RGB",
)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--fixtures",default="ios/verification/generated-physical-v1.8.22")
    parser.add_argument("--out",required=True)
    args=parser.parse_args()
    base=Path(args.fixtures)
    manifest=json.loads((base/"manifest.json").read_text())
    assert manifest["scope"]==SCOPE
    cases=manifest["cases"]
    assert len(cases)==4, "Must use four actual original optical source images"
    assert manifest["grain"]["numba_seed"]==8888
    assert manifest["grain"]["numba_workers"]==1
    assert any(c["numba_micro_enabled"] for c in cases)
    rows=[]
    total=0
    for case in cases:
        w,h=int(case["width"]),int(case["height"])
        assert 0<w<512 and 0<h<512
        name=case["name"]
        with_layers=None
        for stage in STAGES:
            key=f"{name}.{stage}.f64le"
            path=base/key
            data=path.read_bytes()
            checksum=hashlib.sha256(data).hexdigest()
            assert checksum==case["sha256"][stage],(name,stage,"source digest")
            n=w*h*(9 if stage=="grainSublayers" else 3)
            assert len(data)==n*8,(name,stage,len(data),n)
            frame=np.frombuffer(data,dtype="<f8").reshape(
                h,w,9 if stage=="grainSublayers" else 3
            )
            assert np.isfinite(frame).all(),(name,stage,"nonfinite source")
            assert frame.dtype==np.float64 and frame.shape[0:2]==(h,w)
            boundaries={
                "left":float(np.mean(frame[:,0,:])),
                "right":float(np.mean(frame[:,-1,:])),
                "top":float(np.mean(frame[0,:,:])),
                "bottom":float(np.mean(frame[-1,:,:])),
                "edge_horizontal_max":float(np.max(np.abs(frame[:,0,:]-frame[:,-1,:]))),
                "edge_vertical_max":float(np.max(np.abs(frame[0,:,:]-frame[-1,:,:]))),
            }
            rows.append({
                "case":name,"stage":stage,"width":w,"height":h,
                "samples":n,"sha256":checksum,
                "min":float(np.min(frame)),"max":float(np.max(frame)),
                "mean":float(np.mean(frame)),
                "rms":float(np.sqrt(np.mean(frame*frame))),
                "per_channel_means":np.mean(frame,axis=(0,1)).tolist(),
                "per_channel_stdev":np.std(frame,axis=(0,1)).tolist(),
                "edges":boundaries,
                "label":"original-python-reference-only",
            })
            total+=n
            if stage=="printed":with_layers=frame.copy()
            if stage=="grainPrinted":
                difference=frame-with_layers
                rows[-1]["grain_to_output_mae"]=float(np.mean(np.abs(difference)))
                assert rows[-1]["grain_to_output_mae"]>=0
        png=(base/f"{name}.png").read_bytes()
        assert hashlib.sha256(png).hexdigest()==case["sha256"]["png"]
        print("PASS Build92 source 12 stages",name,w,h,
              "micro-enabled",case["numba_micro_enabled"],flush=True)
    assert len(rows)==48
    proof={
        "source_scope":SCOPE,
        "source_manifest_sha256":hashlib.sha256(
            (base/"manifest.json").read_bytes()
        ).hexdigest(),
        "original_python_case_count":len(cases),
        "original_python_stage_count":len(STAGES),
        "original_python_tape_count":len(rows),
        "original_python_float64_samples":total,
        "comparison_to_native":"NOT EXECUTED by Python audit; on-device SourcePhysicalImageParity.evaluate must run",
        "real_device_certified":False,
        "unverified":list(LIMITATIONS),
        "tapes":rows
    }
    out=Path(args.out)
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(proof,indent=2,sort_keys=True,allow_nan=False)+"\n")
    print("PASS Build92 48/48 ORIGINAL PYTHON 12-stage tapes,",
          total,"source Float64 samples; NOT iPhone stage parity")
if __name__=="__main__":
    main()
