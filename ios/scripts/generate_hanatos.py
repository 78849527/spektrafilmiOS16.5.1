#!/usr/bin/env python3
"""Precompute upstream Hanatos2025 raw film response on original TC grid.

Upstream input: src/spektrafilm/data/luts/spectral_upsampling/irradiance_xy_tc.npy
This is the ORIGINAL sample irradiance spectrum LUT. For each of the 20
measured exposure films we apply the original sensitivity and its original
erf4 window with white-normalised D55, matching the default upstream
compute_hanatos2025_tc_lut (window enabled, correction surface disabled).
The resulting 2D raw-response LUT is stored in Float16 for compact iOS16.5.1
delivery; native Swift reproduces original XYZ/CAT16 -> triangular coords
and reflected Mitchell-Netravali cubic grid interpolation.

Full pipeline output parity is NOT implied; DIR couplers, colour reference,
grain and scanner gamut processing remain separate stages.
"""
from __future__ import annotations
import base64
import hashlib
import json
import math
from pathlib import Path
import colour
import numpy as np
from scipy.special import erf

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "src/spektrafilm/data/profiles"
NPY = ROOT / "src/spektrafilm/data/luts/spectral_upsampling/irradiance_xy_tc.npy"
DEST = ROOT / "ios/SpektraFilmPort/GeneratedHanatosData.swift"
PRECISE_DEST = ROOT / "ios/SpektraFilmPort/GeneratedHanatosPreciseData.swift"
WAVELENGTH = np.arange(380, 781, 5, dtype=np.float64)
SHAPE = colour.SpectralShape(380, 780, 5)

def q(x):
    return json.dumps(str(x), ensure_ascii=False)

def reference_illuminant(name: str) -> np.ndarray:
    # Spektrafilm.standard_illuminant("T") is the incandescent lamp from
    # colour.SDS_LIGHT_SOURCES, not a CIE standard daylight illuminant.
    table = colour.SDS_LIGHT_SOURCES if name == "T" else colour.SDS_ILLUMINANTS
    source = "Incandescent" if name == "T" else name
    values = np.asarray(table[source].copy().align(SHAPE).values,
                        dtype=np.float64)
    return values / np.mean(values)

def mitchell(t: float) -> float:
    x = abs(t); b = 1.0 / 3; c = 1.0 / 3
    if x < 1:
        return ((12 - 9*b - 6*c)*x**3 + (-18 + 12*b + 6*c)*x*x +
                (6 - 2*b))/6.0
    if x < 2:
        return ((-b - 6*c)*x**3 + (6*b + 30*c)*x*x -
                (12*b + 48*c)*x + (8*b + 24*c))/6.0
    return 0

def interpolate(tc_lut, xy):
    n = tc_lut.shape[0]
    coords = np.clip(np.asarray(xy) * (n-1), 0, n-1)
    bases = np.minimum(n-2, np.floor(coords).astype(int))
    frac = coords - bases
    wx = [mitchell(frac[0] + 1 - i) for i in range(4)]
    wy = [mitchell(frac[1] + 1 - i) for i in range(4)]
    out = np.zeros(3, dtype=np.float64)
    norm = 0.
    for i in range(4):
        ix = bases[0]-1+i
        ix = -ix if ix < 0 else 2*(n-1)-ix if ix >= n else ix
        for j in range(4):
            iy = bases[1]-1+j
            iy = -iy if iy < 0 else 2*(n-1)-iy if iy >= n else iy
            w = wx[i]*wy[j]
            out += w * tc_lut[ix,iy,:]
            norm += w
    return out / norm

def film_response(rgb, matrix, lut):
    xyz = np.asarray(rgb) @ matrix
    brightness = float(np.sum(xyz))
    xy = xyz[:2] / max(brightness, 1e-10)
    tx = np.clip((1.0-xy[0])**2,0,1)
    ty = np.clip(xy[1]/max(1.0-xy[0],1e-10),0,1)
    return interpolate(lut, [tx,ty]) * brightness

def main():
    orig = np.load(NPY, allow_pickle=False)
    assert orig.ndim == 3 and orig.shape[0] == orig.shape[1]
    assert orig.shape[2] == 81 and orig.shape[0] >= 32
    n = orig.shape[0]
    assert np.isfinite(orig).all()

    names = [
        "kodak_portra_400", "kodak_vision3_250d",
        "fujifilm_provia_100f",
    ]
    originals = []
    for path in sorted(DATA.glob("*.json")):
        doc = json.loads(path.read_bytes())
        info, measured = doc["info"], doc["data"]
        if info["stage"] == "filming" and info["support"] == "film":
            originals.append((info, measured))
    assert len(originals) == 20

    # Every stock can have a different reference illuminant (e.g. D55 for
    # daylight negatives, T for tungsten stocks). Use the exact upstream
    # _rgb_to_tc_b CAT16 matrix for that stock, not one global D55 matrix.
    cie = np.asarray(colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"]
                     .copy().align(SHAPE).values, dtype=np.float64)
    matrices={}
    for info, _ in originals:
        illum = reference_illuminant(info["reference_illuminant"])
        illum_xyz = np.einsum("w,wc->c", illum, cie)
        illum_xy = illum_xyz[:2] / np.sum(illum_xyz)
        mat = np.asarray(colour.RGB_to_XYZ(
            np.eye(3), colourspace="sRGB", apply_cctf_decoding=False,
            illuminant=illum_xy, chromatic_adaptation_transform="CAT16"),
            dtype=np.float64
        )
        assert mat.shape == (3,3)
        matrices[info["stock"]]=mat

    lines = [
        "// ORIGINAL Hanatos2025 spectral irradiation TC response from upstream",
        "// spektrafilm.data.luts.spectral_upsampling.irradiance_xy_tc.npy.",
        "// With original per-stock spectral sensitivity and erf4 window.",
        "// The original source LUT values are integrated at build time; Float16",
        "// storage on iOS introduces at most subpercent quantization.",
        "enum GeneratedHanatosData {",
        f"    static let dimension = {n}",
        f'    static let sourceSHA256 = "{hashlib.sha256(NPY.read_bytes()).hexdigest()}"',
        "    static let sRGBToXYZByFilm: [String: [Double]] = [",
    ]
    for stock, mat in matrices.items():
        lines.append("        " + q(stock) + ": [" +
                     ",".join(format(float(x), ".17g") for x in mat.ravel()) +
                     "],")
    lines.extend([
        "    ]",
        "    static let lutByFilm: [String: String] = [",
    ])
    lut_map={}
    # Keep the upstream spectral contraction in IEEE754 Float64 for the
    # original mode; the packed Float16 version remains the mobile mode.
    precise_lines=[
        "// ORIGINAL upstream Hanatos2025 2D TC source sensor-integrated LUT.",
        "// Actual stored IEEE754 binary64. Never silently drop to Float16.",
        "enum GeneratedHanatosPreciseData {",
        f"    static let dimension = {n}",
        f'    static let sourceSHA256 = "{hashlib.sha256(NPY.read_bytes()).hexdigest()}"',
        "    static let lutByFilm: [String: String] = [",
    ]
    for info, values in originals:
        stock = info["stock"]
        sensitivity = np.nan_to_num(10.0 ** np.asarray(
            values["log_sensitivity"], dtype=np.float64))
        windowp = np.asarray(values["hanatos2025_adaptation_window_params"],
                             dtype=np.float64)
        if windowp.size == 4:
            cu, su, ci, si = windowp
            window = 0.5*(1.0+erf((WAVELENGTH-cu)/(su*np.sqrt(2.0)))) * (
                0.5*(1.0-erf((WAVELENGTH-ci)/(si*np.sqrt(2.0)))))
            ill = reference_illuminant(info["reference_illuminant"])
            normalize = (np.sum(sensitivity * ill[:,None] * window[:,None],axis=0)
                         / np.sum(sensitivity * ill[:,None],axis=0))
            sensitivity = sensitivity * window[:,None] / normalize[None,:]
        response = np.einsum("xyw,wc->xyc", orig, sensitivity, optimize=True)
        assert response.shape == (n,n,3) and np.isfinite(response).all()
        half = response.astype("<f2")
        if not np.isfinite(half).all():
            raise ValueError(f"Float16 overflow in {stock}")
        encoded = base64.b64encode(half.tobytes()).decode("ascii")
        lines.append("        "+q(stock)+": "+q(encoded)+",")
        lut_map[stock] = response
        packed=np.ascontiguousarray(response,dtype="<f8")
        precise_lines.append("        "+q(stock)+": "+
                             q(base64.b64encode(packed.tobytes()).decode("ascii"))+",")

    lines.append("    ]")
    sample=[np.array([0.184]*3),np.array([0.65,0.12,0.04]),
            np.array([0.11,0.56,0.18]),np.array([0.11,0.11,0.7])]
    idx=0
    # Save reference vectors evaluated against original Float64 upstream array,
    # test Swift Float16 path allowing for storage quantization.
    for stock in names:
        for x in sample:
            y=film_response(x,matrices[stock],lut_map[stock])
            lines.append(f'    static let refStock{idx} = {q(stock)}')
            lines.append(f'    static let refRGB{idx}: [Double] = ['+
                         ",".join(format(float(a),".16g") for a in x)+"]")
            lines.append(f'    static let refRaw{idx}: [Double] = ['+
                         ",".join(format(float(a),".16g") for a in y)+"]")
            idx+=1
    lines.append("}")
    DEST.write_text("\n".join(lines)+"\n", encoding="utf-8")
    precise_lines.extend(["    ]", "}"])
    PRECISE_DEST.write_text("\n".join(precise_lines)+"\n",encoding="utf-8")
    print(f"PASS: 20 original Float64 Hanatos stock response LUTs " +
          f"({PRECISE_DEST.stat().st_size} Swift bytes), no mobile precision fallback")
    print(f"PASS: original Hanatos2025 LUT grid {n}x{n}x81, "
          "default per-stock UV window adaptation")
    print(f"PASS: 20 filming stocks, {idx} Python/SciPy reference vectors")
    print(f"Generated Hanatos measured Swift arrays: {DEST.stat().st_size} bytes")

if __name__ == "__main__":
    main()
