#!/usr/bin/env python3
"""Stage verbatim upstream Spektrafilm spectral profiles into the iOS app.

The manifest is derived from the checked-in upstream JSON; no film colors,
spectral measurements, curves or names are invented here. Stdlib only.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src" / "spektrafilm" / "data" / "profiles"
DEST = ROOT / "ios" / "SpektraFilmPort" / "Resources"
PROFILE_DEST = DEST / "profiles"
LICENSE_DEST = DEST / "licenses"


def stage() -> dict:
    files = sorted(SOURCE.glob("*.json"))
    if len(files) < 20:
        raise RuntimeError(f"Too few upstream measured profiles: {len(files)}")

    PROFILE_DEST.mkdir(parents=True, exist_ok=True)
    LICENSE_DEST.mkdir(parents=True, exist_ok=True)
    for stale in PROFILE_DEST.glob("*.json"):
        stale.unlink()

    entries = []
    for path in files:
        raw = path.read_bytes()
        document = json.loads(raw)
        info = document["info"]
        metadata = document["metadata"]
        samples = document["data"]["wavelengths"]

        if not isinstance(samples, list) or len(samples) < 60:
            raise ValueError(f"{path.name}: invalid measured wavelength series")
        if not all(isinstance(x, (int, float)) for x in samples):
            raise ValueError(f"{path.name}: nonnumeric wavelengths")
        if samples != sorted(samples):
            raise ValueError(f"{path.name}: wavelengths are not sorted")
        if info["stock"] != path.stem:
            raise ValueError(f"{path.name}: stock/file ID mismatch")
        if not info.get("name") or not info.get("support"):
            raise ValueError(f"{path.name}: incomplete profile metadata")
        if len(document["data"]["log_sensitivity"]) != len(samples):
            raise ValueError(f"{path.name}: sensitivity / wavelength mismatch")

        # This preserves every measured numeric value and the upstream license.
        shutil.copyfile(path, PROFILE_DEST / path.name)
        entries.append({
            "id": info["stock"],
            "name": info["name"],
            "medium": info["support"],
            "stage": info["stage"],
            "polarity": info["type"],
            "usage": info["use"],
            "channelModel": info["channel_model"],
            "targetPrint": info.get("target_print"),
            "referenceIlluminant": info.get("reference_illuminant", ""),
            "viewingIlluminant": info.get("viewing_illuminant", ""),
            "wavelengthCount": len(samples),
            "filename": path.name,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "profileVersion": metadata.get("version", ""),
            "license": metadata.get("license", ""),
        })

    for title in ("LICENSE", "SPEKTRAFILM_LICENSE.txt", "CITATION.cff"):
        shutil.copyfile(ROOT / title, LICENSE_DEST / title)

    catalog = {
        "schemaVersion": 1,
        "sourceRepository": "andreavolpato/spektrafilm",
        "sourceDirectory": "src/spektrafilm/data/profiles",
        "profiles": entries,
    }
    (PROFILE_DEST / "index.json").write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Staged {len(entries)} unmodified spectral profiles")
    print("Measured filming stock:",
          sum(p["medium"] == "film" and p["stage"] == "filming" for p in entries))
    print("Measured paper:",
          sum(p["medium"] == "paper" and p["stage"] == "printing" for p in entries))
    return catalog


if __name__ == "__main__":
    stage()
