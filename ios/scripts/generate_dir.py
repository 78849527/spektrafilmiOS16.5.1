#!/usr/bin/env python3
"""Port the ORIGINAL spektrafilm.model.couplers chemical DIR calculation.

This script reproduces:
  spektrafilm.runtime.params_builder._apply_film_specifics
  spektrafilm.model.couplers.compute_dir_couplers_matrix
  spektrafilm.model.couplers.compute_density_curves_before_dir_couplers
  spektrafilm.model.couplers.compute_exposure_correction_dir_couplers
  spektrafilm.model.density_curves.interpolate_exposure_to_density

The spatial diffusion stage of DIR is *disabled* in a colour-cube bake, just
like original debug.lut_mode. This does not claim the full spatial DIR effect.
"""
from __future__ import annotations
import base64
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ROOT / "src/spektrafilm/data/profiles"
DEST = ROOT / "ios/SpektraFilmPort/GeneratedDIRData.swift"

# Exact film-specific default curves in params_builder._apply_film_specifics.
NEG = np.array([
    [0.336, 0.353, 0.302],
    [0.154, 0.319, 0.353],
    [0.168, 0.226, 0.273],
], dtype=np.float64)
POS = np.array([
    [0.12, 0.12, 0.06],
    [0.08, 0.08, 0.06],
    [0.06, 0.06, 0.06],
], dtype=np.float64)
PROVIA = np.array([
    [0.156, 0.156, 0.078],
    [0.104, 0.104, 0.078],
    [0.078, 0.078, 0.078],
], dtype=np.float64)
VELVIA = np.array([
    [0.108, 0.108, 0.054],
    [0.072, 0.072, 0.054],
    [0.054, 0.054, 0.054],
], dtype=np.float64)

def matrix(stock: str, positive: bool) -> np.ndarray:
    if stock == "fujifilm_provia_100f": return PROVIA.copy()
    if stock == "fujifilm_velvia_100": return VELVIA.copy()
    return POS.copy() if positive else NEG.copy()

def prepare_curves(le: np.ndarray, curves: np.ndarray,
                   M: np.ndarray, positive: bool) -> np.ndarray:
    # normalized_density_curves = dc - np.nanmin(dc, axis=0)
    # apply_density_correction_dir_couplers preprocessing (source code).
    silver = np.max(curves, axis=0) - curves if positive else curves.copy()
    correction = silver @ M
    shifted_le = le[:, None] - correction
    result = np.zeros_like(curves)
    for c in range(3):
        if positive:
            result[:, c] = -np.interp(le, shifted_le[:, c], -curves[:, c])
        else:
            result[:, c] = np.interp(le, shifted_le[:, c], curves[:, c])
    return result

def compute(log_rgb, le, normalized, corrected, M, positive):
    pre_density = np.array(
        [np.interp(log_rgb[c], le, normalized[:, c]) for c in range(3)])
    dmax = normalized.max(axis=0)
    silver = dmax - pre_density if positive else pre_density
    corrected_log_rgb = log_rgb - silver @ M
    return np.array([np.interp(corrected_log_rgb[c], le, corrected[:, c])
                     for c in range(3)])

def encode(data):
    x = np.asarray(data, dtype="<f4")
    if not np.isfinite(x).all(): raise ValueError("Nonfinite DIR data")
    return base64.b64encode(x.tobytes()).decode("ascii")

def quote(x):
    return json.dumps(str(x))

def main() -> None:
    lines = [
        "// GENERATED from original Spektrafilm default DIR couplers chemistry.",
        "// Source: model/couplers.py and runtime/params_builder.py.",
        "// No spatial diffusion; original LUT-mode chemistry only.",
        "enum GeneratedDIRData {",
        "    struct Record {",
        "        let correctedCurves: String",
        "        let donorReceiverMatrix: [Double]",
        "        let sourceDensityMax: [Double]",
        "    }",
        "    static let records: [String: Record] = [",
    ]
    refs = []
    count = 0
    for path in sorted(PROFILES.glob("*.json")):
        doc = json.loads(path.read_bytes())
        info, data = doc["info"], doc["data"]
        if info["stage"] != "filming": continue
        stock = info["stock"]
        positive = info["type"] == "positive"
        le = np.asarray(data["log_exposure"], dtype=np.float64)
        curves = np.asarray(data["density_curves"], dtype=np.float64)
        normalized = curves - np.min(curves, axis=0)
        M = matrix(stock, positive)
        corrected = prepare_curves(le, normalized, M, positive)
        # Full 9 coefficients source-donor/receiver order; original NumPy
        # einsum 'ijk,km->ijm' has donor in row, target in column.
        lines.append(f"        {quote(stock)}: Record("
                     f"correctedCurves: {quote(encode(corrected))}, "
                     f"donorReceiverMatrix: ["
                     + ",".join(format(x, ".16g") for x in M.flat)
                     + "], sourceDensityMax: ["
                     + ",".join(format(x, ".16g") for x in normalized.max(axis=0))
                     + "]),")
        if stock in ("kodak_portra_400", "kodak_vision3_250d",
                     "fujifilm_provia_100f", "fujifilm_velvia_100"):
            for x in (np.array([-1.5,-1.0,-0.7]),
                      np.array([-0.55,-0.8,-0.35]),
                      np.array([0.4,0.2,0.15])):
                refs.append((stock,x,compute(x,le,normalized,corrected,M,positive)))
        count += 1
    assert count == 20
    lines.append("    ]")
    for i,(stock,x,y) in enumerate(refs):
        def nums(a):
            return "[" + ",".join(format(float(v), ".17g") for v in a) + "]"
        lines.append(f"    static let referenceStock{i} = {quote(stock)}")
        lines.append(f"    static let referenceLogRaw{i}: [Double] = {nums(x)}")
        lines.append(f"    static let referenceDensity{i}: [Double] = {nums(y)}")
    lines.append("}")
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"PASS: pre-DIR corrected curves and donor/receiver matrices for {count} films")
    print(f"PASS: {len(refs)} original Python DIR reference samples, including reversals")
    print(f"Generated DIR Swift arrays: {DEST.stat().st_size} bytes")

if __name__ == "__main__":
    main()
