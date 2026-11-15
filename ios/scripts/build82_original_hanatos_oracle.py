#!/usr/bin/env python3
"""Build82 original-Python AST oracle for adaptive Hanatos spectral LUT.

Executes source spectral_upsampling.py compute_hanatos2025_tc_lut,
4-param erf window, degree-4 poly4, warped poly4 and source UV/IR filter.
Also exercises original SciPy reflect gaussian at 81 wavelengths. Fixtures
sample real original NumPy 192x192x81 spectra, not synthetic mobile looks.

Deliberately validates uncompressed TC LUT separately; Build81 independently
checks source CIE1931 xy gamut. The combined remap remains unverified until
the Python source and Swift full-LUT comparison is added.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

import colour
import numpy as np
import scipy.ndimage
import scipy.special
from opt_einsum import contract

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/"src/spektrafilm/utils/spectral_upsampling.py"
COLOR=ROOT/"src/spektrafilm/model/color_filters.py"
NPY=ROOT/"src/spektrafilm/data/luts/spectral_upsampling/irradiance_xy_tc.npy"
PROFILE_DIR=ROOT/"src/spektrafilm/data/profiles"
PIN={
    "spectral_upsampling.py":"bb75f8a00d00eb02ba571c6cfdbec88a8c0194cb",
    "color_filters.py":"73849be82f7e32e21cd9bf3e116ba244a931188b",
}
SHAPE=colour.SpectralShape(380,780,5)


def check(path:Path,expected:str)->None:
    got=subprocess.check_output(
        ["git","hash-object",str(path)],cwd=ROOT,text=True
    ).strip()
    if got!=expected:
        raise RuntimeError(f"Original source blob drift: {path}, {got}")


def original_illuminant(label:str)->np.ndarray:
    table=colour.SDS_LIGHT_SOURCES if label=="T" else colour.SDS_ILLUMINANTS
    light="Incandescent" if label=="T" else label
    value=np.asarray(table[light].copy().align(SHAPE).values,dtype=np.float64)
    return value/(value.sum()/len(value))


def original_illuminant_xy(label:str)->np.ndarray:
    cie=np.asarray(
        colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"]
        .copy().align(SHAPE).values,dtype=np.float64
    )
    xyz=np.einsum("w,wc->c",original_illuminant(label),cie)
    return xyz[:2]/xyz.sum()


def original_functions():
    check(SOURCE,PIN["spectral_upsampling.py"])
    check(COLOR,PIN["color_filters.py"])
    full=ast.parse(SOURCE.read_text("utf8"),filename=str(SOURCE))
    names={
        "_tri2quad","_quad2tri","_radial_mobius_warp_xy",
        "hanika_sigmoid","poly2d_deg4",
        "eval_poly4_log_exposure_surface",
        "eval_poly4_warp_log_exposure_surface",
        "eval_log_exposure_correction_surface",
        "eval_erf4_spectral_bandpass",
        "eval_spectral_bandpass_window",
        "compute_hanatos2025_tc_lut",
    }
    sub=ast.fix_missing_locations(ast.Module(
        body=[n for n in full.body if isinstance(n,ast.FunctionDef)
              and n.name in names],type_ignores=[]
    ))
    if len(sub.body)!=len(names):
        raise RuntimeError("Missing pinned original Hanatos source methods")
    native_spectra=np.double(np.load(NPY,allow_pickle=False))
    if native_spectra.shape!=(192,192,81):
        raise RuntimeError("Original 81-wavelength spectra LUT shape changed")
    ns={
        "__name__":"__build82_original_ast__",
        "np":np,
        "scipy":scipy,
        "contract":contract,
        "SPECTRAL_SHAPE":SHAPE,
        "_SQRT2PI":float(np.sqrt(2*np.pi)),
        "_HANATOS2025_MAX_CORRECTION_STOPS":2.0,
        "HANATOS2025_SPECTRA_LUT":native_spectra,
        "standard_illuminant":original_illuminant,
        "_illuminant_to_xy":original_illuminant_xy,
    }
    exec(compile(sub,str(SOURCE),"exec"),ns)
    color_ast=ast.parse(COLOR.read_text("utf8"),filename=str(COLOR))
    wanted={"sigmoid_erf","compute_band_pass_filter"}
    selected=[n for n in color_ast.body
              if isinstance(n,ast.FunctionDef) and n.name in wanted]
    if len(selected)!=2:raise RuntimeError("Source bandpass function missing")
    exec(compile(ast.fix_missing_locations(ast.Module(
        body=selected,type_ignores=[])),str(COLOR),"exec"),ns)
    return ns


def profile(stock:str):
    doc=json.loads((PROFILE_DIR/(stock+".json")).read_bytes())
    raw=doc["data"]
    sens=np.nan_to_num(10.0**np.asarray(raw["log_sensitivity"],
                                       dtype=np.float64))
    window=np.asarray(raw["hanatos2025_adaptation_window_params"],dtype=np.float64)
    surface=np.asarray(raw["hanatos2025_adaptation_surface_params"],dtype=np.float64)
    return doc["info"]["reference_illuminant"],sens,window,surface


def main():
    p=argparse.ArgumentParser()
    p.add_argument("--output",required=True,type=Path)
    args=p.parse_args()
    if colour.__version__!="0.4.6":
        raise RuntimeError("Source requires colour-science 0.4.6")
    s=original_functions()
    cells=[(0,0),(0,191),(191,0),(191,191),(1,1),(24,35),
           (96,96),(31,178),(187,127),(72,119),(133,43),(100,0)]
    cases=[]
    for stock,uv,ir in [
        ("kodak_portra_400",None,None),
        ("kodak_portra_400",(0.85,410.0,8.0),(0.65,675.0,15.0)),
        ("kodak_vision3_500t",(1.0,440.0,9.0),(1.0,660.0,11.0)),
    ]:
        reference,sensitivity,window,surface=profile(stock)
        ill=original_illuminant(reference)
        color_filter=s["compute_band_pass_filter"](
            filter_uv=uv or [0,410,8],
            filter_ir=ir or [0,675,15],
        )
        ratio=(
            np.sum(sensitivity*ill[:,None]*color_filter[:,None],axis=0)
            /np.sum(sensitivity*ill[:,None],axis=0)
        )
        sens_filtered=sensitivity*color_filter[:,None]/ratio[None,:]
        adapt=SimpleNamespace(
            window_params=window,surface_params=surface,
            spectral_gaussian_blur=0.0,
            reference_illuminant=reference,
            apply_window=True,apply_surface=True,
        )
        # Executes THE ORIGINAL source compute_hanatos2025_tc_lut with
        # the actual profile + camera-filter-normalized sensitivity.
        result=s["compute_hanatos2025_tc_lut"](
            sens_filtered,adapt,gamut_compress=None
        )
        if result.shape!=(192,192,3) or not np.isfinite(result).all():
            raise RuntimeError("Original Hanatos compute unexpectedly invalid")
        cases.append({
            "stock":stock,
            "filter_uv":list(uv or [0,410,8]),
            "filter_ir":list(ir or [0,675,15]),
            "reference_white":original_illuminant_xy(reference).tolist(),
            "cells":[[x,y] for x,y in cells],
            "expected":[result[x,y,:].tolist() for x,y in cells],
        })

    # The following exercise original AST functions without replacing the
    # surface / window source formula with a manually transcribed oracle.
    reference,sensitivity,window,surface=profile("kodak_portra_400")
    original_window=s["eval_erf4_spectral_bandpass"](window)
    white=original_illuminant_xy(reference)
    surface_grid=s["eval_poly4_log_exposure_surface"](surface,white)
    warp=np.column_stack([surface,np.full(3,0.75)])
    warped_grid=s["eval_poly4_warp_log_exposure_surface"](warp,white)
    gaussian_inputs=np.asarray(np.load(NPY,allow_pickle=False)[74,91,:],
                               dtype=np.float64)
    sigma=0.7
    gaussian_source=scipy.ndimage.gaussian_filter(
        gaussian_inputs,sigma,mode="reflect"
    )
    result={
        "pinned":PIN,
        "colour_version":colour.__version__,
        "source_npy_sha256":hashlib.sha256(NPY.read_bytes()).hexdigest(),
        "cases":cases,
        "surface":{
            "stock":"kodak_portra_400",
            "cells":[[x,y] for x,y in cells],
            "poly4":[surface_grid[x,y,:].tolist() for x,y in cells],
            "warped_alpha":0.75,
            "warped":[warped_grid[x,y,:].tolist() for x,y in cells],
            "window":original_window[:,0].tolist(),
            "gaussian_sigma":sigma,
            "gaussian_input":gaussian_inputs.tolist(),
            "gaussian_expected":gaussian_source.tolist(),
        }
    }
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,separators=(",",":")),
                           encoding="utf8")
    print(f"PASS Build82 pinned source Python Hanatos "
          f"{len(cases)} full 192x192x81 adaptation LUTs, "
          f"poly4/warped surface, erf4 window, SciPy Gaussian")


if __name__=="__main__":
    main()
