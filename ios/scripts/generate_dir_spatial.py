#!/usr/bin/env python3
"""Independent NumPy source DIR spatial-inhibition references (Float64).

Using original measured film profiles and original stock-specific matrices,
test the donor->receiver physical optical-density inhibition *before*
Gaussian/exponential diffusion. Source convolution uses NumPy/Numba
reflect-boundary semantics; iOS CoreImage Gaussian is a documented
approximation and separately tested on constant/impulse fields.
"""
import json
from pathlib import Path
import numpy as np
from generate_dir import ROOT, PROFILES, matrix

DEST = ROOT / "ios/SpektraFilmPort/GeneratedDIRSpatialReference.swift"

def array(values):
    return "[" + ", ".join(f"{float(value):.17g}" for value in values) + "]"

def main():
    stocks = [
        "kodak_portra_400", "kodak_vision3_250d",
        "fujifilm_provia_100f", "fujifilm_velvia_100",
    ]
    densities = [
        [0.1, 0.3, 0.6], [0.2, 0.5, 0.8],
        [0.7, 0.25, 0.14], [0.04, 0.08, 0.12],
    ]
    lines = [
        "// Original stock DIR matrix and source NumPy einsum Float64 references.",
        "enum GeneratedDIRSpatialReference {",
        "    struct Vector {",
        "        let stock: String",
        "        let positive: Bool",
        "        let density: [Double]",
        "        let maximum: [Double]",
        "        let inhibition: [Double]",
        "    }",
        "    static let samples: [Vector] = [",
    ]
    total = 0
    for stock in stocks:
        item = json.loads((PROFILES / (stock + ".json")).read_text())
        positive = item["info"]["type"] == "positive"
        curves = np.asarray(item["data"]["density_curves"], dtype=np.float64)
        dmax = (curves - np.min(curves, axis=0)).max(axis=0)
        M = matrix(stock, positive)
        for density in densities:
            actual = np.asarray(density)
            silver = dmax - actual if positive else actual
            inhibition = np.einsum("k,km->m", silver, M)
            assert np.isfinite(inhibition).all()
            lines += [
                "        Vector(",
                f"            stock: {json.dumps(stock)}, positive: {str(positive).lower()},",
                f"            density: {array(actual)}, maximum: {array(dmax)},",
                f"            inhibition: {array(inhibition)}",
                "        ),",
            ]
            total += 1
    lines += ["    ]", "}"]
    DEST.write_text("\n".join(lines) + "\n")
    assert total == 16
    print("PASS: 16 independent source DIR donor/receiver NumPy exposure-inhibition vectors")

if __name__ == "__main__":
    main()
