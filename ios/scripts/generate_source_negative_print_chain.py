#!/usr/bin/env python3
"""Native-checkable contiguous SOURCE negative CMY -> paper H-D -> RGB truth.

Stages from original SpektraFilm: source measured profile + dichroic optics
including NaN->zero transmission and base-only preflash, ORIGINAL
apply_print_curves_morph (s023 3-layer CDF) sampled on all 256 log exposure
points, original fast_interp scalar equivalent (np.interp on monotone nodes),
and original source paper XYZ / linear-sRGB / ACES / CCTF. The last output
is clipped to the same display [0,1] domain as native production.

Not an input RAW/film-DIR simulation or full image with diffusion/grain;
test input is ALREADY DEVELOPED negative CMY.
"""
import json
from pathlib import Path

import colour
import numpy as np
from generate_original_optics import ROOT, default_dichroic, kg3_filter
from generate_print_optics import exposure_raw
from generate_print_morph import (
    DensityCurvesModel, PrintCurvesMorphParams, apply_print_curves_morph
)
from generate_source_print_scanner_parity import source_scan_print

OUT=ROOT/"ios/SpektraFilmPort/GeneratedSourceNegativePrintChainReference.swift"
FILES=ROOT/"src/spektrafilm/data/profiles"


def array(v):
    a=np.asarray(v,dtype=np.float64).ravel()
    assert np.isfinite(a).all(), "Nonfinite source negative chain stage"
    return "["+",".join(format(float(x),".17g") for x in a)+"]"


def settings(mode):
    if mode=="neutral": return PrintCurvesMorphParams()
    if mode=="gamma_082": return PrintCurvesMorphParams(gamma_factor=.82)
    if mode=="exhaustion_04":
        return PrintCurvesMorphParams(developer_exhaustion=.4)
    if mode=="mixed":
        return PrintCurvesMorphParams(
            gamma_factor=1.13,gamma_factor_fast=.93,gamma_factor_slow=1.07,
            gamma_factor_red=1.04,gamma_factor_green=.94,
            gamma_factor_blue=1.08,developer_exhaustion=.25
        )
    if mode=="fast_slow":
        return PrintCurvesMorphParams(
            gamma_factor_fast=1.20,gamma_factor_slow=.85
        )
    if mode=="rgb":
        return PrintCurvesMorphParams(
            gamma_factor_red=1.10,gamma_factor_green=.93,
            gamma_factor_blue=1.15
        )
    raise ValueError(mode)


def main():
    source=np.asarray(
        colour.colorimetry.blackbody_spectral_radiance(
            np.arange(380,781,5,dtype=np.float64)*1e-9,3400
        ) * kg3_filter(),
        dtype=np.float64,
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
    # Identical developed CMY inputs for each of the six optical
    # configurations, exercising shadows, mid and saturated negatives.
    density_vectors=[
        [0.11,0.52,0.84],
        [0.28,0.41,0.68],
        [0.58,0.18,1.10],
    ]
    lines=[
        "// ORIGINAL Python source negative CMY -> optical print -> s023",
        "// absolute CDF H-D -> paper XYZ -> ACES sRGB, not RAW/DIR/image.",
        "enum GeneratedSourceNegativePrintChainReference {",
        "  struct Vector {",
        "    let film: String",
        "    let paper: String",
        "    let morphMode: String",
        "    let shift: [Double]",
        "    let preflashExposure: Double",
        "    let preflashM: Double",
        "    let preflashY: Double",
        "    let ev: Double",
        "    let filmDensity: [Double]",
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
        baseTrans=10**(-base)*prelight
        baseTrans=np.nan_to_num(baseTrans,nan=0.)
        preflash=flash*np.einsum("l,lc->c",baseTrans,paperSens)
        model=pd["density_curves_model"]
        assert model["model_type"]=="cdfs"
        fitted=apply_print_curves_morph(
            np.asarray(pd["log_exposure"],dtype=np.float64),
            DensityCurvesModel(model["model_type"],
                               model["centers"],model["amplitudes"],
                               model["sigmas"]),
            settings(mode),profile_type=p["info"]["type"]
        )
        assert fitted.shape==(256,3)
        axis=np.asarray(pd["log_exposure"],dtype=np.float64)
        for originalDensity in density_vectors:
            d=np.asarray(originalDensity,dtype=np.float64)
            raw=exposure_raw(d,base,dyes,paperSens,light)
            # Reference 1.0: normalize_print_exposure=false and
            # print_exposure_compensation=false in the native source path.
            pre=np.maximum(raw+preflash,0.)+1e-10
            logE=np.log10(np.maximum(pre*2**ev,0.)+1e-10)
            paperDensity=np.array([
                np.interp(logE[ch],axis,fitted[:,ch]) for ch in range(3)
            ])
            xyz,linear,compressed,encoded=source_scan_print(
                p,paperDensity[np.newaxis,:]
            )
            # Production display clipping is explicit and separately named.
            encodedDisplay=np.clip(encoded,0,1)
            values=(raw,logE,paperDensity,xyz,linear,compressed,encodedDisplay)
            for v in values:assert np.isfinite(v).all(),(film,paper,mode,v)
            lines.extend([
                "    Vector(",
                f'      film:{json.dumps(film)},paper:{json.dumps(paper)},',
                f'      morphMode:{json.dumps(mode)},shift:{array(shift)},',
                f'      preflashExposure:{flash},preflashM:{flash_m},',
                f'      preflashY:{flash_y},ev:{ev},',
                f'      filmDensity:{array(d)},',
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
    OUT.write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("PASS: 18 source-contiguous negative CMY optical print -> 256-node s023 H-D -> scanned XYZ/ACES/sRGB vectors (6 routes x 3 densities)")
    print("Scope: post-film-developed CMY, direct no-LUT enlarger, no spatial effects, source optional ACES and explicit display clamp; NOT RAW/full-image/default CAM16.")


if __name__=="__main__":
    main()
