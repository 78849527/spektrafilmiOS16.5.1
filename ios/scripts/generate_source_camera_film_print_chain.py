#!/usr/bin/env python3
"""Source Hanatos 2025 linear RGB -> negative H-D/DIR -> print CDF -> RGB.

Actual ORIGINAL Python _rgb_to_tc_b + rgb_to_raw_hanatos2025 are
extracted from upstream spectral_upsampling.py with their original AST,
and original apply_lut_cubic_2d is imported from fast_interp_lut.py.
Original source spectral LUT + measured stock sensitivity and source erf4
window are integrated at Float64 as in generate_hanatos.py.
Film develop and DIR use ACTUAL model/density_curves.py, couplers.py.
Only camera spatial effects and grain intentionally disabled (LUT mode).
No approximation/fallback for missing source functions.
"""
import ast
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import colour
import numpy as np
from scipy.special import erf

from generate_hanatos import (
    NPY, SHAPE, WAVELENGTH, reference_illuminant
)
from generate_source_film_dir_print_chain import (
    ROOT, FILES, array, upstream_film, negative_params
)
from generate_source_negative_print_chain import settings
from generate_original_optics import default_dichroic, kg3_filter
from generate_print_optics import exposure_raw
from generate_print_morph import (
    DensityCurvesModel, apply_print_curves_morph
)
from generate_source_print_scanner_parity import source_scan_print

OUT=ROOT/"ios/SpektraFilmPort/GeneratedSourceCameraFilmPrintReference.swift"


def load_actual_source_hanatos():
    # Reuse upstream Python functions directly, but avoid importing the
    # unrelated spektrafilm package initializer and exiv2/RAW bindings.
    p=ROOT/"src/spektrafilm/utils/fast_interp_lut.py"
    spec=importlib.util.spec_from_file_location(
        "spektrafilm.utils.fast_interp_lut", p)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    path=ROOT/"src/spektrafilm/utils/spectral_upsampling.py"
    tree=ast.parse(path.read_text(encoding="utf-8"))
    funcs=("_tri2quad","_illuminant_to_xy","_rgb_to_tc_b",
           "rgb_to_raw_hanatos2025")
    nodes=[node for node in tree.body
           if isinstance(node,ast.FunctionDef) and node.name in funcs]
    assert len(nodes)==len(funcs), "Upstream Hanatos source signature changed"
    cie=np.asarray(
        colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"]
              .copy().align(SHAPE).values,
        dtype=np.float64,
    )
    ns={
        "np":np,"colour":colour,
        "STANDARD_OBSERVER_CMFS":cie,
        "standard_illuminant":reference_illuminant,
        "apply_lut_cubic_2d":module.apply_lut_cubic_2d,
    }
    exec(compile(ast.Module(body=nodes,type_ignores=[]),
                 str(path),"exec"),ns)
    return ns["rgb_to_raw_hanatos2025"]


def stock_float64_lut(film):
    doc=json.loads((FILES/(film+".json")).read_text())
    info=doc["info"]
    fd=doc["data"]
    source=np.asarray(np.load(NPY,allow_pickle=False),dtype=np.float64)
    sensitivity=np.nan_to_num(
        10.0**np.asarray(fd["log_sensitivity"],dtype=np.float64))
    p=np.asarray(fd["hanatos2025_adaptation_window_params"],
                 dtype=np.float64)
    if p.size != 4:
        raise ValueError("Original Hanatos erf4 window missing: "+film)
    cu,su,ci,si=p
    window=(0.5*(1+erf((WAVELENGTH-cu)/(su*np.sqrt(2))))) * (
            0.5*(1-erf((WAVELENGTH-ci)/(si*np.sqrt(2)))))
    illum=reference_illuminant(info["reference_illuminant"])
    norm=(
        np.sum(sensitivity*illum[:,None]*window[:,None],axis=0) /
        np.sum(sensitivity*illum[:,None],axis=0)
    )
    if not np.isfinite(norm).all() or (norm<=0).any():
        raise ValueError("Invalid original Hanatos UV/IR normalization")
    lut=np.einsum(
        "xyw,wc->xyc",source,
        sensitivity*window[:,None]/norm[None,:],optimize=True
    )
    assert lut.ndim==3 and lut.shape[2]==3 and np.isfinite(lut).all()
    return lut, sensitivity, info


def main():
    density,couplers,cls=upstream_film()
    params=negative_params(cls)
    M=couplers.compute_dir_couplers_matrix(params)*params.amount
    raw_hanatos=load_actual_source_hanatos()
    src=np.asarray(
        colour.colorimetry.blackbody_spectral_radiance(
            np.arange(380,781,5,dtype=np.float64)*1e-9,3400
        )*kg3_filter(),dtype=np.float64,
    )
    src/=src.mean()
    neutral=json.loads(
        (ROOT/"src/spektrafilm/data/filters/neutral_print_filters.json").read_text()
    )
    # 6 film/paper/filter combinations, 4 RGB colours = 24 cases / 72 channels.
    # Camera EV includes under, normal and over exposure, independently from
    # the paper exposure; avoid only testing neutral gray.
    routes=[
        ("kodak_portra_400","kodak_portra_endura","neutral",[0,0,0],0,0,0,0),
        ("kodak_portra_400","kodak_portra_endura","gamma_082",[17,-23,31],.025,10,-8,1),
        ("fujifilm_pro_400h","kodak_2383","exhaustion_04",[-20,14,-11],.08,-12,24,-1),
        ("kodak_portra_400","kodak_2383","mixed",[30,40,-35],.12,28,-21,2),
        ("fujifilm_pro_400h","kodak_portra_endura","fast_slow",[-12,17,-8],.035,0,11,0),
        ("kodak_portra_400","kodak_portra_endura","rgb",[7,-10,22],.045,5,-13,-1),
    ]
    colors=[
        [0.184,0.184,0.184],
        [0.65,0.12,0.04],
        [0.11,0.56,0.18],
        [0.11,0.11,0.70],
    ]
    camera_evs=[0,-1,1,0.5]
    lines=[
        "// Direct original upstream Python Hanatos + model/couplers",
        "// + optical print + s023 absolute CDF + source scan references.",
        "// Linear sRGB 1x1 inputs; no spatial/RAW/Numba/whole-image proof.",
        "enum GeneratedSourceCameraFilmPrintReference {",
        "  struct Vector {",
        "    let film: String",
        "    let paper: String",
        "    let morphMode: String",
        "    let shift: [Double]",
        "    let preflashExposure: Double",
        "    let preflashM: Double",
        "    let preflashY: Double",
        "    let cameraEV: Double",
        "    let paperEV: Double",
        "    let linearRGB: [Double]",
        "    let encodedInputRGB: [Double]",
        "    let sourceHanatosRaw: [Double]",
        "    let sourceFilmLogRaw: [Double]",
        "    let sourceInitialFilmDensity: [Double]",
        "    let sourceDIRCorrectedLogRaw: [Double]",
        "    let sourceFilmDevelopedDensity: [Double]",
        "    let sourcePrintRaw: [Double]",
        "    let sourcePaperLogExposure: [Double]",
        "    let sourcePaperDensity: [Double]",
        "    let sourceXYZ: [Double]",
        "    let sourceLinearRGB: [Double]",
        "    let sourceACES: [Double]",
        "    let sourceEncodedRGB: [Double]",
        "  }",
        "  static let vectors: [Vector] = [",
    ]
    lutcache={}
    count=0
    for film,paper,mode,shift,flash,flash_m,flash_y,pev in routes:
        f=json.loads((FILES/(film+".json")).read_text())
        p=json.loads((FILES/(paper+".json")).read_text())
        fd=f["data"]; pd=p["data"]
        if film not in lutcache:
            lutcache[film]=stock_float64_lut(film)
        lut,sensitivity,info=lutcache[film]
        le=np.asarray(fd["log_exposure"],dtype=np.float64)
        dc=np.asarray(fd["density_curves"],dtype=np.float64)
        normalized=dc-np.nanmin(dc,axis=0)
        adjusted=couplers.compute_density_curves_before_dir_couplers(
            normalized,le,M,positive=False)
        printle=np.asarray(pd["log_exposure"],dtype=np.float64)
        model=pd["density_curves_model"]
        fitted=apply_print_curves_morph(
            printle,
            DensityCurvesModel(model["model_type"],model["centers"],
                               model["amplitudes"],model["sigmas"]),
            settings(mode),profile_type=p["info"]["type"]
        )
        base=np.asarray(fd["base_density"],dtype=np.float64)
        dyes=np.asarray(fd["channel_density"],dtype=np.float64)
        papersensitivity=np.nan_to_num(
            10**np.asarray(pd["log_sensitivity"],dtype=np.float64))
        cc=np.asarray(
            neutral.get(paper,{}).get("TH-KG3",{}).get(film,[0,65,55]),
            dtype=np.float64
        )
        printlight=src*default_dichroic(cc+shift)
        prelight=src*default_dichroic(cc+[0,flash_m,flash_y])
        preflash=flash*np.einsum(
            "l,lc->c",np.nan_to_num(10**(-base)*prelight,nan=0.),
            papersensitivity
        )
        for c,input_rgb in enumerate(colors):
            linear=np.asarray(input_rgb,dtype=np.float64)
            raw=raw_hanatos(
                linear.reshape(1,1,3),sensitivity,
                color_space="sRGB",
                apply_cctf_decoding=False,
                reference_illuminant=info["reference_illuminant"],
                tc_lut=lut
            )[0,0]
            assert np.isfinite(raw).all(),(film,linear,raw)
            camera_ev=camera_evs[c]
            # FilmingStage.expose: raw *= 2**cameraEV, then clamp/log.
            film_log=np.log10(np.fmax(raw*2**camera_ev,0.)+1e-10)
            initial=density.interpolate_exposure_to_density(
                film_log.reshape(1,1,3),normalized,le,1.
            )[0,0]
            dir_log=film_log-initial@M
            developed=couplers.apply_density_correction_dir_couplers(
                initial.reshape(1,1,3).copy(),
                film_log.reshape(1,1,3),None,
                le,normalized,params,"negative",gamma_factor=1.0
            )[0,0]
            independently=np.array([
                np.interp(dir_log[ch],le,adjusted[:,ch]) for ch in range(3)
            ])
            assert np.max(abs(developed-independently))<1e-9
            print_raw=exposure_raw(
                developed,base,dyes,papersensitivity,printlight)
            log_print=np.log10(
                np.maximum((np.maximum(print_raw+preflash,0)+1e-10)*2**pev,0)
                +1e-10
            )
            paperdensity=np.array([
                np.interp(log_print[ch],printle,fitted[:,ch])
                for ch in range(3)
            ])
            xyz,srgb,aces,encoded=source_scan_print(
                p,paperdensity[np.newaxis,:]
            )
            display=np.clip(encoded,0,1)
            encoded_input=np.asarray(colour.cctf_encoding(linear,function="sRGB"))
            # Every source numerical stage is finite, including source raw.
            for v in (raw,film_log,initial,dir_log,developed,print_raw,
                      log_print,paperdensity,xyz,srgb,aces,display,
                      encoded_input):
                assert np.isfinite(v).all(),(film,v)
            lines.extend([
                "    Vector(",
                f'      film:{json.dumps(film)},paper:{json.dumps(paper)},',
                f'      morphMode:{json.dumps(mode)},shift:{array(shift)},',
                f'      preflashExposure:{flash},preflashM:{flash_m},',
                f'      preflashY:{flash_y},cameraEV:{camera_ev},paperEV:{pev},',
                f'      linearRGB:{array(linear)},',
                f'      encodedInputRGB:{array(encoded_input)},',
                f'      sourceHanatosRaw:{array(raw)},',
                f'      sourceFilmLogRaw:{array(film_log)},',
                f'      sourceInitialFilmDensity:{array(initial)},',
                f'      sourceDIRCorrectedLogRaw:{array(dir_log)},',
                f'      sourceFilmDevelopedDensity:{array(developed)},',
                f'      sourcePrintRaw:{array(print_raw)},',
                f'      sourcePaperLogExposure:{array(log_print)},',
                f'      sourcePaperDensity:{array(paperdensity)},',
                f'      sourceXYZ:{array(xyz)},',
                f'      sourceLinearRGB:{array(srgb)},',
                f'      sourceACES:{array(aces)},',
                f'      sourceEncodedRGB:{array(display)}',
                "    ),"
            ])
            count+=1
    assert count==24
    lines+=["  ]","}"]
    OUT.write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("PASS: actual upstream source Hanatos rgb_to_raw_hanatos2025 + " +
          "upstream film H-D/DIR + paper CDF + scan 24 routes/72 channels")
    print("Scope: 1x1 linear sRGB, pre-film spatial effects disabled, " +
          "source Float64 LUT, optical no-normalization; not camera RAW, " +
          "whole-image, stochastic grain or spatial DIR.")


if __name__=="__main__":
    main()
