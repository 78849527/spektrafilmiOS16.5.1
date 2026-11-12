#!/usr/bin/env python3
"""Original Python FILM measured H-D + source couplers DIR -> optical print RGB.

This script imports and RUNS upstream model/density_curves.py and
model/couplers.py, NOT a new Python rewrite of those film algorithms.
Spatial DIR is disabled as original source's debug.lut_mode. The input is
already-log exposure of negative emulsion (not camera RAW/Hanatos).
Optical print, s023 fitted paper H-D and ACES scanning use the same
original Python source utilities as v1.8.12's 54-channel truth set.
"""
import importlib.util
import json
import sys
import types
from dataclasses import dataclass
from pathlib import Path

import colour
import numpy as np
from generate_original_optics import ROOT, default_dichroic, kg3_filter
from generate_print_optics import exposure_raw
from generate_print_morph import (
    DensityCurvesModel, apply_print_curves_morph
)
from generate_source_negative_print_chain import (
    FILES, array, settings
)
from generate_source_print_scanner_parity import source_scan_print

OUTPUT=ROOT/"ios/SpektraFilmPort/GeneratedSourceFilmDIRPrintReference.swift"


def load_original_module(module_name, path):
    obj=importlib.util.spec_from_file_location(module_name,path)
    mod=importlib.util.module_from_spec(obj)
    sys.modules[module_name]=mod
    obj.loader.exec_module(mod)
    return mod


def upstream_film():
    # generate_print_morph installed source model utils package shims,
    # without importing Spektrafilm's eager __init__ RAW/exiv2 dependency.
    for name in ("spektrafilm.model", "spektrafilm.runtime"):
        if name not in sys.modules:
            package=types.ModuleType(name)
            package.__path__=[]
            sys.modules[name]=package

    # Only needed to import the source couplers module. The dataclass
    # faithfully reproduces original runtime/params_schema.py's
    # DirCouplersParams defaults/field names; film-specific coefficients
    # below use original runtime/params_builder.py:171-175.
    @dataclass
    class DirCouplersParams:
        active: bool = True
        amount: float = 1.0
        inhibition_samelayer: float = 1.0
        inhibition_interlayer: float = 1.0
        gamma_samelayer_rgb: tuple = (0.341, 0.324, 0.273)
        gamma_interlayer_r_to_gb: tuple = (0.355, 0.305)
        gamma_interlayer_g_to_rb: tuple = (0.154, 0.358)
        gamma_interlayer_b_to_rg: tuple = (0.171, 0.225)
        diffusion_size_um: float = 20.0
        diffusion_tail_um: float = 200.0
        diffusion_tail_weight: float = 0.06
    schema=types.ModuleType("spektrafilm.runtime.params_schema")
    schema.DirCouplersParams=DirCouplersParams
    sys.modules[schema.__name__]=schema
    # Spatial source kernels MUST NOT be called for these 1x1 LUT-mode
    # samples. Fail explicitly if source does attempt to use them.
    diffusion=types.ModuleType("spektrafilm.utils.fast_gaussian_filter")
    def spatial_forbidden(*args, **kwargs):
        raise RuntimeError("Spatial DIR must be disabled in LUT-mode parity")
    diffusion.fast_gaussian_filter=spatial_forbidden
    diffusion.fast_exponential_filter=spatial_forbidden
    sys.modules[diffusion.__name__]=diffusion

    load_original_module(
        "spektrafilm.utils.fast_interp",
        ROOT/"src/spektrafilm/utils/fast_interp.py",
    )
    density=load_original_module(
        "spektrafilm.model.density_curves",
        ROOT/"src/spektrafilm/model/density_curves.py",
    )
    couplers=load_original_module(
        "spektrafilm.model.couplers",
        ROOT/"src/spektrafilm/model/couplers.py",
    )
    return density,couplers,DirCouplersParams


def negative_params(cls):
    # Original _apply_film_specifics() negative-film defaults; amount=1.
    return cls(
        gamma_samelayer_rgb=(.336,.319,.273),
        gamma_interlayer_r_to_gb=(.353,.302),
        gamma_interlayer_g_to_rb=(.154,.353),
        gamma_interlayer_b_to_rg=(.168,.226),
        diffusion_size_um=0.0,
        diffusion_tail_um=0.0,
    )


def main():
    density, couplers, params_cls=upstream_film()
    params=negative_params(params_cls)
    M=couplers.compute_dir_couplers_matrix(params)*params.amount
    assert np.allclose(
        M,
        np.array([[.336,.353,.302],[.154,.319,.353],[.168,.226,.273]]),
        atol=0,rtol=0,
    ), "Original negative DIR donor x receiver order changed"

    source=np.asarray(
        colour.colorimetry.blackbody_spectral_radiance(
            np.arange(380,781,5,dtype=np.float64)*1e-9,3400
        )*kg3_filter(),dtype=np.float64,
    )
    source/=source.mean()
    neutral=json.loads(
        (ROOT/"src/spektrafilm/data/filters/neutral_print_filters.json").read_text()
    )
    routes=[
        ("kodak_portra_400","kodak_portra_endura","neutral",[0,0,0],0,0,0,0),
        ("kodak_portra_400","kodak_portra_endura","gamma_082",[17,-23,31],.025,10,-8,1),
        ("fujifilm_pro_400h","kodak_2383","exhaustion_04",[-20,14,-11],.08,-12,24,-1),
        ("kodak_portra_400","kodak_2383","mixed",[30,40,-35],.12,28,-21,2),
        ("fujifilm_pro_400h","kodak_portra_endura","fast_slow",[-12,17,-8],.035,0,11,0),
        ("kodak_portra_400","kodak_portra_endura","rgb",[7,-10,22],.045,5,-13,-1),
    ]
    log_raw_samples=[
        [-1.5,-1.0,-0.7],
        [-0.55,-0.8,-0.35],
        [0.4,0.2,0.15],
    ]
    lines=[
        "// Upstream model/density_curves.py + couplers.py ACTUAL Python",
        "// 1x1 native nonspatial LUT-mode film H-D/DIR→enlarger→paper RGB.",
        "// Not camera RAW/Hanatos, spatial DIR, grain or full image.",
        "enum GeneratedSourceFilmDIRPrintReference {",
        "  struct Vector {",
        "    let film: String",
        "    let paper: String",
        "    let morphMode: String",
        "    let shift: [Double]",
        "    let preflashExposure: Double",
        "    let preflashM: Double",
        "    let preflashY: Double",
        "    let ev: Double",
        "    let filmLogRaw: [Double]",
        "    let initialFilmDensity: [Double]",
        "    let dirCorrectedLogRaw: [Double]",
        "    let sourceDevelopedFilmDensity: [Double]",
        "    let sourceRaw: [Double]",
        "    let sourceLogExposure: [Double]",
        "    let sourcePaperDensity: [Double]",
        "    let sourceXYZ: [Double]",
        "    let sourceLinearRGB: [Double]",
        "    let sourceCompressedRGB: [Double]",
        "    let sourceEncodedDisplayRGB: [Double]",
        "  }",
        "  static let vectors: [Vector] = [",
    ]
    count=0
    for film,paper,mode,shift,flash,flash_m,flash_y,ev in routes:
        f=json.loads((FILES/(film+".json")).read_text())
        p=json.loads((FILES/(paper+".json")).read_text())
        fd=f["data"];pd=p["data"]
        axis=np.asarray(fd["log_exposure"],dtype=np.float64)
        measured=np.asarray(fd["density_curves"],dtype=np.float64)
        normalized=measured-np.nanmin(measured,axis=0)
        assert np.isfinite(normalized).all()
        print_axis=np.asarray(pd["log_exposure"],dtype=np.float64)
        model=pd["density_curves_model"]
        fitted=apply_print_curves_morph(
            print_axis,
            DensityCurvesModel(model["model_type"],model["centers"],
                               model["amplitudes"],model["sigmas"]),
            settings(mode),profile_type=p["info"]["type"]
        )
        base=np.asarray(fd["base_density"],dtype=np.float64)
        dyes=np.asarray(fd["channel_density"],dtype=np.float64)
        paperSens=np.nan_to_num(
            10**np.asarray(pd["log_sensitivity"],dtype=np.float64)
        )
        cc=np.asarray(
            neutral.get(paper,{}).get("TH-KG3",{}).get(film,[0,65,55]),
            dtype=np.float64,
        )
        light=source*default_dichroic(cc+shift)
        prelight=source*default_dichroic(cc+[0,flash_m,flash_y])
        baseTrans=np.nan_to_num(10**(-base)*prelight,nan=0.)
        preflash=flash*np.einsum("l,lc->c",baseTrans,paperSens)
        for input_log_raw in log_raw_samples:
            log_raw=np.asarray(input_log_raw,dtype=np.float64)
            raw_image=log_raw.reshape(1,1,3).copy()
            initial=density.interpolate_exposure_to_density(
                raw_image,normalized,axis,gamma_factor=1.0
            )[0,0]
            correctedLog=log_raw-initial@M
            developed=couplers.apply_density_correction_dir_couplers(
                initial.reshape(1,1,3).copy(),raw_image,None,
                axis,normalized,params,"negative",gamma_factor=1.0
            )[0,0]
            # Explicit independently visible stages also verify that
            # the SOURCE pre-DIR corrected H-D and source DIR routine agree.
            preCurve=couplers.compute_density_curves_before_dir_couplers(
                normalized,axis,M,positive=False
            )
            direct=np.array([
                np.interp(correctedLog[ch],axis,preCurve[:,ch])
                for ch in range(3)
            ])
            assert np.max(np.abs(developed-direct))<1e-10

            raw=exposure_raw(developed,base,dyes,paperSens,light)
            logE=np.log10(
                np.maximum((np.maximum(raw+preflash,0)+1e-10)*2**ev,0)+1e-10
            )
            paperDensity=np.array([
                np.interp(logE[ch],print_axis,fitted[:,ch])
                for ch in range(3)
            ])
            xyz,linear,compressed,encoded=source_scan_print(
                p,paperDensity[np.newaxis,:]
            )
            encodedDisplay=np.clip(encoded,0,1)
            for value in (
                initial,correctedLog,developed,raw,logE,paperDensity,
                xyz,linear,compressed,encodedDisplay
            ):
                assert np.isfinite(value).all(),(film,paper,mode,value)
            lines.extend([
                "    Vector(",
                f'      film:{json.dumps(film)},paper:{json.dumps(paper)},',
                f'      morphMode:{json.dumps(mode)},shift:{array(shift)},',
                f'      preflashExposure:{flash},preflashM:{flash_m},',
                f'      preflashY:{flash_y},ev:{ev},',
                f'      filmLogRaw:{array(log_raw)},',
                f'      initialFilmDensity:{array(initial)},',
                f'      dirCorrectedLogRaw:{array(correctedLog)},',
                f'      sourceDevelopedFilmDensity:{array(developed)},',
                f'      sourceRaw:{array(raw)},',
                f'      sourceLogExposure:{array(logE)},',
                f'      sourcePaperDensity:{array(paperDensity)},',
                f'      sourceXYZ:{array(xyz)},',
                f'      sourceLinearRGB:{array(linear)},',
                f'      sourceCompressedRGB:{array(compressed)},',
                f'      sourceEncodedDisplayRGB:{array(encodedDisplay)}',
                "    ),",
            ])
            count+=1
    assert count==18
    lines+=["  ]","}"]
    OUTPUT.write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("PASS: 18 DIRECT SOURCE Python negative logE->source measured H-D->source nonspatial DIR->source optical printing/paper CDF->source XYZ/ACES/sRGB vectors")
    print("10 stage families x 54 channel samples. Uses actual model/couplers.py and model/density_curves.py modules. Not camera RAW/Hanatos, spatial DIR, Numba grain or full-image certification.")


if __name__=="__main__":
    main()
