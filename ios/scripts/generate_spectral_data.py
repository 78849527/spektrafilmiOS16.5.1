#!/usr/bin/env python3
"""Embed all 28 upstream Spektrafilm measured materials in Swift (iOS16.5.1).

Important classification: 20 exposure films (16 negative, 4 positive),
6 photographic papers and 2 colour motion-picture print stocks. All original
numeric fields are copied as Float32; invalid/null spectral measurements are
represented as zeros only where upstream np.nan_to_num would do so.
The original 200KB JSONs remain checked in upstream, but are not bundled.
"""
from __future__ import annotations
import base64
import hashlib
import json
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src/spektrafilm/data/profiles"
DEST = ROOT / "ios/SpektraFilmPort/GeneratedSpectralData.swift"
FIELDS = (
    ("log_sensitivity", 243),
    ("channel_density", 243),
    ("base_density", 81),
    ("log_exposure", 256),
    ("density_curves", 768),
)
Q = lambda s: json.dumps(str(s), ensure_ascii=False)


def to_f32(name: str, field: str, values, expected: int) -> str:
    flat = []
    for row in values:
        for elem in (row if isinstance(row, list) else [row]):
            if elem is None:
                flat.append(0.0)
            else:
                value = float(elem)
                if not math.isfinite(value):
                    raise ValueError(f"Nonfinite {name} / {field}")
                flat.append(value)
    if len(flat) != expected:
        raise ValueError(f"Bad size {name}/{field} {len(flat)} != {expected}")
    return base64.b64encode(struct.pack("<" + "f" * expected, *flat)).decode("ascii")


def main() -> None:
    paths = sorted(SRC.glob("*.json"))
    if len(paths) != 28:
        raise ValueError(f"Expected exact original 28 profiles; got {len(paths)}")
    originals = []
    for path in paths:
        raw = path.read_bytes()
        doc = json.loads(raw)
        info, data = doc["info"], doc["data"]
        if info["stock"] != path.stem:
            raise ValueError(f"ID mismatch {path}")
        if info["channel_model"] != "color":
            raise ValueError(f"Unexpected non-colour profile: {path.stem}")
        if data["wavelengths"] != list(range(380, 781, 5)):
            raise ValueError(f"Bad 380–780nm spectral axis: {path}")
        if len(data["log_exposure"]) != 256:
            raise ValueError(f"Wrong density response size: {path}")
        if (info["support"], info["stage"]) not in (
            ("film", "filming"), ("film", "printing"), ("paper", "printing")
        ):
            raise ValueError(f"Unexpected stage: {path}")
        originals.append((info, data, raw))
    exposures = [x for x in originals if x[0]["stage"] == "filming"]
    printmedia = [x for x in originals if x[0]["stage"] == "printing"]
    positives = [x for x in exposures if x[0]["type"] == "positive"]
    negatives = [x for x in exposures if x[0]["type"] == "negative"]
    papers = [x for x in printmedia if x[0]["support"] == "paper"]
    printfilm = [x for x in printmedia if x[0]["support"] == "film"]
    assert (len(exposures), len(negatives), len(positives),
            len(papers), len(printfilm)) == (20, 16, 4, 6, 2)
    lines = [
        "// Generated from all 28 original Spektrafilm measured profiles.",
        "// Upstream source and original GPLv3 / profile CC BY-SA notices retained",
        "// under src/spektrafilm and SPEKTRAFILM_LICENSE.txt.",
        "// Spectral arrays: original float64 rounded to Float32; null -> 0.",
        "// This contains ALL measured arrays, not the complete source engine.",
        "enum GeneratedSpectralData {",
        "    struct Record {",
        "        let logSensitivity: String",
        "        let channelDensity: String",
        "        let baseDensity: String",
        "        let logExposure: String",
        "        let densityCurves: String",
        "        let support: String",
        "        let stage: String",
        "        let polarity: String",
        "        let referenceIlluminant: String",
        "        let viewingIlluminant: String",
        "        let sourceSHA256: String",
        "    }",
    ]
    def ids(items):
        return "[" + ", ".join(Q(x[0]["stock"]) for x in items) + "]"
    lines.extend([
        "    static let filmIDs = " + ids(exposures),
        "    static let negativeFilmIDs = " + ids(negatives),
        "    static let positiveFilmIDs = " + ids(positives),
        "    static let paperIDs = " + ids(papers),
        "    static let printFilmIDs = " + ids(printfilm),
        "    static let printMediumIDs = " + ids(printmedia),
        "    static let profiles: [String: Record] = [",
    ])
    for info, data, raw in originals:
        stock = info["stock"]
        encoded = {
            field: to_f32(stock, field, data[field], count)
            for field, count in FIELDS
        }
        fields = [
            ("logSensitivity", encoded["log_sensitivity"]),
            ("channelDensity", encoded["channel_density"]),
            ("baseDensity", encoded["base_density"]),
            ("logExposure", encoded["log_exposure"]),
            ("densityCurves", encoded["density_curves"]),
            ("support", info["support"]),
            ("stage", info["stage"]),
            ("polarity", info["type"]),
            ("referenceIlluminant", info["reference_illuminant"]),
            ("viewingIlluminant", info["viewing_illuminant"]),
            ("sourceSHA256", hashlib.sha256(raw).hexdigest()),
        ]
        lines.append(
            "        " + Q(stock) + ": Record(" +
            ", ".join(f"{k}: {Q(v)}" for k, v in fields) + "),"
        )
    lines.extend(["    ]", "}"])
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"PASS: 28 original measured profiles; {len(negatives)} negative + "
          f"{len(positives)} positive exposure films; "
          f"{len(papers)} papers + {len(printfilm)} motion print stocks")
    print(f"PASS: {len(negatives) * len(printmedia)} negative-print "
          f"pairs and {len(positives)} positive film scans")
    print(f"Generated embedded Swift data: {DEST.stat().st_size} bytes")

if __name__ == "__main__":
    main()
