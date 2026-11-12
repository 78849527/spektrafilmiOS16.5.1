#!/usr/bin/env python3
"""Generate original Spektrafilm s023 print morphology fitted params and refs.

Only all 8 original printing profiles. Numeric reference arrays are computed
with upstream spektrafilm.utils.morph_curves.apply_print_curves_morph, not
with a separately reimplemented approximation.
"""
from pathlib import Path
import json
import sys
import importlib.util
import types
import numpy as np

ROOT=Path(__file__).resolve().parents[2]

# Import the ORIGINAL s023 source module without executing the parent
# spektrafilm package __init__ (which eagerly imports unrelated RAW
# exiv2 libraries). The only runtime source dependency required by the
# algorithm is a simple fitted-model data container.
class DensityCurvesModel:
    def __init__(self, model_type, centers, amplitudes, sigmas):
        self.model_type=model_type
        self.centers=np.asarray(centers,dtype=float)
        self.amplitudes=np.asarray(amplitudes,dtype=float)
        self.sigmas=np.asarray(sigmas,dtype=float)
    @property
    def n_layers(self):
        return self.centers.shape[1]
    @property
    def n_channels(self):
        return self.centers.shape[0]

for package in ("spektrafilm","spektrafilm.profiles","spektrafilm.utils"):
    obj=types.ModuleType(package)
    obj.__path__=[]
    sys.modules[package]=obj
profile_shim=types.ModuleType("spektrafilm.profiles.io")
profile_shim.DensityCurvesModel=DensityCurvesModel
sys.modules["spektrafilm.profiles.io"]=profile_shim
source_path=ROOT/"src/spektrafilm/utils/morph_curves.py"
spec=importlib.util.spec_from_file_location(
    "spektrafilm.utils.morph_curves",source_path
)
source_module=importlib.util.module_from_spec(spec)
sys.modules[spec.name]=source_module
spec.loader.exec_module(source_module)
PrintCurvesMorphParams=source_module.PrintCurvesMorphParams
apply_print_curves_morph=source_module.apply_print_curves_morph

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
      "  struct ExposureReference {",
      "    let stock: String",
      "    let yBlack: Double",
      "    let yWhite: Double",
      "    let exposureEVOriginal: Double",
      "    let exposureEVRounded: Double",
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
    lines.append("  ]")
    lines.append("  static let exposureReferences: [ExposureReference] = [")
    for ix,(stock,info,data) in enumerate(stocks):
        def reference_ev(y_black,y_white,le,curves,base):
            # Original source removes sRGB CCTF piecewise. 0.01 is
            # in the LOW linear segment (0.01 / 12.92), not the
            # (0.01+0.055)/1.055 power branch.
            target_black=0.01/12.92
            target_white=((0.98+0.055)/1.055)**2.4
            slope=(target_white-target_black)/(y_white-y_black+1e-10)
            intercept=target_black-slope*y_black
            before=(0.184-intercept)/slope
            d_corr=-np.log10(max(1e-10,before))
            d_base=-np.log10(0.184)
            corr=np.interp(d_corr-base,curves,le)
            initial=np.interp(d_base-base,curves,le)
            return float(np.clip(np.log2(10**(corr-initial)),-4,4))
        le=np.asarray(data["log_exposure"],dtype=float)
        curves=np.asarray(data["density_curves"],dtype=float).mean(axis=1)
        base=float(np.asarray(data["base_density"],dtype=float).mean())
        # The original project stores Float64 profile curves, whereas
        # the iOS port intentionally packs original numbers to Float32.
        # Use the same source NumPy formula for both data precision paths.
        le32=np.asarray(data["log_exposure"],dtype=np.float32).astype(float)
        curves32=np.asarray(data["density_curves"],dtype=np.float32).astype(float).mean(axis=1)
        base32=float(np.asarray(data["base_density"],dtype=np.float32).astype(float).mean())
        for case in range(2):
            y_black=0.018+ix*0.002+case*0.009
            y_white=0.79+ix*0.008-case*0.024
            original_ev=reference_ev(y_black,y_white,le,curves,base)
            rounded_ev=reference_ev(y_black,y_white,le32,curves32,base32)
            lines.append(f'    ExposureReference(stock: "{stock}", yBlack: {y_black:.17g}, yWhite: {y_white:.17g}, exposureEVOriginal: {original_ev:.17g}, exposureEVRounded: {rounded_ev:.17g}),')
    lines.extend(["  ]","}"])
    OUTPUT.write_text("\n".join(lines)+"\n",encoding="utf-8")
    assert len(stocks)==8 and len(refs)==56
    print("PASS: 8 original printing models (6 paper, 2 motion print film) with 3-layer s023 CDF")
    print("PASS: 56 upstream reference profiles x morph modes, 5 exposure nodes x 3 channels")
    print("PASS: 16 original NumPy inverse-H&D EV references in source Float64 and iOS Float32 precision")
    print("Generated print s023 morphology:",OUTPUT.stat().st_size,"bytes")

if __name__=="__main__":
    main()
