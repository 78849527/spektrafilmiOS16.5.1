#!/usr/bin/env python3
"""Build77 04: independent original-JSON byte manifest for Swift stock audit.

Read pinned upstream JSON, NOT the generated Swift payload or its generator.
The native Swift test compares every embedded F32/F64 array, null mask, and
stock identity with these independently recomputed source-side SHA256 values.
Passing proves payload bytes only, not optical algorithm or device parity.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE_TREE = "fa9262d2440903262dd302b52739162c939e153e"
UPSTREAM_SHA = "3bb2c2d2801ff68b92019cf1dbcbb133d60832bc"
SPECS = (
    ("log_sensitivity", "logSensitivity", "sourceLogSensitivityF64", 243),
    ("channel_density", "channelDensity", "sourceChannelDensityF64", 243),
    ("base_density", "baseDensity", "sourceBaseDensityF64", 81),
    ("log_exposure", "logExposure", "sourceLogExposureF64", 256),
    ("density_curves", "densityCurves", "sourceDensityCurvesF64", 768),
    ("density_curves_layers", "densityCurvesLayers", "sourceDensityCurvesLayersF64", 2304),
)


def require(ok: bool, reason: str) -> None:
    if not ok:
        raise ValueError(reason)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def flatten(value: object) -> list[float | None]:
    if isinstance(value, list):
        return [item for x in value for item in flatten(x)]
    require(value is None or (
        isinstance(value, (float, int)) and not isinstance(value, bool)
        and math.isfinite(value)
    ), "Malformed original profile numeric sample")
    return [None if value is None else float(value)]


def numeric_bytes(values: object, count: int, fmt: str) -> bytes:
    flat = flatten(values)
    require(len(flat) == count, f"Expected {count} numbers, got {len(flat)}")
    return struct.pack("<" + fmt * count,
                       *(0.0 if value is None else value for value in flat))


def validity(values: object, count: int) -> bytes:
    flat = flatten(values)
    require(len(flat) == count, "Bad original validity mask length")
    return bytes(int(item is not None) for item in flat)


def generate() -> dict:
    actual = subprocess.run(
        ["git", "rev-parse", "HEAD:src/spektrafilm/data/profiles"],
        check=True, capture_output=True, text=True, cwd=ROOT
    ).stdout.strip()
    require(actual == SOURCE_TREE,
            f"Pinned original profile tree changed: {actual}")
    paths = sorted((ROOT / "src/spektrafilm/data/profiles").glob("*.json"))
    require(len(paths) == 28, "Missing original 28 profiles")
    profiles = []
    all_ids: set[str] = set()
    filming = printing = 0
    for path in paths:
        raw = path.read_bytes()
        profile = json.loads(raw)
        data, info = profile["data"], profile["info"]
        stock = info["stock"]
        require(stock == path.stem and stock not in all_ids,
                f"Duplicate/mismatched original stock {stock}")
        all_ids.add(stock)
        stage = info["stage"]
        require(stage in ("filming", "printing"), f"Invalid stock stage {stock}")
        filming += int(stage == "filming")
        printing += int(stage == "printing")
        require(data["wavelengths"] == list(range(380, 781, 5)),
                f"Unexpected wavelength axis {stock}")
        fields: dict[str, str] = {}
        source_payload = bytearray()
        for original, mobile, precise, count in SPECS:
            if original not in data:
                require(original == "density_curves_layers" and stage == "printing",
                        f"Missing original measurement {stock}/{original}")
                continue
            require(original != "density_curves_layers" or stage == "filming",
                    f"Unexpected nine-layer field on paper {stock}")
            f32 = numeric_bytes(data[original], count, "f")
            f64 = numeric_bytes(data[original], count, "d")
            fields[mobile] = sha(f32)
            fields[precise] = sha(f64)
            source_payload.extend(f64)
        dye = data["channel_density"]
        base = data["base_density"]
        require(len(dye) == 81 and len(base) == 81, "Invalid scanner dye/base")
        masks = {
            "baseValidWavelengths": validity(base, 81),
            "sensitivityValidSamples": validity(data["log_sensitivity"], 243),
            "scannerValidWavelengths": bytes(
                int(base[i] is not None and all(x is not None for x in dye[i]))
                for i in range(81)
            )
        }
        require(all(any(mask) for mask in masks.values()),
                f"Original missing-wavelength masks invalid {stock}")
        profiles.append({
            "stock": stock, "stage": stage,
            "support": info["support"], "polarity": info["type"],
            "reference_illuminant": info["reference_illuminant"],
            "viewing_illuminant": info["viewing_illuminant"],
            "json_sha256": sha(raw),
            "source_payload_sha256": sha(source_payload),
            "fields": fields,
            "masks": {key: sha(value) for key, value in masks.items()},
        })
    require((filming, printing) == (20, 8),
            "Original stock family counts changed")
    return {
        "source_sha": UPSTREAM_SHA,
        "profile_tree_sha": SOURCE_TREE,
        "evidence": "ORIGINAL_JSON_PAYLOAD_ONLY_NOT_NUMERICAL_STAGE_PARITY",
        "profiles": profiles,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--output", required=True, type=Path)
    args = p.parse_args()
    manifest = generate()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8"
    )
    print("Build77 independent upstream 28-stock F64/F32/null-mask manifest PASS "
          "(not iPhoneOS optical equivalence)")


if __name__ == "__main__":
    main()
