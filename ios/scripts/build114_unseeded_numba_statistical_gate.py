#!/usr/bin/env python3
"""Build114 original *unseeded* Numba prange statistical gate.

This runs the actual pinned original fast_stats.py on FOUR real workers;
it does not silently replace production Swift's seeded one-worker route,
and it does not claim bit-identical unseeded outputs.
"""
from __future__ import annotations
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path

import numpy as np
import numba

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src/spektrafilm/utils/fast_stats.py"
OUT = ROOT / "ios/build/release/build114-unseeded-numba-source-statistics.json"


def load_source():
    spec = importlib.util.spec_from_file_location("build114_original_fast_stats", SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stats(a):
    a = np.asarray(a, dtype=np.float64).ravel()
    assert np.isfinite(a).all(), "original unseeded prange nonfinite"
    return {"count": int(a.size), "mean": float(a.mean()), "variance": float(a.var())}


def close(label, values, expected_mean, expected_var, mean_tol, var_tol):
    actual = stats(values)
    assert abs(actual["mean"]-expected_mean) < mean_tol, (label,"mean",actual)
    assert abs(actual["variance"]-expected_var) < var_tol, (label,"variance",actual)
    return {"label": label, "expected_mean": expected_mean,
            "expected_variance":expected_var, "actual": actual,
            "mean_tolerance":mean_tol, "variance_tolerance":var_tol}


def main():
    assert int(os.getenv("NUMBA_NUM_THREADS","0")) == 4, (
        "Run explicitly with NUMBA_NUM_THREADS=4"
    )
    numba.set_num_threads(4)
    assert numba.get_num_threads()==4, "Numba did not execute four workers"
    n=65_536
    source=load_source()
    # Warmup is intentionally unseeded; independent prange workers retain
    # their own RNG states after compilation.
    source.warmup_fast_stats()
    lambdas=np.full(n,8.0,np.float64)
    poisson_a=source.fast_poisson(lambdas)
    poisson_b=source.fast_poisson(lambdas)
    assert np.any(poisson_a != poisson_b), "Unseeded Python output unexpectedly frozen"
    binomial_a=source.fast_binomial(np.full(n,32,np.int64),
                                   np.full(n,0.4,np.float64))
    lognorm_a=source.fast_lognormal_from_mean_std(
        np.full(n,1.0,np.float64),np.full(n,0.3,np.float64))
    # The iOS production sampler performs the same full-array
    # Poisson(8) phase followed by binomial thinning with p=.4.
    compound_a=source.fast_binomial(
        source.fast_poisson(np.full(n,8.0,np.float64)),
        np.full(n,0.4,np.float64))
    cases=[
        close("source_prange_Poisson_lambda8",poisson_a,8.0,8.0,0.12,0.35),
        close("source_prange_Binomial_n32_p0.4",binomial_a,12.8,7.68,0.12,0.35),
        close("source_prange_compound_thinned_Poisson8_p04",compound_a,3.2,3.2,0.12,0.30),
        close("source_prange_lognormal_mean1_std0.3",lognorm_a,1.0,0.09,0.018,0.016)
    ]
    summary={
        "schema":1,"source_sha256":hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "numba_num_threads":4,"source_is_actual_fast_stats_py":True,
        "source_default_unseeded_prange_statistical_gate":"PASS",
        "source_prange_repeated_output_identical":False,
        "cases":cases,
        "ios_source_unseeded_parallel_rng_certified":False,
        "reason":"Swift has only a seeded single-worker production analogue; exact unseeded parallel Python field cannot be bit-identical or certified from source-only statistics.",
    }
    OUT.parent.mkdir(parents=True,exist_ok=True)
    OUT.write_text(json.dumps(summary,indent=2,sort_keys=True)+"\n")
    print("PASS Build114 original 4-worker unseeded Numba statistics:",OUT)
    print("NOT CERTIFIED iOS default multiworker prange parity")


if __name__=="__main__":
    main()
