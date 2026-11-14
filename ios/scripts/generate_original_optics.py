#!/usr/bin/env python3
"""Build-time reference spectra from the ORIGINAL Spektrafilm Python methods.

Uses colour-science's Mallett 2019 sRGB basis, the stock reference D55,
CIE 1931 2° CMFs, D50 viewing illuminant, original 3400K Schott KG3
enlarger, and Spektrafilm's default CMY (0/65/55) dichroic filtration.

The iOS binary retains the legacy compact Float32 lookup arrays for the
mobile fast path AND independent original Float64 lookup arrays for the
opt-in high-precision photon/paper/scanner mode. No Python runtime is needed.
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


def encoded(values, source_float64: bool = False) -> str:
    dtype = np.float64 if source_float64 else np.float32
    value = np.asarray(values, dtype=dtype).ravel()
    if not np.isfinite(value).all():
        raise ValueError("Reference source contains nonfinite spectral values")
    pack = "<f8" if source_float64 else "<f4"
    return base64.b64encode(value.astype(pack).tobytes()).decode("ascii")


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


def canon_lens_transmission() -> np.ndarray:
    # Original GenericFilter(name='canon_24_f28_is',
    #   type='lens_transmission', brand='canon',
    #   data_in_percentage=True) as used by TH-KG3-L.
    source_file = (
        ROOT / "src/spektrafilm/data/filters/lens_transmission/"
        "canon/canon_24_f28_is.csv"
    )
    values = np.loadtxt(source_file, delimiter=",", dtype=np.float64)
    unique = np.unique(values[:, 0], return_index=True)[1]
    transmission = Akima1DInterpolator(
        values[unique, 0], values[unique, 1] / 100.0
    )(WL)
    assert transmission.shape == (81,)
    assert np.isfinite(transmission).all()
    return transmission


def default_dichroic(cc_values=(0.0, 65.0, 55.0)) -> np.ndarray:
    # Exact original create_combined_dichroic_filter defaults, CMY order.
    dic = np.zeros((81, 3), dtype=np.float64)
    dic[:, 2] = erf((WL - 516.0) / 12.0)
    mask = WL <= 550.0
    dic[mask, 1] = -erf((WL[mask] - 500.0) / 8.0)
    dic[~mask, 1] = erf((WL[~mask] - 610.0) / 8.0)
    dic[:, 0] = -erf((WL - 607.0) / 8.0)
    dic = dic / 2.0 + 0.5
    cc = np.asarray(cc_values, dtype=np.float64)
    assert cc.shape == (3,)
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
    # The actual upstream rgb_to_raw_mallett2019 first evaluates
    # colour.RGB_to_RGB(RGB, 'sRGB', 'sRGB',
    #   apply_cctf_decoding=False, apply_cctf_encoding=False).
    # Even a same-colourspace conversion is NOT necessarily exactly
    # the identity under colour-science reference matrices.
    # Preserve the evaluated Float64 3x3 row-vector transform so native
    # production reproduces the precise original operation order.
    mallett_srgb_conversion = np.asarray(
        colour.RGB_to_RGB(
            np.eye(3, dtype=np.float64), "sRGB", "sRGB",
            apply_cctf_decoding=False, apply_cctf_encoding=False
        ), dtype=np.float64
    )
    assert mallett_srgb_conversion.shape == (3, 3)
    assert np.isfinite(mallett_srgb_conversion).all()
    d55 = illuminant("D55")
    # Upstream standard_illuminant("T") uses the colour-science
    # Incandescent light source, aligned to 380-780nm / 5nm.
    tungsten = np.asarray(
        colour.SDS_LIGHT_SOURCES["Incandescent"].copy()
        .align(SHAPE).values, dtype=np.float64
    )
    tungsten /= np.mean(tungsten)
    d50 = illuminant("D50")
    # Upstream film-printing stocks Kodak 2383/2393 view under K75P.
    k75 = np.asarray(
        colour.SDS_LIGHT_SOURCES["Kinoton 75P"].copy().align(SHAPE).values,
        dtype=np.float64
    )
    k75 /= np.mean(k75)
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
    # Source standard_illuminant('TH-KG3-L'): measured Canon lens
    # transmission acts BEFORE mean-normalizing the illuminant.
    source_with_lens = source * canon_lens_transmission()
    source_with_lens /= np.mean(source_with_lens)
    print_illuminant = source * default_dichroic()

    # Original params_builder.apply_database_neutral_print_filters uses
    # print stock / TH-KG3 / film stock specific CMY Kodak CC balancing.
    # Bake the *actual* neutral filter for each 16 negatives x 8 media:
    # colour_enlarger(light_source, filter_cc_values=stock_cc).
    filter_db = json.loads((
        ROOT / "src/spektrafilm/data/filters/neutral_print_filters.json"
    ).read_text())
    all_infos = [
        json.loads(path.read_bytes())["info"]
        for path in sorted((ROOT / "src/spektrafilm/data/profiles").glob("*.json"))
    ]
    negatives = [x["stock"] for x in all_infos
                 if x["stage"] == "filming" and x["type"] == "negative"]
    media = [x["stock"] for x in all_infos if x["stage"] == "printing"]
    assert len(negatives) == 16 and len(media) == 8
    print_illuminants = {}
    neutral_cc_by_pair = {}
    for medium in media:
        for stock in negatives:
            cc = (filter_db.get(medium, {}).get("TH-KG3", {})
                  .get(stock, (0.0, 65.0, 55.0)))
            print_illuminants[stock + "|" + medium] = source * default_dichroic(cc)
            neutral_cc_by_pair[stock + "|" + medium] = [float(x) for x in cc]
    assert len(print_illuminants) == 128

    names = {
        "mallettSRGBConversion": mallett_srgb_conversion,
        "mallettBasis": basis,
        "d55": d55,
        "t": tungsten,
        "d50": d50,
        "k75p": k75,
        "cie1931": cie,
        "enlargerNeutral": print_illuminant,
        "enlargerSource": source,
        "enlargerSourceLens": source_with_lens,
        "schottKG3": kg3_filter(),
        "dichroicCMYNeutral": default_dichroic(),
    }
    assert basis.shape == (81, 3) and cie.shape == (81, 3)
    assert np.isclose(np.mean(d55), 1, rtol=1e-10)
    assert np.isclose(np.mean(tungsten), 1, rtol=1e-10)
    # Daylight and tungsten film stocks require distinct illuminants for
    # source Mallett 2019; do not accidentally reuse the D55 matrix.
    refs = {
        info["reference_illuminant"] for info in all_infos
        if info["stage"] == "filming"
    }
    assert refs == {"D55", "T"}, refs
    assert np.isclose(np.mean(d50), 1, rtol=1e-10)
    assert np.all((print_illuminant >= 0) & np.isfinite(print_illuminant))
    assert np.isclose(np.mean(source_with_lens), 1, rtol=1e-13)
    assert not np.allclose(source, source_with_lens, atol=1e-9)

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
        "// Mobile Float32 and independent true original Float64 spectra.",
        "enum GeneratedOriginalOptics {",
    ]
    for key, array in names.items():
        lines.append(f'    static let {key} = "{encoded(array)}"')
        lines.append(f'    static let sourceF64_{key} = '
                     f'"{encoded(array, source_float64=True)}"')
    lines.append("    static let printIlluminantByPair: [String: String] = [")
    for key, values in print_illuminants.items():
        lines.append(f"        {json.dumps(key)}: {json.dumps(encoded(values))},")
    lines.append("    ]")
    lines.append("    static let sourceF64PrintIlluminantByPair: [String: String] = [")
    for key, values in print_illuminants.items():
        lines.append(
            f"        {json.dumps(key)}: {json.dumps(encoded(values, source_float64=True))},"
        )
    lines.append("    ]")
    lines.append("    static let neutralCMYByPair: [String: [Double]] = [")
    for key, values in neutral_cc_by_pair.items():
        lines.append(f"        {json.dumps(key)}: {json.dumps(values)},")
    lines.append("    ]")
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
    print("PASS: 128 original film×print neutral CMY database filter spectra")
    print("PASS: independent Float64 CIE/illuminants/basis/KG3/128 pair spectra " +
          "preserved alongside unchanged mobile Float32")
    print(f"PASS: {len(validation)} Python reference Mallett response samples")
    print(f"Generated: {DEST.stat().st_size} bytes")
    print(f"colour-science version: {colour.__version__}")


if __name__ == "__main__":
    main()
