#!/usr/bin/env python3
"""Generate compact Swift measured spectra for nine original Spektrafilm stocks.

No large JSON folders are copied into the app. Values are sourced from
unchanged upstream profile JSON; floating point arrays are packed as little-
endian Float32, replacing absent wavelengths (null) with zero, and embedded
as strings in generated Swift. Original JSON SHA-256 is retained per record.
This is a subset of the optical simulation, not the original full renderer.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ROOT / "src/spektrafilm/data/profiles"
TARGET = ROOT / "ios/SpektraFilmPort/GeneratedSpectralData.swift"

FILM_IDS = [
    "kodak_portra_160",
    "kodak_portra_400",
    "kodak_portra_800",
    "kodak_gold_200",
    "kodak_ektar_100",
    "fujifilm_pro_400h",
]
PAPER_IDS = [
    "kodak_portra_endura",
    "kodak_endura_premier",
    "fujifilm_crystal_archive_typeii",
]
FIELDS = [
    ("log_sensitivity", 81 * 3),
    ("channel_density", 81 * 3),
    ("base_density", 81),
    ("log_exposure", 256),
    ("density_curves", 256 * 3),
]


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def encode_float32(source_id: str, key: str, values: list, count: int) -> str:
    flattened = []
    for row in values:
        cells = row if isinstance(row, list) else [row]
        for cell in cells:
            if cell is not None:
                cell = float(cell)
                if not math.isfinite(cell):
                    raise ValueError(f"{source_id} {key}: non-finite field")
            flattened.append(0.0 if cell is None else cell)
    if len(flattened) != count:
        raise ValueError(f"{source_id} {key}: {len(flattened)} vs {count}")
    return base64.b64encode(struct.pack("<" + "f" * count, *flattened)).decode("ascii")


def generate() -> None:
    ids = FILM_IDS + PAPER_IDS
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate measured profile IDs")
    lines = [
        "// AUTO-GENERATED from original Spektrafilm measured spectral profiles.",
        "// Copyright original authors; source licensing in SPEKTRAFILM_LICENSE.txt.",
        "// Data arrays are Float32; null wavelengths -> zero; original SHA256 noted.",
        "// Experimental spectral simulation; not original Hanatos/print parity.",
        "enum GeneratedSpectralData {",
        "    struct Record {",
        "        let logSensitivity: String",
        "        let channelDensity: String",
        "        let baseDensity: String",
        "        let logExposure: String",
        "        let densityCurves: String",
        "        let sourceSHA256: String",
        "    }",
        "    static let filmIDs = [" + ", ".join(map(quote, FILM_IDS)) + "]",
        "    static let paperIDs = [" + ", ".join(map(quote, PAPER_IDS)) + "]",
        "    static let profiles: [String: Record] = [",
    ]
    for stock_id in ids:
        raw = (PROFILES / (stock_id + ".json")).read_bytes()
        document = json.loads(raw)
        info = document["info"]
        data = document["data"]
        if (info["stock"] != stock_id or
            info["channel_model"] != "color" or
            info["type"] != "negative"):
            raise ValueError(f"{stock_id}: only measured color negative supported")
        medium = "film" if stock_id in FILM_IDS else "paper"
        expected_stage = "filming" if medium == "film" else "printing"
        if info["support"] != medium or info["stage"] != expected_stage:
            raise ValueError(f"{stock_id}: film/paper type mismatch")
        if data["wavelengths"] != list(range(380, 781, 5)):
            raise ValueError(f"{stock_id}: wavelength grid mismatch")
        if len(data["log_exposure"]) != 256:
            raise ValueError(f"{stock_id}: expected 256 H-D samples")
        encoded = {
            key: encode_float32(stock_id, key, data[key], count)
            for key, count in FIELDS
        }
        lines.append(
            "        " + quote(stock_id) + ": Record("
            + "logSensitivity: " + quote(encoded["log_sensitivity"]) + ", "
            + "channelDensity: " + quote(encoded["channel_density"]) + ", "
            + "baseDensity: " + quote(encoded["base_density"]) + ", "
            + "logExposure: " + quote(encoded["log_exposure"]) + ", "
            + "densityCurves: " + quote(encoded["density_curves"]) + ", "
            + "sourceSHA256: " + quote(hashlib.sha256(raw).hexdigest())
            + "),"
        )
    lines.extend(["    ]", "}"])
    TARGET.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(
        f"PASS: {len(FILM_IDS)} measured negatives, {len(PAPER_IDS)} papers, "
        f"{len(FILM_IDS) * len(PAPER_IDS)} combinations; "
        f"{TARGET.stat().st_size} bytes of generated Swift."
    )


if __name__ == "__main__":
    generate()
