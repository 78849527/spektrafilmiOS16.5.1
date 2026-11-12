#!/usr/bin/env python3
"""Verify staged profiles are byte-for-byte copies of upstream source."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / "src/spektrafilm/data/profiles"
dest = root / "ios/SpektraFilmPort/Resources/profiles"
catalog = json.loads((dest / "index.json").read_text(encoding="utf-8"))
entries = catalog["profiles"]

assert catalog["schemaVersion"] == 1
assert len(entries) == len(list(source.glob("*.json")))
assert len(entries) >= 20
assert len({p["id"] for p in entries}) == len(entries)

film = [p for p in entries if p["medium"] == "film" and p["stage"] == "filming"]
paper = [p for p in entries if p["medium"] == "paper" and p["stage"] == "printing"]
assert film and paper

for item in entries:
    filename = item["filename"]
    upstream = (source / filename).read_bytes()
    bundled = (dest / filename).read_bytes()
    assert upstream == bundled, filename
    assert hashlib.sha256(upstream).hexdigest() == item["sha256"]
    source_json = json.loads(upstream)
    assert item["id"] == source_json["info"]["stock"]
    assert item["wavelengthCount"] == len(source_json["data"]["wavelengths"])

assert any(p["id"] == "kodak_portra_400" for p in film)
assert any(p["id"] == "kodak_portra_endura" for p in paper)
print(f"PASS: {len(film)} filming stocks, {len(paper)} papers, "
      f"{len(entries)} unchanged original spectral profiles")
