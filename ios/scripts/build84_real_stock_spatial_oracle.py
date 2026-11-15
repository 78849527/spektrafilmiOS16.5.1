#!/usr/bin/env python3
"""Build84 batch2: original Python source and 256-node *real stock* DIR
chemistry, original FIR/YVV reflect edges and 2/3-Gaussian mixtures.
No synthetic re-implementation used as the reference.
"""
import ast
import json
import pathlib
import subprocess
import sys
from types import SimpleNamespace

import numpy as np
from opt_einsum import contract

from build84_original_film_dir_oracle import (
    ROOT, SOURCE_BLOBS, load_original, verify_fixed_source,
)

OTHER_PINS = {
    "runtime/params_builder.py": "a15dd5ce17d5f9960eb453bdbc81f899eb64f8f0",
    "utils/fast_gaussian_filter.py": "8918c673ea0fb3f5d9ae820ca85bf6db4aba457a",
}
# Pinned Python source stock measurements. Include paper profiles in the
# hash map so source edits never silently modify reference material.
PROFILE_BLOBS = {
    "fujifilm_c200.json": "a46e6413a5d2784a44fbd005738cab49cfffbbca",
    "fujifilm_crystal_archive_typeii.json": "ff172170a5d6ef8095eabda99ccc6f111fe7ea2f",
    "fujifilm_pro_400h.json": "56838db62865ff06c033e731f760d5e28210e592",
    "fujifilm_provia_100f.json": "ae08afb23dcc2a46507ef43e34cbf896b3303319",
    "fujifilm_velvia_100.json": "cbea6d15cae3ac19c1eff9d91da5490cadd49f39",
    "fujifilm_xtra_400.json": "5222f4f5a9076850ca64a41a441731087d8345ad",
    "kodak_2383.json": "f587b79bf4d3a599ee13989012f9cced02259495",
    "kodak_2393.json": "54adf037ba24c9ba22e23bc983fc1c539c935f48",
    "kodak_ektachrome_100.json": "8d187efca11b985fc54b56c8f9cb643ba523ccf0",
    "kodak_ektacolor_edge.json": "34a39e2a108b6c2a72b9e48d9c2f13ba351e473f",
    "kodak_ektar_100.json": "242e7e2ef2b041a878adfa82c38f306ff97e7f86",
    "kodak_endura_premier.json": "8f849d820176f8f90f1d66ceed339acd333c3a7c",
    "kodak_gold_200.json": "c4ee86767ca1ac69300537e443d9cacd4fd50e78",
    "kodak_kodachrome_64.json": "31f58cb1b6011ebb3fbbb65415a4eedefc5ebf7f",
    "kodak_portra_160.json": "1108a992efb068008caa06b0c3f338fc9d5c744a",
    "kodak_portra_400.json": "39f0fb62a8a55cdc3b9d22157cf72438bfab2199",
    "kodak_portra_800.json": "c05fefb7940de296bf79e823073a2382f5c2a6d9",
    "kodak_portra_800_push1.json": "176737fb0f21435583af1161a68c4c8debba752f",
    "kodak_portra_800_push2.json": "5b24db9da7e6cbab66bacfd8ed99911c9cb2c402",
    "kodak_portra_endura.json": "2f007f0ff276da104c4ca1fcb9f355558e64fb9a",
    "kodak_supra_endura.json": "ba63b1788fd2794b890856866355c166761fbdf1",
    "kodak_ultra_endura.json": "a207c74b4f9a7502935cae80b87d579b3c54ba8b",
    "kodak_ultramax_400.json": "9d2a64f8f917a4a9a6d3a58c52dd13864cce88b2",
    "kodak_verita_200d.json": "99607b450a78d89cf41786dcef6a53711a29267e",
    "kodak_vision3_200t.json": "8fc197eab9ce8754bd386a87e260cd2ac5f48185",
    "kodak_vision3_250d.json": "d54518ee2bed1c3f8673b8cae639dfacaed84ecd",
    "kodak_vision3_500t.json": "d770189f958512c7a0e8e7f6d324ff39c7e7ce68",
    "kodak_vision3_50d.json": "cf51b69d37169181288f8472d73258550807d402"
}
PROFILE_DIR = ROOT / "data/profiles"


def verify_extra_pins():
    verify_fixed_source()
    for name, expected in OTHER_PINS.items():
        actual = subprocess.check_output(
            ["git", "hash-object", str(ROOT / name)], text=True
        ).strip()
        assert actual == expected, ("SOURCE PIN DRIFT", name, actual)
    for name, expected in PROFILE_BLOBS.items():
        actual = subprocess.check_output(
            ["git", "hash-object", str(PROFILE_DIR / name)], text=True
        ).strip()
        assert actual == expected, ("STOCK PROFILE PIN DRIFT", name, actual)


def source_namespace():
    ns = {
        "np":np, "contract":contract, "RuntimePhotoParams":object,
        "_apply_halation_preset":lambda _:None
    }
    from dataclasses import dataclass
    ns["dataclass"] = dataclass
    load_original("runtime/params_schema.py", ["DirCouplersParams"], ns)
    load_original("runtime/params_builder.py", ["_apply_film_specifics"], ns)
    load_original("utils/fast_interp.py", ["fast_interp"], {
        **ns, "numba":SimpleNamespace(njit=lambda **kw:(lambda f:f),
                                     prange=range),
    })  # load separately into ns below to retain the function reference
    ns["numba"] = SimpleNamespace(njit=lambda **kw:(lambda f:f),
                                   prange=range)
    load_original("utils/fast_interp.py", ["fast_interp"], ns)
    load_original("model/density_curves.py",
                  ["interpolate_exposure_to_density"], ns)
    load_original("model/couplers.py", [
        "compute_dir_couplers_matrix",
        "compute_density_curves_before_dir_couplers",
        "compute_exposure_correction_dir_couplers",
    ], ns)
    return ns


def source_stock_oracle(ns):
    all_stocks = []
    for file in sorted(PROFILE_DIR.glob("*.json")):
        doc = json.loads(file.read_text(encoding="utf-8"))
        info, data = doc["info"], doc["data"]
        if info["stage"] != "filming":
            continue
        name, positive = info["stock"], info["type"] == "positive"
        params = ns["DirCouplersParams"]()
        fake = SimpleNamespace(
            film=SimpleNamespace(is_positive=positive, is_negative=not positive,
                                 info=SimpleNamespace(stock=name)),
            film_render=SimpleNamespace(dir_couplers=params),
        )
        ns["_apply_film_specifics"](fake)
        matrix = ns["compute_dir_couplers_matrix"](params) * params.amount
        original = np.asarray(data["density_curves"],dtype=np.float64)
        x = np.asarray(data["log_exposure"],dtype=np.float64)
        assert x.shape == (256,) and original.shape == (256,3)
        normalized = original - np.nanmin(original,axis=0)
        corrected = ns["compute_density_curves_before_dir_couplers"](
            normalized,x,matrix,positive=positive
        )
        assert np.all(np.isfinite(corrected))
        # Real measured axes and 256-node H-D, across endpoint and gamma
        # boundaries, with the same source fast_interp.
        ratios = [-0.20,0.0,0.09,0.21,0.43,0.57,0.82,0.99,1.2]
        raw = np.array([[
            [x[0]+(x[-1]-x[0])*r,
             x[0]+(x[-1]-x[0])*(1-r),
             x[0]+(x[-1]-x[0])*max(0,r-0.13)]
            for r in ratios
        ]],dtype=np.float64)
        gamma = np.array([0.85,1.0,1.2],dtype=np.float64)
        hd = ns["interpolate_exposure_to_density"](
            raw,normalized,x,gamma
        )
        all_stocks.append(dict(
            stock=name,positive=positive,
            logAxis=x.tolist(),curves=normalized.reshape(-1).tolist(),
            matrix=matrix.reshape(-1).tolist(),
            beforeDIR=corrected.reshape(-1).tolist(),
            raw=raw.reshape(-1).tolist(),
            gamma=gamma.tolist(),hd=hd.reshape(-1).tolist()
        ))
    assert len(all_stocks)==20, f"expected 20 film stocks, got {len(all_stocks)}"
    return all_stocks


def no_jit(*args, **kwargs):
    if args and callable(args[0]):
        return args[0]
    return lambda f:f


def original_gaussian_namespace():
    name="utils/fast_gaussian_filter.py"
    tree = ast.parse((ROOT / name).read_text(encoding="utf-8"),filename=name)
    keep = {
        "_gaussian_kernel_1d", "_reflect", "_fir_2d_fused",
        "_gaussian_filter_2d_small", "_yvv_coeffs", "_iir_horizontal",
        "_iir_vertical", "_gaussian_filter_2d_large", "_dispatch_2d",
        "_apply_per_channel", "fast_gaussian_filter",
        "fast_exponential_filter",
    }
    constants = {"_STRIP_H","_IIR_COL_CHUNK",
                 "_EXPONENTIAL_GAUSSIAN_FITS","SMALL_SIGMA_MAX"}
    body = []
    for n in tree.body:
        if isinstance(n,ast.FunctionDef) and n.name in keep:
            n.decorator_list=[]
            body.append(n)
        elif isinstance(n,(ast.Assign,ast.AnnAssign)):
            targets = n.targets if isinstance(n,ast.Assign) else [n.target]
            if any(isinstance(t,ast.Name) and t.id in constants for t in targets):
                body.append(n)
    assert len([n for n in body if isinstance(n,ast.FunctionDef)])==len(keep)
    compiled=ast.fix_missing_locations(ast.Module(body=body,type_ignores=[]))
    ns={"np":np,"njit":no_jit,"prange":range}
    exec(compile(compiled,name,"exec"),ns)
    return ns


def spatial_oracle(ns):
    samples=[]
    for width,height in ((1,1),(1,7),(7,1),(3,5),(8,6)):
        # Fully deterministic RGB frame with nonuniform, signed values.
        image=np.array([
            [[((x+2)*(y+1)*(ch+3)%17-8)/13.0 + 0.023*y
              for ch in range(3)] for x in range(width)]
            for y in range(height)],dtype=np.float64)
        for sigma in (0.0,0.2,1.2,2.99,3.0,7.25):
            actual=ns["fast_gaussian_filter"](image,sigma)
            samples.append(dict(kind="gaussian",width=width,height=height,
                input=image.reshape(-1).tolist(),scale=[sigma]*3,
                output=actual.reshape(-1).tolist()))
        for decay,fit in (((0.1,1.1,4.0),2),((0.2,2.1,5.0),3)):
            actual=ns["fast_exponential_filter"](
                image,np.array(decay,dtype=np.float64),n_gaussians=fit
            )
            samples.append(dict(kind="exponential",width=width,height=height,
                input=image.reshape(-1).tolist(),scale=list(decay),
                fit=fit,output=actual.reshape(-1).tolist()))
    return samples


def source_complete_dir_cases(ns, stock_records):
    """Run original couplers.py complete density-to-log exposure correction.

    Covers both positive/negative film, spatial-disabled chemistry,
    source FIR -> YVV crossover, exponential-tail contribution and narrow
    1px dimensions. The Swift counterpart uses actual production Double
    convolution and Build84 original inhibitor chemistry.
    """
    by_name={stock["stock"]:stock for stock in stock_records}
    frames=[]
    for name,positive in (("kodak_portra_400",False),
                          ("fujifilm_provia_100f",True)):
        matrix=np.asarray(by_name[name]["matrix"],dtype=np.float64).reshape(3,3)
        dmax=np.array([1.7,1.9,2.1],dtype=np.float64)
        for width,height,core,tail,weight in (
            (1,7,0.0,4.0,0.06),
            (7,1,0.4,0.5,0.06),
            (3,5,2.99,1.5,0.0),
            (3,5,3.0,6.0,0.06),
            (7,4,7.25,20.0,0.18),
            (2,8,0.9,5.0,0.11),
        ):
            density=np.array([
                [[0.11+((x+2)*(y+3)*(c+1)%11)*0.085
                  for c in range(3)] for x in range(width)]
                for y in range(height)],dtype=np.float64)
            log_raw=np.array([
                [[-1.2+((x+1)*(y+5)*(c+2)%17)*0.11
                  for c in range(3)] for x in range(width)]
                for y in range(height)],dtype=np.float64)
            actual=ns["compute_exposure_correction_dir_couplers"](
                log_raw,density,dmax,matrix,
                diffusion_size_pixel=core,
                diffusion_tail_size_pixel=tail,
                diffusion_exp_tail_weight=weight,
                positive=positive
            )
            assert np.isfinite(actual).all()
            frames.append(dict(
                stock=name,positive=positive,
                width=width,height=height,core=core,tail=tail,weight=weight,
                matrix=matrix.reshape(-1).tolist(),
                maximum=dmax.tolist(),density=density.reshape(-1).tolist(),
                rawLog=log_raw.reshape(-1).tolist(),
                corrected=actual.reshape(-1).tolist()
            ))
    return frames


def main(output_path):
    verify_extra_pins()
    original=source_namespace()
    filters=original_gaussian_namespace()
    stocks=source_stock_oracle(original)
    spatial=spatial_oracle(filters)
    original.update({"fast_gaussian_filter":filters["fast_gaussian_filter"],
                     "fast_exponential_filter":filters["fast_exponential_filter"]})
    dir_stages=source_complete_dir_cases(original,stocks)
    pathlib.Path(output_path).write_text(
        json.dumps({"stocks":stocks,"spatial":spatial,"dirStages":dir_stages},
                   separators=(",",":"),allow_nan=False),
        encoding="utf-8"
    )
    print("ORIGINAL SOURCE AST PASS stocks=",len(stocks),
          "256-node curves=",len(stocks)*256*3,
          "spatial cases=",len(spatial),"full DIR stages=",len(dir_stages),
          "exact source hashes pinned=",len(PROFILE_BLOBS)+len(OTHER_PINS)+len(SOURCE_BLOBS))


if __name__ == "__main__":
    main(sys.argv[1])
