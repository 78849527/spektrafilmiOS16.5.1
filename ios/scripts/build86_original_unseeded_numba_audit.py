#!/usr/bin/env python3
"""Build86: observe the *original* unseeded multiworker Numba prange RNG.

This is a source-only distribution audit, not a replacement native RNG or
a claim that unordered cross-platform draws can be bitwise replayed.
Uses original fast_stats.py functions without patches, original SHA pinned.
"""
from __future__ import annotations
import hashlib
import importlib.util
import json
from pathlib import Path

import numba
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
FAST = ROOT / "src/spektrafilm/utils/fast_stats.py"
FAST_SHA = "9e80d29ce6b9f7820ae70f5c09da15edfaa70a0d"

def git_blob(path):
    content = path.read_bytes()
    return hashlib.sha1(
        b"blob " + str(len(content)).encode() + b"\0" + content
    ).hexdigest()

def main():
    assert git_blob(FAST) == FAST_SHA, "Source fast_stats changed"
    spec = importlib.util.spec_from_file_location("source_fast_stats_build86", FAST)
    original = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(original)
    max_threads = numba.get_num_threads()
    workers = [t for t in (1,2,4) if t <= max_threads]
    # Fully deterministic density/probability inputs; intentionally do not
    # supply/override a RNG seed for the actual ORIGINAL prange draws.
    h,w = 96,128
    rates = np.tile(np.array([0.25,3.75,17.5,29.5,30.0,75.0,220.0,
                              0.0], dtype=np.float64), (h,w//8))
    probability = np.tile(np.array([0.1,0.24,0.47,0.75,0.9,0.33,0.52,
                                    0.98], dtype=np.float64), (h,w//8))
    source = []
    # Warm at one worker before audit to avoid conflating initial JIT
    # construction and the first stochastic production execution.
    numba.set_num_threads(1)
    original.fast_poisson(np.ones((2,2),dtype=np.float64))
    original.fast_binomial(
        np.ones((2,2),dtype=np.int64),
        np.full((2,2),0.5,dtype=np.float64),
    )
    original.fast_lognormal_from_mean_std(
        np.ones((2,2,3),dtype=np.float64),
        np.full((2,2,3),0.085,dtype=np.float64),
    )
    for threads in workers:
        numba.set_num_threads(threads)
        iterations = []
        for trial in range(4):
            poisson = original.fast_poisson(rates)
            binomial = original.fast_binomial(poisson,probability)
            micro = original.fast_lognormal_from_mean_std(
                np.ones((h,w,3),dtype=np.float64),
                np.full((h,w,3),0.085,dtype=np.float64),
            )
            assert poisson.shape == rates.shape
            assert binomial.shape == rates.shape
            assert micro.shape == (h,w,3)
            assert np.isfinite(micro).all()
            assert np.all(poisson>=0)
            assert np.all(binomial>=0)
            assert np.all(binomial<=poisson)
            max_delta = np.max(np.abs(
                poisson.astype(np.float64) - rates
            ))
            iterations.append(dict(
                poisson_mean=float(poisson.mean()),
                poisson_variance=float(poisson.var()),
                binomial_mean=float(binomial.mean()),
                micro_mean=float(micro.mean()),
                micro_std=float(micro.std()),
                image_sha256=hashlib.sha256(
                    poisson.tobytes()+binomial.tobytes()+micro.tobytes()
                ).hexdigest(),
                poisson_max_abs_from_lambda=float(max_delta)
            ))
        # Numba source is unseeded in the pipeline. It should not look
        # like a constant/replayed field, even across repeated calls.
        unique=len({x["image_sha256"] for x in iterations})
        assert unique>1, "Original unseeded Numba unexpectedly replayed exact array"
        source.append(dict(workers=threads,unique_draws=unique,
                           trials=iterations))
    result=dict(
        sourceBlob=FAST_SHA,sourceNumba=numba.__version__,
        sourceNumpy=np.__version__,shape=[h,w,3],workers=source,
        claim="Source prange distribution observation ONLY; no iOS or cross-worker bitwise parity"
    )
    target=ROOT / "ios/verification/build86-original-unseeded-numba-statistics.json"
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(json.dumps(result,indent=2,sort_keys=True)+"\n")
    print("PASS Build86 original unseeded prange statistics:",
          [(x["workers"],x["unique_draws"]) for x in source],
          "source SHA pinned")
    print("NOT CERTIFIED: iOS parallel worker bitstreams or even distribution match; "
          "source is stochastic, native stream requires independent validation.")

if __name__ == "__main__":
    main()
