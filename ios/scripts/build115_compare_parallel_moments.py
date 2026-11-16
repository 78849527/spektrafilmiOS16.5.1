#!/usr/bin/env python3
"""Independent original NumPy/Numba vs Swift parallel moment comparison.

Both streams are independently seeded and cannot have matching pixels.
Compare the actual original Numba source distribution and independently
measured production Swift source-equation sampler, NOT their RNG bitstreams.
"""
import json
from pathlib import Path

root=Path(__file__).resolve().parents[2]
src=json.loads((root/"ios/build/release/build114-unseeded-numba-source-statistics.json").read_text())
swift=json.loads((root/"ios/build/release/build115-swift-parallel-stats.json").read_text())
assert src["numba_num_threads"]==4
assert swift["workerCount"]==4
assert swift["bitReplayDiagnosticPassed"]
assert swift["independentUnseededOutputsDiffer"]
assert not swift["exactPythonUnseededBitParityCertified"]

ref={case["label"]:case["actual"] for case in src["cases"]}
particle=ref["source_prange_compound_thinned_Poisson8_p04"]
micro=ref["source_prange_lognormal_mean1_std0.3"]
dist=[
    ("compound Poisson+Binomial",swift["particles"],particle,0.14,0.32),
    ("lognormal",swift["microstructure"],micro,0.025,0.021),
]
output=[]
for label,actual,original,mean_tolerance,var_tolerance in dist:
    mean_delta=abs(actual["mean"]-original["mean"])
    variance_delta=abs(actual["variance"]-original["variance"])
    assert actual["count"]>=65536 and original["count"]>=65536
    assert mean_delta<mean_tolerance,(label,"mean",mean_delta)
    assert variance_delta<var_tolerance,(label,"variance",variance_delta)
    output.append({"name":label,"swift":actual,"python_source":original,
                   "mean_delta":mean_delta,"variance_delta":variance_delta,
                   "mean_tolerance":mean_tolerance,"variance_tolerance":var_tolerance,
                   "result":"STATISTICAL_PASS"})
report={
    "schema":1,"comparison":"independently sampled SOURCE_Numba4 vs Swift4",
    "cases":output,
    "source_statistical_equivalence_4worker":True,
    "python_unseeded_per_pixel_rng_parity":False,
    "real_ios1651_rss_or_runtime_certified":False,
    "status":"CI_MACOS_SWIFT_VS_UNMODIFIED_PYTHON_STATISTICS_PASS"
}
dest=root/"ios/build/release/build115-python-swift-parallel-statistics.json"
dest.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n")
print("PASS Build115 original source Numba4 vs Swift4 independent statistical moments")
print("NOT CERTIFIED Python unseeded worker scheduling/bitstream and real iPhone until LOG+JSON")
