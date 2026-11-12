#!/usr/bin/env python3
"""Independent original-Python regression: NaN in ANY CMY dye = zero light."""
import base64
import json
import re
from pathlib import Path
import numpy as np
from generate_source_rgb_parity import (PROFILES, STANDARD_OBSERVER_CMFS,
                                       source_scan, standard_illuminant)

ROOT = Path(__file__).resolve().parents[2]
GENERATED = ROOT / "ios/SpektraFilmPort/GeneratedSpectralData.swift"

def generated_masks(field: str = "scannerValidWavelengths", count: int = 81):
    output = {}
    for line in GENERATED.read_text(encoding="utf-8").splitlines():
        if ": Record(" not in line:
            continue
        stock = json.loads(line.strip().split(": Record(", 1)[0])
        m = re.search(re.escape(field) + r': "([^"]+)"', line)
        assert m, f"Missing generated scanner mask: {stock}"
        bits = base64.b64decode(m.group(1), validate=True)
        assert len(bits) == count and set(bits) <= {0, 1}, (stock, field)
        output[stock] = np.asarray(list(bits), dtype=bool)
    return output

def main():
    masks = generated_masks()
    base_masks = generated_masks("baseValidWavelengths", 81)
    sensitivity_masks = generated_masks("sensitivityValidSamples", 243)
    paths = sorted(PROFILES.glob("*.json"))
    assert len(masks) == len(base_masks) == len(sensitivity_masks) == len(paths) == 28
    missing = {}
    for path in paths:
        p = json.loads(path.read_text(encoding="utf-8"))
        dye = np.asarray(p["data"]["channel_density"], dtype=np.float64)
        base = np.asarray(p["data"]["base_density"], dtype=np.float64)
        expected = np.isfinite(base) & np.all(np.isfinite(dye), axis=1)
        sensitivity = np.asarray(p["data"]["log_sensitivity"], dtype=np.float64)
        assert expected.shape == (81,) and sensitivity.shape == (81, 3)
        assert np.array_equal(expected, masks[path.stem]), path.stem
        assert np.array_equal(np.isfinite(base), base_masks[path.stem]), path.stem + " base"
        assert np.array_equal(np.isfinite(sensitivity).ravel(), sensitivity_masks[path.stem]), path.stem + " sensitivity"
        invalid = int((~expected).sum())
        if invalid:
            missing[path.stem] = invalid
    for stock in ("fujifilm_provia_100f", "fujifilm_velvia_100"):
        assert missing.get(stock, 0) > 10
    print(f"PASS: 28 source NaN scanner/base/sensitivity masks (81/81/243 samples each); invalid wavelengths: {missing}")

    cie = np.asarray(STANDARD_OBSERVER_CMFS[:], dtype=np.float64)
    max_error = 0.0
    old_bug = 0.0
    for stock in ("fujifilm_provia_100f", "fujifilm_velvia_100"):
        p = json.loads((PROFILES / (stock + ".json")).read_text(encoding="utf-8"))
        dye = np.nan_to_num(np.asarray(p["data"]["channel_density"], dtype=np.float64), nan=0.)
        base = np.nan_to_num(np.asarray(p["data"]["base_density"], dtype=np.float64), nan=0.)
        illum = np.asarray(standard_illuminant(p["info"]["viewing_illuminant"]), dtype=np.float64)
        normalizer = np.sum(illum * cie[:, 1])
        for density in ([0., 0., 0.], [.24, .42, .63], [1.2, 1.5, 2.2]):
            d = np.asarray(density, dtype=np.float64)
            truth = source_scan(p, d[None, :])[0][0]
            absorb = base + np.sum(dye * d[None, :], axis=1)
            light = 10. ** (-absorb) * illum
            old_xyz = np.sum(light[:, None] * cie, axis=0) / normalizer
            light[~masks[stock]] = 0.
            masked_xyz = np.sum(light[:, None] * cie, axis=0) / normalizer + 1e-10
            err = float(np.max(np.abs(truth - masked_xyz)))
            max_error = max(max_error, err)
            old_bug = max(old_bug, float(np.max(np.abs(truth - old_xyz))))
            assert err < 1e-9, (stock, d, truth, masked_xyz, err)
    assert old_bug > 1e-5, "Original zero-absorbance defect not exposed"
    print(f"PASS: original Float64 XYZ masked integration; max error={max_error:.12g}; old defect={old_bug:.12g}")
    print("Scope: source reversal scanner, NOT full-image/RAW/RNG certification.")

if __name__ == "__main__":
    main()
