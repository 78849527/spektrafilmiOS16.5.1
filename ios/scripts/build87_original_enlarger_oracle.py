#!/usr/bin/env python3
"""Original optical enlarger: original source AST color filter, material dye,
preflash, 4 normalization modes and PrintingStage.expose() no-diffusion branch.
Real film / paper 81-wavelength Float64 measurements, raw source blobs pinned.
"""
import ast
import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace as NS
import numpy as np
import scipy
from opt_einsum import contract

ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/"src/spektrafilm"
PINS={
    "model/color_filters.py":"73849be82f7e32e21cd9bf3e116ba244a931188b",
    "runtime/stages/printing.py":"93859d705507276638653850338086dc64c6157c",
    "utils/conversions.py":"2ca9cfc6138278a9fb8c32c0ca191e384b2cff6e",
    "model/develop.py":"938ff7045c87ca77c0182f7608b66093ae87f421",
}

def git_sha(path):
    raw=path.read_bytes()
    return hashlib.sha1(b"blob "+str(len(raw)).encode()+b"\0"+raw).hexdigest()

def source(ns,name,names):
    path=SRC/name
    if PINS[name] is not None:
        assert git_sha(path)==PINS[name],("SOURCE DRIFT",name,git_sha(path))
    tree=ast.parse(path.read_text())
    nodes=[n for n in tree.body if isinstance(n,(ast.ClassDef,ast.FunctionDef))
           and n.name in names]
    assert len(nodes)==len(names),(name,len(nodes),names)
    for node in nodes:
        if isinstance(node,ast.FunctionDef):
            node.decorator_list=[]
    exec(compile(ast.fix_missing_locations(ast.Module(
        body=nodes,type_ignores=[])),str(path),"exec"),ns)
    return ns

def main(destination):
    ns={"np":np,"scipy":scipy,"contract":contract}
    source(ns,"model/color_filters.py",
           ["create_combined_dichroic_filter","DichroicFilters"])
    source(ns,"utils/conversions.py",["density_to_light"])
    source(ns,"model/develop.py",["compute_density_spectral"])
    source(ns,"runtime/stages/printing.py",["PrintingStage","_exposure_factor"])
    filters=ns["DichroicFilters"].__new__(ns["DichroicFilters"])
    wavelengths=np.arange(380.0,781.0,5.0,dtype=np.float64)
    filters.wavelengths=wavelengths
    filters.create_custom_filters()
    assert filters.filters.shape==(81,3)

    # A source-neutral positive illuminant for exercising every actual
    # measured wavelength, independent of optional Python Colour import.
    light=np.exp(-0.5*((wavelengths-590.0)/155.0)**2)+0.18
    light/=light.mean()
    films=("kodak_portra_400","fujifilm_pro_400h",
           "kodak_vision3_500t","kodak_ektar_100")
    papers=("kodak_portra_endura","kodak_2383")
    cases=[]
    for film_name in films:
        film=json.loads((SRC/"data/profiles"/(film_name+".json")).read_text())
        base=np.asarray(film["data"]["base_density"],dtype=np.float64)
        dye=np.asarray(film["data"]["channel_density"],dtype=np.float64)
        density=np.array([0.14,0.23,0.36],dtype=np.float64)
        ref0=base+np.einsum("lc,c->l",dye,
                                np.array([0.32,0.32,0.32]))
        ref1=base+np.einsum("lc,c->l",dye,
                                np.array([0.48,0.36,0.28]))
        for paper_name in papers:
            paper=json.loads((SRC/"data/profiles"/(paper_name+".json")).read_text())
            sens=np.nan_to_num(
                10.0**np.asarray(paper["data"]["log_sensitivity"],
                                  dtype=np.float64))
            for normalize in (False,True):
                for compensate in (False,True):
                    for flash in (0.0,0.24,1.2):
                        # Override the original schema's 0/65/55 neutral
                        # controls as allowed by source EnlargerParams.
                        neutral=[11.0,63.5,51.0]
                        printing=[neutral[0]+4.0,neutral[1]-9.0,
                                  neutral[2]+6.0]
                        preshift=[neutral[0],neutral[1]+5.0,
                                  neutral[2]-3.0]
                        filt=filters.apply_cc(light,printing)
                        prelight=filters.apply_cc(light,preshift)
                        service=NS(
                            density_spectral_midgray=ref0[None,None,:],
                            density_spectral_midgray_comp=ref1[None,None,:],
                            enlarger_filtered_illuminant=lambda _:filt,
                            preflash_filtered_illuminant=lambda _:prelight
                        )
                        params=NS(
                            illuminant="TH-KG3",
                            c_filter_neutral=neutral[0],m_filter_neutral=neutral[1],
                            y_filter_neutral=neutral[2],
                            c_filter_shift=4.0,m_filter_shift=-9.0,
                            y_filter_shift=6.0,
                            preflash_m_filter_shift=5.0,
                            preflash_y_filter_shift=-3.0,
                            preflash_exposure=flash,
                            normalize_print_exposure=normalize,
                            print_exposure_compensation=compensate,
                            print_exposure=2.0**0.6,
                            diffusion_filter=NS(active=False)
                        )
                        stage=ns["PrintingStage"].__new__(ns["PrintingStage"])
                        stage._film=NS(data=NS(base_density=base,
                                              channel_density=dye,
                                              density_curves=np.asarray(
                                                  film["data"]["density_curves"])))
                        stage._film_render=NS(grain=NS(density_min=[.03,.03,.03]))
                        stage._enlarger=params
                        stage._enlarger_service=service
                        stage._print=NS(data=NS(log_sensitivity=np.asarray(
                            paper["data"]["log_sensitivity"],dtype=np.float64)))
                        stage._resize_service=NS(pixel_size_um=9.0)
                        stage._settings=NS(use_enlarger_lut=False)
                        stage._color_reference_service=NS(
                            black_white_printing_exposure_correction=lambda:1.0)
                        stage._lut_service=NS(
                            spectral_compute_enlarger=lambda values,
                                spectral_calculation,**kw:
                                spectral_calculation(values))
                        ns["standard_illuminant"]=lambda _:light
                        # Source diffusion is the identity when inactive;
                        # isolated test explicitly locks that branch off.
                        assert not params.diffusion_filter.active
                        ns["apply_diffusion_filter_um"]=lambda raw,*args,**kw:raw
                        first=ns["_exposure_factor"](sens,filt,
                                                     service.density_spectral_midgray)
                        comp=ns["_exposure_factor"](sens,filt,
                                                    service.density_spectral_midgray_comp)
                        ref=stage._compute_exposure_factor_midgray(sens,filt)
                        pre=stage._compute_raw_preflash(light,sens).reshape(-1)
                        logged=stage._film_cmy_to_print_log_raw(
                            density[None,None,:]).reshape(-1)
                        final=stage.expose(density[None,None,:]).reshape(-1)
                        spectral=ns["compute_density_spectral"](
                            dye,density[None,None,:],base_density=base)
                        transmission=ns["density_to_light"](
                            spectral,filt)
                        raw=contract("ijk,kl->ijl",transmission,sens).reshape(-1)
                        output=dict(
                            film=film_name,paper=paper_name,
                            neutral=neutral,shifts=[4.0,-9.0,6.0],
                            preShifts=[5.0,-3.0],flash=flash,
                            normalize=normalize,compensate=compensate,
                            light=light.tolist(),filtered=filt.tolist(),
                            base=np.nan_to_num(base,nan=0).tolist(),
                            baseValid=np.isfinite(base).tolist(),
                            sensitivity=sens.tolist(),
                            sourcePreflash=pre.tolist(),
                            midRaw=(1.0/first)*np.ones(3),
                            compRaw=(1.0/comp)*np.ones(3),
                            sourceDivisor=1.0/ref,
                            raw=raw.tolist(),rawLog=logged.tolist(),
                            paperEV=0.6,final=final.tolist()
                        )
                        assert np.isfinite(final).all()
                        cases.append(output)
    assert len(cases)==len(films)*len(papers)*12
    Path(destination).write_text(
        json.dumps({"cases":cases,"source":PINS},
                   separators=(",",":"),allow_nan=False),encoding="utf8")
    print("ORIGINAL PYTHON 81nm PRINT SOURCE PASS:",
          len(cases),"real film-paper exposure cases, four midgray modes,",
          "preflash 0/.24/1.2, direct source spectral print")

if __name__=="__main__":
    main(sys.argv[1])
