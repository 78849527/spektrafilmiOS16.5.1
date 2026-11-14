#!/usr/bin/env python3
"""ONE strict Build77 Python-vs-actual-iPhone 3-branch verification command.

This consumes only original Python stage tapes plus real iPhone stage
files exported by Build77OneShotEvidence. It NEVER makes source self-copies
to represent device output. Output is one combined JSON verdict. A pass
on controlled source conditions DOES NOT claim original unseeded defaults,
complete UI parameter parity, P3/RAW, large-image/colour/thermal acceptance.
Missing required evidence is a HARD, visible INCOMPLETE result.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np

UPSTREAM_SHA = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
REFERENCE_INPUT_SHA = (
    "3584df8f8f1f5e4be21682e17218c4d360902320891bb753935f867dbf020e25"
)
CASES = {
    "negative-print": ("kodak_portra_400","kodak_portra_endura",False),
    "direct-scan": ("fujifilm_provia_100f","kodak_portra_endura",False),
    "negative-print-diffusion":
        ("kodak_portra_400","kodak_portra_endura",True),
}
COMPARATOR = Path(__file__).with_name("build77_source_contract.py")


def read_json(file: Path) -> dict:
    if not file.is_file():
        raise FileNotFoundError(f"REQUIRED evidence absent: {file}")
    value = json.loads(file.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"Invalid JSON evidence: {file}")
    return value


def require(test: bool, explanation: str) -> None:
    if not test:
        raise ValueError(explanation)


def verify(source: Path, iphone: Path, atol: float) -> dict:
    device = read_json(iphone / "one-shot-manifest.json")
    require(device["status"]=="REAL_IPHONE_STAGED_EVIDENCE_NOT_PYTHON_CERTIFIED",
            "Device evidence is not actual unverified iPhone stage capture")
    require(device["source_sha"]==UPSTREAM_SHA,
            "Device upstream Python source pin drifted")
    require(device["actual_hardware_device"] is True,
            "Hardware iPhone required: simulator evidence cannot certify")
    require(device["input_source_sha256"]==REFERENCE_INPUT_SHA,
            "iPhone reference input SHA differs")
    require(re.fullmatch(r"[0-9a-f]{40}",
                         device.get("app_source_commit","")) is not None,
            "iPhone binary source commit not embedded or invalid")
    require(len(device["cases"])==3,
            "One-shot source tape package must have all 3 cases")
    source_input=np.load(source/"input.npy",allow_pickle=False)
    require(source_input.shape==(6,4,3) and
            source_input.dtype==np.dtype("<f8"),
            "Original Python reference input is not 6x4x3 Float64")
    require(hashlib.sha256(source_input.tobytes()).hexdigest()==REFERENCE_INPUT_SHA,
            "Original Python input payload SHA changed")
    result={
        "source_sha":UPSTREAM_SHA,
        "iphone_commit":device["app_source_commit"],
        "device_model":device.get("device_model"),
        "source_input_float64_sha":REFERENCE_INPUT_SHA,
        "scope":"one controlled 3-branch 6x4 Float64 stage comparison",
        "cases":{},
        "controlled_3_branch_parity_pass":False,
        "full_build77_certified":False,
        "full_source_default_certification_requirements_unmet":[
            "original unseeded multiworker Numba source RNG",
            "complete RuntimePhotoParams production UI defaults/branches",
            "real 8/12MP memory/thermal/edge-seam/colour validation",
            "iPhone source gamut/ICC and full 7-tap default values",
        ],
    }
    reports={row["name"]:row for row in device["cases"]}
    require(set(reports)==set(CASES),
            "Source one-shot direct/negative/diffusion topology incomplete")
    all_pass=True
    for name,(film,paper,spatial) in CASES.items():
        ref_dir=source/(name+"-controlled")
        original=read_json(ref_dir/"manifest.json")
        record=reports[name]
        require(original["source_sha"]==UPSTREAM_SHA,
                name+": original Python SHA drift")
        require(original["mode"]=="PYTHON_SOURCE_CONTROLLED_BUILD77_ONESHOT",
                name+": original Python reference is unseeded default, not matched control")
        require(original["film"]==film and original["print"]==paper,
                name+": source film/paper does not match actual iPhone")
        require(original["scan_film"]==(name=="direct-scan") and
                original["print_diffusion"]==spatial,
                name+": original source branch does not match device")
        require(record["film"]==film and record["paper"]==paper and
                record["spatial_print"]==spatial,
                name+": iPhone used wrong film/print/branch")
        for key in ("source_grain_active","scanner_glare_active",
                    "camera_metering_active","print_normalize_exposure",
                    "print_reference_compensation"):
            require(record[key] is False, name+": device controlled setting drift: "+key)
        require(record["print_diffusion_strength"]==(0.5 if spatial else 0.0),
                name+": device diffusion setting drift")
        candidate=iphone/name
        source_input_on_device=np.load(candidate/"iosInput.npy",allow_pickle=False)
        require(source_input_on_device.dtype==np.dtype("<f8") and
                source_input_on_device.shape==(6,4,3) and
                np.array_equal(source_input_on_device.view(np.uint64),
                               source_input.view(np.uint64)),
                name+": real Swift iPhone input bit pattern differs from Python")
        completed=subprocess.run([
            sys.executable,str(COMPARATOR),"compare-taps",
            "--reference",str(ref_dir),"--candidate",str(candidate),
            "--candidate-mapping","--atol",str(atol),
        ],capture_output=True,text=True)
        try:
            report=json.loads(completed.stdout)
        except ValueError:
            report={"output":completed.stdout[-6000:]}
        report["comparison_returncode"]=completed.returncode
        report["stderr"]=completed.stderr[-3000:]
        result["cases"][name]=report
        all_pass &= completed.returncode==0
    result["controlled_3_branch_parity_pass"]=bool(all_pass)
    result["status"]=(
        "CONTROLLED_DEVICE_PARITY_PASS_NOT_FULL_DEFAULT_CERTIFIED"
        if all_pass else "CONTROLLED_DEVICE_PARITY_FAILED"
    )
    return result


def main() -> int:
    parser=argparse.ArgumentParser()
    parser.add_argument("--source-evidence",required=True,type=Path)
    parser.add_argument("--iphone-evidence",required=True,type=Path)
    parser.add_argument("--report",required=True,type=Path)
    parser.add_argument("--atol",type=float,default=1e-8)
    args=parser.parse_args()
    record={
        "status":"MISSING_HARDWARE_OR_SOURCE_EVIDENCE",
        "controlled_3_branch_parity_pass":False,
        "full_build77_certified":False,
    }
    try:
        require(0 <= args.atol <= 1e-6 and np.isfinite(args.atol),
                "Must state a finite strict Float64 absolute error ≤ 1e-6")
        record=verify(args.source_evidence,args.iphone_evidence,args.atol)
    except Exception as exc:
        record["error"]=str(exc)
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(
        json.dumps(record,ensure_ascii=False,indent=2)+"\n",encoding="utf-8"
    )
    print(json.dumps(record,ensure_ascii=False,indent=2))
    if record["status"]=="CONTROLLED_DEVICE_PARITY_PASS_NOT_FULL_DEFAULT_CERTIFIED":
        return 0  # Only the specifically scoped controlled-mode check passes.
    return 2  # No false fully certified result, ever.


if __name__=="__main__":
    raise SystemExit(main())
