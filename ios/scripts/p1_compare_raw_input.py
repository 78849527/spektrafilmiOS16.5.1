#!/usr/bin/env python3
"""Compare actual LibRaw ACES16 against Python rawpy Float32. Input tap only."""
from __future__ import annotations
import argparse
import hashlib
import json
import tempfile
from pathlib import Path
import numpy as np

def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def compare(manifest: Path, reference: Path, native: Path,
            raw: Path | None = None) -> dict:
    p = json.loads(manifest.read_text())
    if p.get("output_colorspace") != "ACES2065-1" or p.get("output_cctf_encoding") is not False:
        raise ValueError("Python reference must be linear ACES2065-1")
    if p.get("white_balance") != "as_shot" or p.get("output_type") != "float32":
        raise ValueError("RAW white balance or precision differs")
    if p.get("endianness") != "little":
        raise ValueError("Unexpected byte order")
    shape = p.get("shape")
    if not (isinstance(shape,list) and len(shape)==3 and
            all(isinstance(x,int) and x>0 for x in shape) and shape[2]==3):
        raise ValueError("Invalid RGB dimensions")
    h,w,_=shape
    channels=h*w*3
    if p.get("byte_length")!=channels*4:
        raise ValueError("Reference channel count or byte length is inconsistent")
    if reference.stat().st_size!=channels*4 or native.stat().st_size!=channels*2:
        raise ValueError("Actual Python/native RAW channel buffers have different sizes")
    if sha256_file(reference)!=p.get("golden_sha256"):
        raise ValueError("Python Float32 reference SHA256 mismatch")
    if raw is not None and sha256_file(raw)!=p.get("raw_sha256"):
        raise ValueError("Original camera RAW changed since Python reference was generated")
    py=np.memmap(reference,dtype="<f4",mode="r",shape=(channels,))
    ios=np.memmap(native,dtype="<u2",mode="r",shape=(channels,))
    exact=0
    total=0.0
    squares=0.0
    maximum=0.0
    worst=-1
    first=-1
    for begin in range(0,channels,524288):
        end=min(begin+524288,channels)
        observed=ios[begin:end].astype(np.float32)/np.float32(65535.0)
        expected=np.asarray(py[begin:end])
        if not np.isfinite(observed).all() or not np.isfinite(expected).all():
            raise ValueError("Non-finite camera input is not comparable")
        equal=observed.view(np.uint32)==expected.view(np.uint32)
        exact+=int(np.count_nonzero(equal))
        if not equal.all() and first==-1:
            first=begin+int(np.flatnonzero(~equal)[0])
        diff=np.abs(observed.astype(np.float64)-expected.astype(np.float64))
        total+=float(np.sum(diff))
        squares+=float(np.dot(diff,diff))
        idx=int(np.argmax(diff))
        if diff[idx]>maximum:
            maximum=float(diff[idx])
            worst=begin+idx
    report={
        "scope":"rawpy/LibRaw input tap ONLY; no full optical parity",
        "shape":shape,"channels":channels,"exact_channels":exact,
        "different_channels":channels-exact,
        "first_difference":first,"worst_index":worst,
        "mae":total/channels,"rmse":(squares/channels)**0.5,
        "maximum_abs":maximum,"raw_sha256":p.get("raw_sha256"),
        "python_golden_sha256":p["golden_sha256"],
        "native_rgb16_sha256":sha256_file(native),
        "strict_input_bit_exact":exact==channels
    }
    return report

def selftest() -> None:
    with tempfile.TemporaryDirectory() as t:
        base=Path(t)
        data=np.asarray([0,1,2,32767,32768,65534,65535]*3,
                        dtype="<u2").reshape(1,7,3)
        native=base/"native.rgb16le"
        golden=base/"golden.rgbf32le"
        manifest=base/"manifest.json"
        data.tofile(native)
        (data.astype(np.float32)/np.float32(65535.0)).astype("<f4").tofile(golden)
        manifest.write_text(json.dumps({
            "shape":[1,7,3],"byte_length":84,
            "golden_sha256":sha256_file(golden),
            "raw_sha256":"synthetic-only","white_balance":"as_shot",
            "output_type":"float32","output_colorspace":"ACES2065-1",
            "output_cctf_encoding":False,"endianness":"little"
        }))
        result=compare(manifest,golden,native)
        assert result["strict_input_bit_exact"] and result["exact_channels"]==21
        broken=data.copy()
        broken[0,0,0]=2
        broken.tofile(native)
        result=compare(manifest,golden,native)
        assert not result["strict_input_bit_exact"] and result["different_channels"]==1
    print("PASS P1 synthetic 21/21 Float32 exact + 1-channel mutation rejection")

def main() -> None:
    p=argparse.ArgumentParser()
    p.add_argument("--selftest",action="store_true")
    p.add_argument("--manifest",type=Path)
    p.add_argument("--reference",type=Path)
    p.add_argument("--native",type=Path)
    p.add_argument("--raw",type=Path)
    p.add_argument("--out",type=Path)
    a=p.parse_args()
    if a.selftest:
        selftest()
        if a.manifest is None:
            return
    if not all([a.manifest,a.reference,a.native]):
        p.error("Specify --manifest --reference --native")
    report=compare(a.manifest,a.reference,a.native,a.raw)
    if a.out:
        a.out.parent.mkdir(parents=True,exist_ok=True)
        a.out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(report,ensure_ascii=False,indent=2))
    if not report["strict_input_bit_exact"]:
        raise SystemExit("FAIL native RAW differs from Python rawpy: NOT CERTIFIED")

if __name__=="__main__":
    main()
