#!/usr/bin/env python3
"""Original Spektrafilm three-sublayer density interpolation and variance references.

Reference uses source model/density_curves.py interp_density_cmy_layers
and model/grain.py apply_grain_to_density_layers, evaluated with Float64
NumPy to independently check the Swift GPU model's measured sublayer
means and exact Poisson/binomial first/second moments.
"""
from __future__ import annotations

import json
import numpy as np
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "src/spektrafilm/data/profiles"
DEST = ROOT / "ios/SpektraFilmPort/GeneratedSublayerGrainReference.swift"

PIXEL_UM = 9.0
STOCKS = [
    "kodak_portra_400", "kodak_vision3_250d",
    "fujifilm_provia_100f", "fujifilm_velvia_100",
]
CHANNEL_SCALE = np.array([1.6, 1.6, 3.2], dtype=np.float64)
SUB_SCALE = np.array([2.0, 1.0, 0.5], dtype=np.float64)
D_MIN = np.array([0.03, 0.03, 0.03], dtype=np.float64)
UNIFORMITY = np.array([0.97, 0.99, 0.97], dtype=np.float64)


def vector(a):
    return "[" + ",".join(format(float(x), ".17g") for x in np.ravel(a)) + "]"


def produce():
    lines = [
        "// Generated from original Spektrafilm grain.py + measured 256x3x3 H-D.",
        "enum GeneratedSublayerGrainReference {",
        "    struct Vector {",
        "        let stock: String",
        "        let positive: Bool",
        "        let total: [Double]",
        "        let layers: [Double]",
        "        let layerRawMaximum: [Double]",
        "        let mean: [Double]",
        "        let variance: [Double]",
        "    }",
        f"    static let pixelUM: Double = {PIXEL_UM}",
        "    static let samples: [Vector] = [",
    ]
    count = 0
    for stock in STOCKS:
        record = json.loads((DATA / (stock + ".json")).read_text())
        data = record["data"]
        positive = record["info"]["type"] == "positive"
        measured = np.asarray(data["density_curves"], dtype=np.float64)
        normalized = measured - np.min(measured, axis=0)
        measured_layers = np.asarray(data["density_curves_layers"],
                                     dtype=np.float64)
        assert measured_layers.shape == (256, 3, 3)
        maxima = np.max(measured_layers, axis=0)
        fraction = maxima/np.sum(maxima, axis=0)[None, :]
        dmin_layers = fraction*D_MIN[None, :]
        full_max = maxima+dmin_layers
        n = (PIXEL_UM**2)*fraction/(
            0.2*CHANNEL_SCALE[None, :]*SUB_SCALE[:, None]
        )
        for f in [0.1, 0.35, 0.65, 0.9]:
            # Mean CMY density is stock-specific and reversals are inverted.
            total = f*np.max(normalized, axis=0)
            out = np.zeros((3, 3), dtype=np.float64)
            for channel in range(3):
                sign = -1 if positive else 1
                for layer in range(3):
                    out[layer, channel] = np.interp(
                        sign*total[channel],
                        sign*normalized[:, channel],
                        measured_layers[:, layer, channel],
                    )
            p = np.clip((out+dmin_layers)/full_max,1e-6,1-1e-6)
            saturation = 1-p*UNIFORMITY[None,:]*(1-1e-6)
            variance = np.sum(full_max**2*p*saturation/n, axis=0)
            mean = np.sum(full_max*p, axis=0)-D_MIN
            assert np.isfinite(variance).all() and np.all(variance > 0)
            lines += [
                "        Vector(",
                f"            stock: {json.dumps(stock)}, positive: {str(positive).lower()},",
                f"            total: {vector(total)}, layers: {vector(out)},",
                f"            layerRawMaximum: {vector(maxima)},",
                f"            mean: {vector(mean)}, variance: {vector(variance)}",
                "        ),"
            ]
            count += 1
    lines += ["    ]", "}"]
    DEST.write_text("\n".join(lines)+"\n",encoding="utf-8")
    assert count == 16
    print("PASS: 16 original NumPy 3x3 grain sublayer interpolation and Poisson/Binomial moment references")


if __name__ == "__main__":
    produce()
