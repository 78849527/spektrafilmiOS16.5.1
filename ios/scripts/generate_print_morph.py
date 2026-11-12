#!/usr/bin/env python3
"""Generate original Spektrafilm s023 print morphology fitted params and refs.

Only all 8 original printing profiles. Numeric reference arrays are computed
with upstream spektrafilm.utils.morph_curves.apply_print_curves_morph, not
with a separately reimplemented approximation.
"""
from pathlib import Path
import json
import sys
import numpy as np

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"src"))
from spektrafilm.utils.morph_curves import (
    PrintCurvesMorphParams, apply_print_curves_morph
)
from spektrafilm.profiles.io import DensityCurvesModel

DATA=ROOT/"src/spektrafilm/data/profiles"
OUTPUT=ROOT/"ios/SpektraFilmPort/GeneratedPrintMorphData.swift"

def values(a):
    return "["+",".join(format(float(x),".16g") for x in np.asarray(a,dtype=np.float64).ravel())+"]"

def main():
    configs=[
      ("neutral",PrintCurvesMorphParams()),
      ("gamma_082",PrintCurvesMorphParams(gamma_factor=0.82)),
      ("gamma_125",PrintCurvesMorphParams(gamma_factor=1.25)),
      ("fast_slow",PrintCurvesMorphParams(gamma_factor_fast=1.2,gamma_factor_slow=0.85)),
      ("rgb",PrintCurvesMorphParams(gamma_factor_red=1.10,gamma_factor_green=0.93,gamma_factor_blue=1.15)),
      ("exhaustion_04",PrintCurvesMorphParams(developer_exhaustion=0.4)),
      ("mixed",PrintCurvesMorphParams(gamma_factor=1.13,gamma_factor_fast=0.93,
                      gamma_factor_slow=1.07,gamma_factor_red=1.04,
                      gamma_factor_green=0.94,gamma_factor_blue=1.08,
                      developer_exhaustion=0.25)),
    ]
    lines=[
      "// Original s023 morphology fitted parameters; source SHA stays in GeneratedSpectralData.",
      "// Reference samples produced by ORIGINAL Python apply_print_curves_morph.",
      "enum GeneratedPrintMorphData {",
      "  struct Model {",
      "    let centers: [Double]",
      "    let amplitudes: [Double]",
      "    let sigmas: [Double]",
      "  }",
      "  struct Reference {",
      "    let stock: String",
      "    let sampleLE: [Double]",
      "    let mode: String",
      "    let densityAtSamples: [Double]",
      "  }",
      "  static let models: [String: Model] = [",
    ]
    stocks=[];refs=[]
    for path in sorted(DATA.glob("*.json")):
        doc=json.loads(path.read_text())
        info,data=doc["info"],doc["data"]
        if info["stage"]!="printing":continue
        stock=info["stock"]
        model=data["density_curves_model"]
        if model["model_type"]!="cdfs":raise ValueError(stock+" unsupported model")
        c=np.asarray(model["centers"],dtype=float)
        a=np.asarray(model["amplitudes"],dtype=float)
        sig=np.asarray(model["sigmas"],dtype=float)
        assert c.shape==(3,3) and a.shape==(3,3) and sig.shape==(3,3)
        lines.append(f'    "{stock}": Model(centers: {values(c)}, amplitudes: {values(a)}, sigmas: {values(sig)}),')
        stocks.append((stock,info,data))
    lines.extend(["  ]","  static let references: [Reference] = ["])
    for stock,info,data in stocks:
        m=data["density_curves_model"]
        model=DensityCurvesModel(
            model_type=m["model_type"],centers=m["centers"],
            amplitudes=m["amplitudes"],sigmas=m["sigmas"]
        )
        le=np.asarray(data["log_exposure"],dtype=float)
        sel=np.asarray([0,53,127,193,255],dtype=np.int64)
        for name,settings in configs:
            modeled=apply_print_curves_morph(
                le,model,settings,profile_type=info["type"]
            )
            assert modeled.shape==(256,3) and np.isfinite(modeled).all()
            sample=modeled[sel].reshape(-1)
            lines.append(f'    Reference(stock: "{stock}", sampleLE: {values(le[sel])}, mode: "{name}", densityAtSamples: {values(sample)}),')
            refs.append((stock,name))
    lines.extend(["  ]","}"])
    OUTPUT.write_text("\n".join(lines)+"\n",encoding="utf-8")
    assert len(stocks)==8 and len(refs)==56
    print("PASS: 8 original printing models (6 paper, 2 motion print film) with 3-layer s023 CDF")
    print("PASS: 56 upstream reference profiles x morph modes, 5 exposure nodes x 3 channels")
    print("Generated print s023 morphology:",OUTPUT.stat().st_size,"bytes")

if __name__=="__main__":
    main()
