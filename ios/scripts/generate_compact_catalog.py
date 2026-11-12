#!/usr/bin/env python3
"""Generated minimal Swift metadata from original Spektrafilm profiles, no JSON assets."""
import hashlib
import json
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
source = repo / "src/spektrafilm/data/profiles"
target = repo / "ios/SpektraFilmPort/GeneratedMeasuredProfiles.swift"
files = sorted(source.glob("*.json"))
assert len(files) == 28, f"Expected 28 original profiles, got {len(files)}"

def q(obj):
    return json.dumps(str(obj), ensure_ascii=False)

lines = []
for path in files:
    raw = path.read_bytes()
    d = json.loads(raw)
    info, meta = d["info"], d["metadata"]
    wavelengths = d["data"]["wavelengths"]
    assert info["stock"] == path.stem
    assert len(wavelengths) >= 60
    assert wavelengths == sorted(wavelengths)
    assert len(d["data"]["log_sensitivity"]) == len(wavelengths)
    f = {
       "id": q(info["stock"]),
       "name": q(info["name"]),
       "medium": q(info["support"]),
       "stage": q(info["stage"]),
       "polarity": q(info["type"]),
       "targetPrint": "nil" if info.get("target_print") is None else q(info["target_print"]),
       "wavelengthCount": str(len(wavelengths)),
       "profileVersion": q(meta.get("version", "")),
       "sha256": q(hashlib.sha256(raw).hexdigest())
    }
    lines.append("        MeasuredStock(" + ", ".join(f"{k}: {v}" for k,v in f.items()) + "),")

target.write_text(
    "// Generated from Spektrafilm sources (Andrea Volpato); metadata only.\n"
    "// Source license: root SPEKTRAFILM_LICENSE.txt. No spectral simulation.\n"
    "enum GeneratedMeasuredProfiles {\n"
    "    static let entries: [MeasuredStock] = [\n"
    + "\n".join(lines) + "\n"
    "    ]\n"
    "}\n",
    encoding="utf-8"
)
print(f"Generated {len(lines)} stock metadata records ({target.stat().st_size} bytes)")
