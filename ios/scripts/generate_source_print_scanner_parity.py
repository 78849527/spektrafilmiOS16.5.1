#!/usr/bin/env python3
"""Original Python printing-medium DENSITY -> scanner RGB stage truth.

This deliberately starts *after* paper development. Reuses AST-loaded
original upstream source functions, not a fake native-specific scanner.
Both paper and motion-print stocks are scanned under their original D50
or Kinoton 75P viewing illuminant, with reference black/white and glare
disabled and the upstream optional ACES RGC gamut path selected. This
does NOT certify negative-to-paper H-D fitting, RAW, grain or full images.
"""
from __future__ import annotations
import hashlib
import json
from pathlib import Path

import colour
import numpy as np
from opt_einsum import contract
from generate_source_rgb_parity import (
    ROOT, PROFILES, STANDARD_OBSERVER_CMFS, original_functions,
)

F = original_functions()
compute_density_spectral = F["compute_density_spectral"]
density_to_light = F["density_to_light"]
standard_illuminant = F["standard_illuminant"]
compress_rgb_aces_rgc = F["compress_rgb_aces_rgc"]
OUTPUT = ROOT / "ios/SpektraFilmPort/GeneratedSourcePrintScannerReference.swift"


def swift(values):
    values = np.asarray(values, dtype=np.float64).ravel()
    assert np.isfinite(values).all(), "Source print scan nonfinite"
    return "[" + ",".join(format(float(x), ".17g") for x in values) + "]"


def source_scan_print(profile, densities):
    dye = np.asarray(profile["data"]["channel_density"], dtype=np.float64)
    base = np.asarray(profile["data"]["base_density"], dtype=np.float64)
    source = np.asarray(
        standard_illuminant(profile["info"]["viewing_illuminant"]),
        dtype=np.float64,
    )
    cie = np.asarray(STANDARD_OBSERVER_CMFS[:], dtype=np.float64)
    assert dye.shape == (81, 3) and base.shape == (81,)
    norm = np.sum(source * cie[:, 1])
    # Printing/ScanningStage's ORIGINAL NumPy functions. Any source
    # NaN dye at a wavelength means zero transmitted light, not zero D.
    spectral = compute_density_spectral(dye, densities[None, :, :], base)
    light = density_to_light(spectral, source)
    xyz = contract("ijk,kl->ijl", light, cie) / norm
    xyz = 10.0 ** np.log10(np.fmax(xyz, 0.0) + 1e-10)
    white = contract("k,kl->l", source, cie) / norm
    viewing_xy = colour.XYZ_to_xy(white)
    linear = colour.XYZ_to_RGB(
        xyz, colourspace="sRGB", illuminant=viewing_xy,
        apply_cctf_encoding=False,
    )
    compressed = compress_rgb_aces_rgc(
        linear, threshold=0.0, limit=1.0, power=6.0
    )
    encoded = colour.RGB_to_RGB(
        compressed, "sRGB", "sRGB",
        apply_cctf_decoding=False, apply_cctf_encoding=True,
    )
    return xyz[0], linear[0], compressed[0], encoded[0]


def main():
    media = sorted(
        p for p in PROFILES.glob("*.json")
        if json.loads(p.read_text(encoding="utf-8"))["info"]["stage"]
        == "printing"
    )
    assert len(media) == 8
    lines = [
        "// Original Python printing-medium density -> scanner only.",
        "// Stage scoped: no paper exposure/develop/RAW/grain/full image.",
        "enum GeneratedSourcePrintScannerReference {",
        "    struct Case {",
        "        let medium: String",
        "        let density: [Double]",
        "        let sourceXYZ: [Double]",
        "        let sourceLinearRGB: [Double]",
        "        let sourceCompressedRGB: [Double]",
        "        let sourceEncodedRGB: [Double]",
        "    }",
        '    static let sourceScanningSHA256 = "' + hashlib.sha256(
            (ROOT / "src/spektrafilm/runtime/stages/scanning.py").read_bytes()
        ).hexdigest() + '"',
        "    static let cases: [Case] = [",
    ]
    total = 0
    for path in media:
        p = json.loads(path.read_text(encoding="utf-8"))
        medium = p["info"]["stock"]
        maxima = np.nanmax(np.asarray(
            p["data"]["density_curves"], dtype=np.float64
        ), axis=0)
        # The iOS production path clamps encoded RGB to display 0..1.
        # For numerical equivalence of the UNCLIPPED source ACES option,
        # select test vectors already within that interval. Skipped OOG
        # candidates are not hidden passes: counts are asserted below.
        candidates = np.stack([
            maxima * np.array([t, t, t])
            for t in np.linspace(0.08, 0.98, 25)
        ], axis=0)
        xyz, linear, compressed, encoded = source_scan_print(p, candidates)
        chosen = []
        for i in range(len(candidates)):
            if (np.all(np.isfinite(encoded[i])) and
                    np.all(encoded[i] >= 0) and
                    np.all(encoded[i] <= 1)):
                chosen.append(i)
        assert len(chosen) >= 3, (
            f"Not enough source in-gamut paper scan samples: {medium}, "
            f"got {len(chosen)}; cannot claim scanner RGB parity"
        )
        # Three separated sample densities per original print medium.
        picks = [chosen[0], chosen[len(chosen)//2], chosen[-1]]
        assert len(set(picks)) == 3
        for idx in picks:
            lines.extend([
                "        Case(",
                f"            medium: {json.dumps(medium)},",
                f"            density: {swift(candidates[idx])},",
                f"            sourceXYZ: {swift(xyz[idx])},",
                f"            sourceLinearRGB: {swift(linear[idx])},",
                f"            sourceCompressedRGB: {swift(compressed[idx])},",
                f"            sourceEncodedRGB: {swift(encoded[idx])}",
                "        ),",
            ])
            total += 1
    assert total == 24
    lines.extend(["    ]", "}"])
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("PASS: original Python print-medium scanner truth — 8 media x 3 in-gamut densities = 24 cases / 72 RGB channels")
    print("Scope: already-developed print density -> XYZ/linear sRGB/ACES/sRGB only; not full RAW->negative->print.")


if __name__ == "__main__":
    main()
