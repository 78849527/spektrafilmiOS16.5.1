#!/usr/bin/env python3
"""Build105-HF: static + actual upstream-manifest source gate regression.

This cannot replace physical iPhone Swift/Numba full-image execution.
It catches Build103's false universal missing-seed assertion before IPA.
"""
from pathlib import Path
import json

root = Path(__file__).resolve().parents[2]
parity = (root / "ios/tests/SourcePhysicalImageParity.swift").read_text()
grain = (root / "ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift").read_text()
project = (root / "ios/project.yml").read_text()
fixtures = root / "ios/verification/generated-physical-v1.8.22/manifest.json"
manifest = json.loads(fixtures.read_text())
cases = manifest["cases"]
assert len(cases) == 4, "original four-case fixture missing"
expected = {
    "kodak_neutral_fir": (12.0, False),
    "fujifilm_2383_iir": (4.0, False),
    "kodak_endura_morph": (9.0, False),
    "kodak_grain_micro_yvv": (0.35, True),
}
assert {c["name"] for c in cases} == set(expected), "source cases changed"
for case in cases:
    pixel, enabled = expected[case["name"]]
    assert case["pixelUM"] == pixel
    assert case["numba_micro_enabled"] == enabled
    assert (30.0 * 0.001 / pixel > 0.05) is enabled
# Source regression must be isolated to the existing upstream-derived
# predicate; no masks, no test bypass, no change to Python data/threshold.
assert "if fixture.numba_micro_enabled {\n                    do {" in parity
assert 'denied.sourceGrain.numbaSeed=nil' in parity
assert 'catch OriginalSourcePhysicalGrain.Failure.invalid {}' in parity
assert "seedFree.rgb == developed.rgb" in parity
assert "inactiveMicroSeedFreeCases==3" in parity
assert "activeMicroMissingSeedRejectedCases==1" in parity
assert "requestedMicroStd>0.05" in grain
assert "if settings.useFastStats && settings.fastStatsSeed != microSeed" in grain
assert 'CURRENT_PROJECT_VERSION: "105"' in project
assert 'MARKETING_VERSION: "1.8.72"' in project
print("PASS Build105-HF static SOURCE gate: 3 Python inactive-micro fixtures accept absent Numba seed with bit-exact RGB; 1 real active-micro fixture requires seed. Full device rerun REQUIRED.")
