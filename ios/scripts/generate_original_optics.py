#!/usr/bin/env python3
"""Build-time reference spectra from the ORIGINAL Spektrafilm Python methods.

Uses colour-science's Mallett 2019 sRGB basis, the stock reference D55,
CIE 1931 2° CMFs, D50 viewing illuminant, original 3400K Schott KG3
enlarger, and Spektrafilm's default CMY (0/65/55) dichroic filtration.

The iOS binary receives compact Float32 lookup arrays as compiled Swift
constants. No Python, large JSON bundle, or runtime colour dependency is
introduced on iOS 16.5.1. Original preprocessing uses float64.
"""
from __future__ import annotations

import base64
import hashlib
import json
import math
import struct
from pathlib import Path

import colour
import numpy as np
from scipy.interpolate import Akima1DInterpolator
from scipy.special import erf

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / "ios/SpektraFilmPort/GeneratedOriginalOptics.swift"
WL = np.arange(380, 781, 5, dtype=np.float64)
SHAPE = colour.SpectralShape(380, 780, 5)


def encoded(values) -> str:
    value = np.asarray(values, dtype=np.float32).ravel()
    if not np.isfinite(value).all():
        raise ValueError("Reference source contains nonfinite spectral values")
    return base64.b64encode(value.astype("<f4").tobytes()).decode("ascii")


def illuminant(name: str) -> np.ndarray:
    # Identical to spektrafilm.model.illuminants.standard_illuminant.
    values = np.asarray(colour.SDS_ILLUMINANTS[name].copy().align(SHAPE).values,
                        dtype=np.float64)
    return values / np.mean(values)


def kg3_filter() -> np.ndarray:
    path = (ROOT / "src/spektrafilm/data/filters/heat_absorbing/"
            "schott/KG3.csv")
    values = np.loadtxt(path, delimiter=",", dtype=np.float64)
    unique = np.unique(values[:, 0], return_index=True)[1]
    return np.asarray(Akima1DInterpolator(
        values[unique, 0], values[unique, 1])(WL), dtype=np.float64)


def default_dichroic() -> np.ndarray:
    # Exact original create_combined_dichroic_filter defaults, CMY order.
    dic = np.zeros((81, 3), dtype=np.float64)
    dic[:, 2] = erf((WL - 516.0) / 12.0)
    mask = WL <= 550.0
    dic[mask, 1] = -erf((WL[mask] - 500.0) / 8.0)
    dic[~mask, 1] = erf((WL[~mask] - 610.0) / 8.0)
    dic[:, 0] = -erf((WL - 607.0) / 8.0)
    dic = dic / 2.0 + 0.5
    cc = np.array([0.0, 65.0, 55.0], dtype=np.float64)
    trans = 10.0 ** (-cc / 100.0)
    dimmed = 1.0 - (1.0 - dic) * (1.0 - trans)[None, :]
    return np.prod(dimmed, axis=1)


def original_mallett_response_matrix(basis, d55, film_log_sens) -> np.ndarray:
    # Same einsum and green-midgray normalisation as
    # spektrafilm.utils.spectral_upsampling.rgb_to_raw_mallett2019.
    sensitivities = np.nan_to_num(10.0 ** film_log_sens)
    matrix = np.einsum("lk,l,lm->mk", basis, d55, sensitivities)
    raw_midgray = np.einsum("k,km->m", d55 * 0.184, sensitivities)
    return matrix / raw_midgray[1]


def main() -> None:
    basis = np.asarray(
        colour.recovery.MSDS_BASIS_FUNCTIONS_sRGB_MALLETT2019.copy()
        .align(SHAPE).values, dtype=np.float64
    )
    d55 = illuminant("D55")
    d50 = illuminant("D50")
    cie = np.asarray(
        colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"]
        .copy().align(SHAPE).values, dtype=np.float64
    )

    # Spektrafilm standard_illuminant("TH-KG3") = 3400K blackbody times
    # measured Schott KG3 spectrum, then normalised by its mean.
    bbr = np.asarray(
        colour.colorimetry.blackbody_spectral_radiance(WL * 1e-9, 3400),
        dtype=np.float64
    )
    source = bbr * kg3_filter()
    source /= np.mean(source)
    print_illuminant = source * default_dichroic()

    names = {
        "mallettBasis": basis,
        "d55": d55,
        "d50": d50,
        "cie1931": cie,
        "enlargerNeutral": print_illuminant,
        "schottKG3": kg3_filter(),
        "dichroicCMYNeutral": default_dichroic(),
    }
    assert basis.shape == (81, 3) and cie.shape == (81, 3)
    assert np.isclose(np.mean(d55), 1, rtol=1e-10)
    assert np.isclose(np.mean(d50), 1, rtol=1e-10)
    assert np.all((print_illuminant >= 0) & np.isfinite(print_illuminant))

    # Source-fidelity reference checks from the original Mallett2019 einsum.
    validation = []
    for stock in ("kodak_portra_400", "fujifilm_pro_400h"):
        raw = (ROOT / "src/spektrafilm/data/profiles" /
               (stock + ".json")).read_bytes()
        data = json.loads(raw)["data"]
        M = original_mallett_response_matrix(
            basis, d55, np.asarray(data["log_sensitivity"], dtype=np.float64))
        for rgb in ([0.184, 0.184, 0.184],
                    [0.65, 0.10, 0.04], [0.04, 0.65, 0.10],
                    [0.04, 0.10, 0.65]):
            raw_response = np.maximum(M @ rgb, 0.0)
            validation.append((stock, rgb, raw_response))
    lines = [
        "// GENERATED from Spektrafilm's original Mallett2019 / colour-science",
        "// optical reference functions; do not edit, not an iOS resource bundle.",
        "// Original source: spektrafilm.utils.spectral_upsampling / illuminants",
        "// and spektrafilm.model.color_filters; measured KG3 filter source.",
        "// Float64 reference rounded to packed Float32 for iOS 16.5.1.",
        "enum GeneratedOriginalOptics {",
    ]
    for key, array in names.items():
        lines.append(f'    static let {key} = "{encoded(array)}"')
    for index, (stock, rgb, response) in enumerate(validation):
        def numbers(vals):
            return "[" + ",".join(format(float(v), ".16g") for v in vals) + "]"
        lines.append(
            f"    static let referenceStock{index} = "
            f'"{stock}"'
        )
        lines.append(f"    static let referenceRGB{index}: [Double] = {numbers(rgb)}")
        lines.append(
            f"    static let referenceRaw{index}: [Double] = {numbers(response)}"
        )
    lines.append("}")
    DEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("PASS: Mallett2019 basis, D55/D50, CIE1931, KG3, default CMY filter")
    print(f"PASS: {len(validation)} Python reference Mallett response samples")
    print(f"Generated: {DEST.stat().st_size} bytes")
    print(f"colour-science version: {colour.__version__}")


if __name__ == "__main__":
    main()
