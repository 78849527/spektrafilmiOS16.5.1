#!/usr/bin/env python3
"""Reference original Spektrafilm optical enlarger CC filter and preflash.

Uses EXACT source equations and the previously verified original spectral
source:
  model.color_filters.DichroicFilters.apply_cc
  runtime.services.filter_enlarger_source.EnlargerService
  runtime.stages.printing.PrintingStage._compute_raw_preflash
  PrintingStage._exposure_factor (geomean normalization)
Reference pairs cover ALL 16 original negative film x 8 printing stocks.
"""
from pathlib import Path
import json
import numpy as np
from generate_original_optics import kg3_filter,default_dichroic,WL
import colour

ROOT=Path(__file__).resolve().parents[2]
DEST=ROOT/"ios/SpektraFilmPort/GeneratedEnlargerReference.swift"
DATA=ROOT/"src/spektrafilm/data/profiles"
DB=json.loads((ROOT/"src/spektrafilm/data/filters/neutral_print_filters.json").read_text())
# Orig blackbody 3400K + exact measured Schott KG3, then mean normalized.
illum=np.asarray(colour.colorimetry.blackbody_spectral_radiance(WL*1e-9,3400),dtype=float)
illum=illum*kg3_filter()
illum/=illum.mean()
def fmt(a):
    return "["+",".join(format(float(x),".17g") for x in np.asarray(a).ravel())+"]"
def flat_finite(a):
    return np.nan_to_num(np.asarray(a,dtype=float),
                         nan=0.0,posinf=0.0,neginf=0.0)
def light(film,concentrations,spectrum):
    base=flat_finite(film["base_density"])
    cmy=flat_finite(film["channel_density"])
    assert cmy.shape==(81,3)
    return spectrum*10**(-(base+cmy@np.asarray(concentrations)))
def main():
    doc={p.stem:json.loads(p.read_text()) for p in DATA.glob("*.json")}
    film_ids=sorted(k for k,v in doc.items()
                    if v["info"]["stage"]=="filming"
                    and v["info"]["type"]=="negative")
    paper_ids=sorted(k for k,v in doc.items() if v["info"]["stage"]=="printing")
    assert len(film_ids)==16 and len(paper_ids)==8
    lines=[
        "// Original Spektrafilm 128-film/print optical CC+preflash Python refs.",
        "enum GeneratedEnlargerReference {",
        "    struct Pair {",
        "        let film: String; let paper: String",
        "        let cc: [Double]; let mainSpectral: [Double]",
        "        let mainRaw: [Double]; let preflashRaw: [Double]",
        "        let midgrayFactor: Double",
        "    }",
        "    static let pairs: [Pair] = ["
    ]
    for medium in paper_ids:
        for film_id in film_ids:
            paper=doc[medium]["data"]
            negative=doc[film_id]["data"]
            cc=DB.get(medium,{}).get("TH-KG3",{}).get(film_id,[0,65,55])
            cc=np.asarray(cc,dtype=float)
            main_cc=cc+np.array([0,12,-9])
            flash_cc=cc+np.array([0,6,-7])
            filtered=illum*default_dichroic(main_cc)
            flash=illum*default_dichroic(flash_cc)
            sensitivity=10**flat_finite(paper["log_sensitivity"])
            film_light=light(negative,[0.2,0.36,0.70],filtered)
            raw=film_light@sensitivity
            raw_flash=(light(negative,[0,0,0],flash)@sensitivity)*0.15
            midraw=light(negative,[0.18,0.18,0.18],filtered)@sensitivity
            norm=np.exp(np.mean(np.log(np.maximum(midraw,1e-10))))
            assert np.isfinite(raw).all() and np.isfinite(raw_flash).all()
            lines.append(
                f'        Pair(film: "{film_id}", paper: "{medium}", '
                f'cc: {fmt(cc)}, '
                f'mainSpectral: {fmt(filtered[[0,16,34,49,80]])}, '
                f'mainRaw: {fmt(raw)}, '
                f'preflashRaw: {fmt(raw_flash)}, '
                f'midgrayFactor: {norm:.17g}),'
            )
    lines.extend(["    ]","}"])
    DEST.write_text("\n".join(lines)+"\n",encoding="utf-8")
    print("PASS: 128 original CC filtered illuminants and density-derived main/flash raw optical response")
    print("PASS: preflash 0.15, M CC +6, Y CC -7, main M +12, Y -9, 3400K KG3")
    print("Generated enlarger reference:",DEST.stat().st_size,"bytes")
if __name__=="__main__":
    main()
