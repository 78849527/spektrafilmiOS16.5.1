#!/usr/bin/env python3
"""Embed all 28 upstream Spektrafilm measured materials in Swift (iOS16.5.1).

Important classification: 20 exposure films (16 negative, 4 positive),
6 photographic papers and 2 colour motion-picture print stocks. Fast/mobile profile values retain legacy Float32 packing exactly, while
the opt-in original physical pixel engine gets a SEPARATE bit-exact Float64
copy of every upstream JSON numeric field. Original None values use zero
plus a separate exact validity mask, so original density_to_light() still
sets missing-wavelength transmitted light to ZERO. Never mix mobile F32
profile values into exact source per-pixel material evaluation.
Original JSON measurements remain checked in upstream, not bundled.
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
    # Measured 256 x 3 emulsion sublayers x 3 CMY components.
    # Only the 20 capture-film profiles contain these curves.
    ("density_curves_layers", 2304),
)
Q = lambda s: json.dumps(str(s), ensure_ascii=False)


def to_bytes(name: str, field: str, values, expected: int, fmt: str) -> str:
    flat = []
    def gather(tree):
        if isinstance(tree, list):
            for item in tree:
                gather(item)
            return
        if tree is None:
            flat.append(0.0)
        else:
            value = float(tree)
            if not math.isfinite(value):
                raise ValueError(f"Nonfinite {name} / {field}")
            flat.append(value)
    gather(values)
    if len(flat) != expected:
        raise ValueError(f"Bad size {name}/{field} {len(flat)} != {expected}")
    return base64.b64encode(struct.pack("<" + fmt * expected, *flat)).decode("ascii")

def to_f32(name: str, field: str, values, expected: int) -> str:
    return to_bytes(name, field, values, expected, "f")

def to_f64(name: str, field: str, values, expected: int) -> str:
    return to_bytes(name, field, values, expected, "d")

def scan_validity_mask(stock: str, data: dict) -> str:
    """Original NaN anywhere in CMY dye/base => zero transmission at wavelength."""
    dye, base = data["channel_density"], data["base_density"]
    if len(dye) != 81 or len(base) != 81:
        raise ValueError(f"Invalid source scanner spectral shape: {stock}")
    valid = []
    for i in range(81):
        row = dye[i]
        if not isinstance(row, list) or len(row) != 3:
            raise ValueError(f"Invalid source CMY row: {stock}:{i}")
        valid.append(int(base[i] is not None and all(v is not None for v in row)))
    if not any(valid):
        raise ValueError(f"No source-measured scanner wavelengths for {stock}")
    return base64.b64encode(bytes(valid)).decode("ascii")

def numeric_validity_mask(stock: str, field: str, values, expected: int) -> str:
    """Retain measured None slots independently of Float32 numeric packing."""
    flat = []
    def walk(tree):
        if isinstance(tree, list):
            for value in tree:
                walk(value)
        else:
            flat.append(int(tree is not None))
    walk(values)
    if len(flat) != expected:
        raise ValueError(f"Unexpected {stock} {field} mask length {len(flat)}")
    if not any(flat):
        raise ValueError(f"No valid source spectral samples: {stock} {field}")
    return base64.b64encode(bytes(flat)).decode("ascii")


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
        "// Separate FAST Float32 and ORIGINAL Float64 measured arrays.",
        "// Original JSON NaN/null zero-light masks remain independent.",
        "// Original Float64 arrays are loaded only by opt-in source image mode.",
        "enum GeneratedSpectralData {",
        "    struct Record {",
        "        let logSensitivity: String",
        "        let channelDensity: String",
        "        let baseDensity: String",
        "        let scannerValidWavelengths: String",
        "        let baseValidWavelengths: String",
        "        let sensitivityValidSamples: String",
        "        let logExposure: String",
        "        let densityCurves: String",
        "        let densityCurvesLayers: String",
        "        let sourceLogSensitivityF64: String",
        "        let sourceChannelDensityF64: String",
        "        let sourceBaseDensityF64: String",
        "        let sourceLogExposureF64: String",
        "        let sourceDensityCurvesF64: String",
        "        let sourceDensityCurvesLayersF64: String",
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
            field: (
                to_f32(stock, field, data[field], count)
                if field in data else ""
            )
            for field, count in FIELDS
        }
        source_double = {
            field: (
                to_f64(stock, field, data[field], count)
                if field in data else ""
            )
            for field, count in FIELDS
        }
        fields = [
            ("logSensitivity", encoded["log_sensitivity"]),
            ("channelDensity", encoded["channel_density"]),
            ("baseDensity", encoded["base_density"]),
            ("scannerValidWavelengths", scan_validity_mask(stock, data)),
            ("baseValidWavelengths", numeric_validity_mask(stock, "base_density", data["base_density"], 81)),
            ("sensitivityValidSamples", numeric_validity_mask(stock, "log_sensitivity", data["log_sensitivity"], 243)),
            ("logExposure", encoded["log_exposure"]),
            ("densityCurves", encoded["density_curves"]),
            ("densityCurvesLayers", encoded["density_curves_layers"]),
            ("sourceLogSensitivityF64", source_double["log_sensitivity"]),
            ("sourceChannelDensityF64", source_double["channel_density"]),
            ("sourceBaseDensityF64", source_double["base_density"]),
            ("sourceLogExposureF64", source_double["log_exposure"]),
            ("sourceDensityCurvesF64", source_double["density_curves"]),
            ("sourceDensityCurvesLayersF64", source_double["density_curves_layers"]),
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
    assert all("density_curves_layers" in data and
               len(data["density_curves_layers"]) == 256
               for info, data, _ in exposures)
    print("PASS: 20 measured 256×3×3 sublayer emulsions encoded.")
    print(f"PASS: {len(negatives) * len(printmedia)} negative-print "
          f"pairs and {len(positives)} positive film scans")
    print("PASS: original Float64 bit representation of six measured arrays " +
          "retained separately from unchanged mobile Float32 for all 28 stocks.")
    print(f"Generated embedded Swift data: {DEST.stat().st_size} bytes")

if __name__ == "__main__":
    main()
