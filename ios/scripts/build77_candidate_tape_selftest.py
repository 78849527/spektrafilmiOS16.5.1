#!/usr/bin/env python3
"""Build77/05: exercise REAL candidate-tape comparator plumbing, fail closed.

IMPORTANT: candidate bytes in this TEST are copied from Python references,
NOT from an iOS device or compiled Swift. PASS means only that the newly
added mapping/shape/hash/numeric comparison mechanism works. Every synthetic
candidate exists solely inside TemporaryDirectory and is never retained.
"""
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ios/scripts/build77_source_contract.py"
UPSTREAM = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
BASE = ROOT / "build77-evidence"
ALIAS = {
    "rgb_in":"iosInput",
    "rgb_pre":"rgbPre",
    "log_e_film":"logRaw",
    "cmy_film":"density",
    "log_e_print":"paperLogExposure",
    "cmy_print":"paperDevelopedDensity",
    "rgb_out":"iosOutput",
}


def run(ref: Path, cand: Path, expect_success: bool) -> None:
    result = subprocess.run([
        sys.executable, str(SCRIPT), "compare-taps",
        "--reference", str(ref), "--candidate", str(cand),
        "--candidate-mapping", "--atol", "0",
    ], capture_output=True, text=True)
    if (result.returncode == 0) != expect_success:
        raise AssertionError(
            "Comparator accepted a corrupted fixture or rejected a source"
            " self-copy: " + (result.stdout + result.stderr)[-1800:]
        )


def case(label: str, temporary: Path) -> None:
    reference = BASE / label
    source = json.loads((reference/"manifest.json").read_text())
    chosen = {tap: ALIAS[tap] for tap in source["taps"]}
    candidate = temporary/label
    candidate.mkdir()
    observed = []
    for tap, name in chosen.items():
        original = np.load(reference/(tap+".npy"), allow_pickle=False)
        assert original.dtype == np.dtype("<f8")
        path = candidate/(name+".npy")
        shutil.copyfile(reference/(tap+".npy"), path)
        observed.append({
            "name":name, "shape":list(original.shape), "dtype":"<f8",
            "bytes":path.stat().st_size,
            "file_sha256":hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    branch = "direct_scan" if source["scan_film"] else "negative_print"
    mapping = {
        "status":"IOS_CANDIDATE_MAPPING_NOT_PYTHON_NUMERIC_PARITY",
        "source_sha":UPSTREAM,
        "source_to_ios_actual_observer":chosen,
        "source_tap_order":list(source["taps"]),
        "film_branch":branch,
        "float_storage":"<f8",
        "numerically_certified":False,
        "width":int(next(iter(source["taps"].values()))["shape"][1]),
        "height":int(next(iter(source["taps"].values()))["shape"][0]),
    }
    assert len(chosen) == (5 if source["scan_film"] else 7)
    manifest = {
        "status":"IOS_INTERNAL_DIAGNOSTIC_NOT_PYTHON_TAP_PARITY",
        "observations":observed,
    }
    candidate_map = candidate/"candidate-source-tap-mapping.json"
    candidate_manifest = candidate/"manifest.json"
    candidate_map.write_text(json.dumps(mapping))
    candidate_manifest.write_text(json.dumps(manifest))
    run(reference, candidate, True)

    # If an actual value differs, even with a correct file SHA/shape,
    # source-level exact tolerance MUST reject it.
    original_path = candidate/(chosen["rgb_pre"]+".npy")
    original_bytes = original_path.read_bytes()
    changed = np.load(original_path, allow_pickle=False).copy()
    finite = np.flatnonzero(np.isfinite(changed))
    assert finite.size
    changed.flat[int(finite[0])] += 0.1
    np.save(original_path, changed, allow_pickle=False)
    for row in observed:
        if row["name"] == chosen["rgb_pre"]:
            row["file_sha256"] = hashlib.sha256(
                original_path.read_bytes()
            ).hexdigest()
            row["bytes"] = original_path.stat().st_size
    candidate_manifest.write_text(json.dumps(manifest))
    run(reference, candidate, False)

    original_path.write_bytes(original_bytes)
    for row in observed:
        if row["name"] == chosen["rgb_pre"]:
            row["file_sha256"] = hashlib.sha256(original_bytes).hexdigest()
            row["bytes"] = len(original_bytes)
    candidate_manifest.write_text(json.dumps(manifest))
    run(reference, candidate, True)

    mapping["numerically_certified"] = True
    candidate_map.write_text(json.dumps(mapping))
    run(reference, candidate, False)
    mapping["numerically_certified"] = False
    mapping["source_to_ios_actual_observer"]["rgb_pre"] = "../escape"
    candidate_map.write_text(json.dumps(mapping))
    run(reference, candidate, False)
    print(
        "PASS synthetic comparator self-test:", label,
        len(chosen), "stage files; independent numeric perturbation,"
        " false certification and unsafe path all rejected;",
        " NO Swift or iPhone stage equality was tested"
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="build77-mapping-SELFTEST-") as name:
        temporary = Path(name)
        for label in ("negative-print", "direct-scan",
                      "negative-print-diffusion"):
            case(label, temporary)
    print("PASS 3/3 ephemeral harness branch self-tests; NOT source/iOS parity")


if __name__ == "__main__":
    main()
