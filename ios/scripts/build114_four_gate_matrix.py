#!/usr/bin/env python3
"""Build114 scope-explicit certification ledger.

This gates the *presence* of four independent source/native test paths
without upgrading a narrow PASS into full Python/RAW/RNG certification.
"""
import hashlib
import json
import os
from pathlib import Path

root=Path(__file__).resolve().parents[2]
read=lambda p:(root/p).read_text()
src=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
conv=read("ios/SpektraFilmPort/SourceSpatialDIRConvolution.swift")
ui=read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
device=read("ios/SpektraFilmPort/Build108SourceOpticalDeviceStress.swift")
raw=read("ios/SpektraFilmPort/Build95LibRaw16Ingress.swift")
input_profile=read("ios/SpektraFilmPort/Build111PhotoInputProfile.swift")
original=read("ios/scripts/generate_source_physical_frame.py")
test=read("ios/tests/Build114InPlaceDIRValidation.swift")
numba_path=root/"ios/build/release/build114-unseeded-numba-source-statistics.json"
assert numba_path.is_file(),"Missing actual four-worker Numba benchmark"
numba=json.loads(numba_path.read_text())
assert numba["source_default_unseeded_prange_statistical_gate"]=="PASS"
assert numba["ios_source_unseeded_parallel_rng_certified"] is False
for blob,term in [
    (src,"estimatedPeakBytesPerPixel: UInt64 = 104"),
    (src,"diffuseInPlaceMemoryBounded("),
    (conv,"func diffuseInPlaceMemoryBounded("),
    (test,"reference[k].bitPattern != inPlace[k].bitPattern"),
    (device,"5000,height:2600,grain:false"),
    (device,"captureBuild114FourGates"),
    (ui,"onRunBuild114FourGates()"),
    (input_profile,"declaredDepth==16"),
    (raw,"bitsPerComponent: 16"),
    (original,"seed_numba_one_worker(8888)")
]:
    assert term in blob, f"Missing required proof boundary: {term}"
manifest_path=root/"ios/verification/generated-physical-v1.8.22/manifest.json"
assert manifest_path.exists(),"Upstream Python source fixture generation not completed"
manifest=json.loads(manifest_path.read_text())
assert len(manifest["cases"])==4
assert manifest["grain"]["numba_workers"]==1
sha=os.environ.get("GITHUB_SHA","not_in_GitHub_Actions")
report={
    "schema":1,"source_commit":sha,
    "source_hashes":{
        "physical_renderer_sha256":hashlib.sha256(src.encode()).hexdigest(),
        "inplace_dir_sha256":hashlib.sha256(conv.encode()).hexdigest(),
    },
    "certification_gates":[
        {"name":"13MP source optical",
         "ci_status":"inplace_source_104Bpx_and_7_case_bitwise_regression",
         "required_real_device":"5000x2600 measured RSS/Jetsam with no-grain baseline; extra feature combinations separate",
         "fully_certified":False},
        {"name":"Python original whole-image",
         "ci_status":"4_original_small_sRGB_images_all_12_stage_Python_tapes_retained",
         "required_real_device":"independent 1/2/13MP Python complete output references and complete parameter-set parity",
         "fully_certified":False},
        {"name":"RAW/16-bit/ICC",
         "ci_status":"native_16bit_egress_ingress_and_ICC_container_regressions",
         "required_real_device":"real camera RAF/DNG, sensor->spectral source, 16-bit + metadata and original rawpy output parity",
         "fully_certified":False},
        {"name":"Default multiworker Numba prange",
         "ci_status":"actual_original_four_unseeded_worker_moments_pass",
         "required_real_device":"Swift per-worker statistical and seed lifecycle equivalence, distinct from bit-replay",
         "fully_certified":False}
    ],
    "policy":"Four separate PASS results required before lifting any NOT CERTIFIED label. Missing proofs are not auto-passed by a successful IPA build."
}
out=root/"ios/build/release/build114-four-gate-certification-ledger.json"
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n")
print("PASS Build114 four certification gate boundaries and source fingerprints:",out)
print("NOT CERTIFIED remaining cross-device/reference scopes")
