#!/usr/bin/env python3
"""Fail-closed v1.8 certification. Compilation or visual similarity cannot pass.

A real-device record is REQUIRED in addition to real Metal GPU tests.
Do not set a status to passed without verified original Python outputs,
recorded hardware measurements, source SHA and full-image comparisons.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

CERT = Path("ios/verification/v1.8-precision-certification.json")
MANDATORY = (
    "original_poisson_binomial_rng",
    "original_float_and_order",
    "nine_layer_grain",
    "dye_cloud_and_iir",
    "microstructure",
    "edge_and_tile",
    "full_image_density",
    "full_image_rgb",
    "ios_16_5_1_hardware",
    "photos_full_resolution_export",
)
def main():
    sha = os.environ.get("GITHUB_SHA")
    if not sha:
        sha = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True).strip()
    if not CERT.is_file():
        raise SystemExit(
            "NOT CERTIFIED: real-iPhone original NumPy + full-image parity "
            "evidence missing; never promote an unverified test IPA."
        )
    evidence = json.loads(CERT.read_text(encoding="utf-8"))
    assert evidence.get("commit_sha") == sha, (
        "Certificate belongs to a different commit; retest the binary."
    )
    assert evidence.get("ios_target") == "16.5.1", "wrong minimum target"
    assert evidence.get("device_class") == "physical_iphone", (
        "Intel macOS virtual GPU cannot certify physical hardware."
    )
    for key in MANDATORY:
        entry = evidence.get("checks", {}).get(key, {})
        assert entry.get("status") == "numerically_equivalent", (
            f"NOT CERTIFIED: {key} is missing or not numerically equivalent"
        )
        assert entry.get("source_reference") and entry.get("measured_report"), (
            f"NOT CERTIFIED: {key} lacks both source and measured evidence"
        )
        for field in ("source_reference", "measured_report"):
            p = Path(entry[field])
            assert p.is_file() and p.stat().st_size > 0, (
                f"NOT CERTIFIED: evidence file absent/empty: {p}"
            )
    print("PASS: full v1.8 source+device certification records verified")
if __name__ == "__main__":
    main()
