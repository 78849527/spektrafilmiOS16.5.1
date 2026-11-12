#!/usr/bin/env python3
"""Create v0.3 measured Portra400+Portra Endura spectral arrays as Swift source.

Only selected original measured numeric fields are embedded: no folder
resources, no scripts in app bundle. Input remains unmodified upstream JSON.
The native v0.3 renderer is an explicitly simplified spectral approximation
rather than a full parity port of the Spektrafilm Python rendering pipeline.
"""
import base64
import hashlib
import json
import math
import struct
from pathlib import Path

root = Path(__file__).resolve().parents[2]
profile_root = root / "src/spektrafilm/data/profiles"
target = root / "ios/SpektraFilmPort/GeneratedSpectralData.swift"
names = ["kodak_portra_400", "kodak_portra_endura"]

def flatten(key, value, expected):
    flat = []
    for row in value:
        values = row if isinstance(row, list) else [row]
        for item in values:
            if item is not None:
                item = float(item)
                if not math.isfinite(item):
                    raise ValueError(f"Invalid {key}: non-finite number")
            flat.append(0.0 if item is None else item)
    if len(flat) != expected:
        raise ValueError(f"{key}: expected {expected} floats, got {len(flat)}")
    raw = struct.pack("<" + "f" * len(flat), *flat)
    return base64.b64encode(raw).decode("ascii")

profile_fields = [
    ("log_sensitivity", 81 * 3),
    ("channel_density", 81 * 3),
    ("base_density", 81),
    ("log_exposure", 256),
    ("density_curves", 256 * 3),
]
lines = [
    "// GENERATED from original CC BY-SA 4.0 measured profiles.",
    "// Source: andreavolpato/spektrafilm src/spektrafilm/data/profiles.",
    "// Original full licence in SPEKTRAFILM_LICENSE.txt at repository root.",
    "// Float32 rounding only; nil spectral values are replaced with 0.",
    "// Simplified native spectral calculations, NOT a full Python-port parity claim.",
    "enum GeneratedSpectralData {",
]
for name in names:
    data = (profile_root / f"{name}.json").read_bytes()
    obj = json.loads(data)
    assert obj["info"]["stock"] == name
    sample = obj["data"]["wavelengths"]
    assert sample == list(range(380, 781, 5)), f"{name}: wavelength grid mismatch"
    key = "film" if name == names[0] else "paper"
    lines.append(f'    static let {key}SHA256 = "{hashlib.sha256(data).hexdigest()}"')
    for field, expected in profile_fields:
        encoded = flatten(field, obj["data"][field], expected)
        lines.append(f'    static let {key}_{field} = "{encoded}"')
lines.append("}")
target.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Generated {target.name}, {target.stat().st_size} bytes, 2 unchanged-source digests")
