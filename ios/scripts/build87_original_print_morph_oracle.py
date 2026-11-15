#!/usr/bin/env python3
"""Original fitted s023 paper morph curves for EVERY real printing stock.

The entire original original src/spektrafilm/utils/morph_curves.py algorithm
is executed via AST; only heavyweight unrelated profile IO imports are
omitted. Do not modify numerical function bodies, sigma floor, Brent root.
Also writes a minimal Swift test-only model table using the exact measured
three-layer JSON parameters. The production OriginalPrintMorph.swift is
compiled and executed unchanged by native macOS Swift.
"""
import ast
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import sys
from types import SimpleNamespace
import numpy as np
from scipy.optimize import brentq as _brentq
from scipy.stats import norm as _norm_dist

ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/"src/spektrafilm"
PROFILE_SHA={
    "fujifilm_crystal_archive_typeii":"ff172170a5d6ef8095eabda99ccc6f111fe7ea2f",
    "kodak_2383":"f587b79bf4d3a599ee13989012f9cced02259495",
    "kodak_2393":"54adf037ba24c9ba22e23bc983fc1c539c935f48",
    "kodak_ektacolor_edge":"34a39e2a108b6c2a72b9e48d9c2f13ba351e473f",
    "kodak_endura_premier":"8f849d820176f8f90f1d66ceed339acd333c3a7c",
    "kodak_portra_endura":"2f007f0ff276da104c4ca1fcb9f355558e64fb9a",
    "kodak_supra_endura":"ba63b1788fd2794b890856866355c166761fbdf1",
    "kodak_ultra_endura":"a207c74b4f9a7502935cae80b87d579b3c54ba8b",
}
MORPH_SOURCE_SHA="15ab56feb426b1010811848b6a527fc07a97909b"

def sha(path):
    raw=path.read_bytes()
    return hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()

def original():
    path=SRC/"utils/morph_curves.py"
    assert sha(path)==MORPH_SOURCE_SHA,"Original morph code changed"
    tree=ast.parse(path.read_text(encoding="utf8"))
    values={
        "_signed_z","_gumbel_matched_cdf","_layer_cdf",
        "_evaluate_channel_density","_evaluate_fitted_density",
        "_speed_layer_indices","_channel_gamma_factor",
        "_developer_exhaustion_center_offset","_morph_channel_params",
        "apply_print_curves_morph"
    }
    nodes=[]
    for node in tree.body:
        if isinstance(node,ast.FunctionDef) and node.name in values:
            node.decorator_list=[]
            nodes.append(node)
        elif isinstance(node,ast.Assign) and any(
            isinstance(t,ast.Name) and t.id in (
                "SIGMA_FLOOR","_GUMBEL_LOCATION","_GUMBEL_WIDTH"
            ) for t in node.targets
        ):
            nodes.append(node)
    assert len(nodes)==13,(len(nodes),[n.name for n in nodes if isinstance(n,ast.FunctionDef)])
    ns={
        "np":np,"math":math,
        "_brentq":_brentq,"_norm_dist":_norm_dist,
        "DensityCurvesModel":object,
        "dataclass":dataclass
    }
    exec(compile(ast.fix_missing_locations(ast.Module(body=nodes,
        type_ignores=[])),str(path),"exec"),ns)
    return ns["apply_print_curves_morph"]

def fmt(values):
    return "["+",".join(format(float(v),".17g")
                        for v in np.asarray(values,dtype=np.float64).reshape(-1))+"]"

def config(**kwargs):
    defaults=dict(active=True,gamma_factor=1.0,gamma_factor_fast=1.0,
                  gamma_factor_slow=1.0,gamma_factor_red=1.0,
                  gamma_factor_green=1.0,gamma_factor_blue=1.0,
                  developer_exhaustion=0.0)
    defaults.update(kwargs)
    return defaults

CONFIGS=[
    config(active=False),
    config(),
    config(gamma_factor=4.25),
    config(gamma_factor=0.093),
    config(gamma_factor_fast=2.4,gamma_factor_slow=0.8),
    config(gamma_factor_fast=1.7,gamma_factor_slow=0.1),
    config(gamma_factor_red=4.5,gamma_factor_green=0.6,gamma_factor_blue=1.2),
    config(developer_exhaustion=1.0),
    config(gamma_factor=1.8,gamma_factor_fast=0.83,
           gamma_factor_slow=1.16,developer_exhaustion=0.67),
    config(gamma_factor=4.1,gamma_factor_fast=0.7,gamma_factor_slow=2.1,
           gamma_factor_red=0.62,gamma_factor_green=1.28,
           gamma_factor_blue=2.15,developer_exhaustion=0.28),
]

def main(dest_json,dest_swift):
    run=original()
    papers=SRC/"data/profiles"
    items=[]
    models=[]
    for stock,pin in PROFILE_SHA.items():
        path=papers/(stock+".json")
        assert sha(path)==pin, "Original paper source profile changed "+stock
        profile=json.loads(path.read_text(encoding="utf8"))
        assert profile["info"]["stage"]=="printing",stock
        model=profile["data"]["density_curves_model"]
        assert model["model_type"]=="cdfs",stock
        centers=np.asarray(model["centers"],dtype=np.float64)
        amplitudes=np.asarray(model["amplitudes"],dtype=np.float64)
        sigmas=np.asarray(model["sigmas"],dtype=np.float64)
        assert centers.shape==(3,3)
        assert amplitudes.shape==(3,3)
        assert sigmas.shape==(3,3)
        models.append(f'    "{stock}":Model(centers:{fmt(centers)},'
                      f'amplitudes:{fmt(amplitudes)},sigmas:{fmt(sigmas)}),')
        obj=SimpleNamespace(centers=centers,amplitudes=amplitudes,
                            sigmas=sigmas,n_layers=3)
        axis=np.asarray(profile["data"]["log_exposure"],dtype=np.float64)
        assert len(axis)==256
        sample_x=np.array([
            axis[0]-0.25,axis[0],axis[1],axis[57]+0.001,
            axis[123],axis[190]-0.003,axis[254],axis[255],
            axis[255]+0.25
        ],dtype=np.float64)
        for positive in (False,True):
            for case,settings in enumerate(CONFIGS):
                params=SimpleNamespace(**settings)
                fitted=run(
                    axis,obj,params,
                    profile_type="positive" if positive else "negative"
                )
                assert fitted.shape==(256,3)
                assert np.isfinite(fitted).all(),(stock,case,positive)
                interpolate=np.stack([
                    np.interp(sample_x,axis,fitted[:,ch])
                    for ch in range(3)
                ],axis=1)
                items.append(dict(
                    stock=stock,positive=positive,params=settings,
                    axis=axis.tolist(),density=fitted.reshape(-1).tolist(),
                    sampleX=sample_x.tolist(),
                    sampleDensity=interpolate.reshape(-1).tolist()
                ))
    assert len(items)==len(PROFILE_SHA)*len(CONFIGS)*2==160
    Path(dest_json).write_text(json.dumps(
        dict(cases=items,pins=PROFILE_SHA,morph_sha=MORPH_SOURCE_SHA),
        separators=(",",":"),allow_nan=False),encoding="utf8")
    Path(dest_swift).write_text(
        "import Foundation\n"
        "// Original source JSON Float64 print CDF model parameters.\n"
        "enum GeneratedPrintMorphData {\n"
        "  struct Model {\n"
        "    let centers:[Double]\n"
        "    let amplitudes:[Double]\n"
        "    let sigmas:[Double]\n"
        "  }\n"
        "  static let models:[String:Model] = [\n"+
        "\n".join(models)+"\n  ]\n}\n",
        encoding="utf8")
    print("ORIGINAL PRINT MORPH AST PASS: 8 real print stocks × ",
          "2 polarities × 10 original parameter modes = 160 full ",
          "256×3 fitted CDF curves; including gamma>3 and exhaustion=1")

if __name__=="__main__":
    main(sys.argv[1],sys.argv[2])
