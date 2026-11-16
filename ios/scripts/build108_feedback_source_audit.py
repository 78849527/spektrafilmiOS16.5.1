#!/usr/bin/env python3
"""Build107: static + actual upstream-manifest source gate regression.

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
assert 'CURRENT_PROJECT_VERSION: "108"' in project
assert 'MARKETING_VERSION: "1.8.74"' in project
print("PASS Build107 static SOURCE gate: 3 Python inactive-micro fixtures accept absent Numba seed with bit-exact RGB; 1 real active-micro fixture requires seed. Full device rerun REQUIRED.")

# Build106+107 must be a single actual device report with TWO attachments.
app = (root / "ios/SpektraFilmPort/ContentView.swift").read_text()
ui = (root / "ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
source = (root / "ios/SpektraFilmPort/Build107CombinedDeviceFeedback.swift").read_text()
memory = (root / "ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift").read_text()
grain = (root / "ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift").read_text()
ledger = (root / "ios/SpektraFilmPort/Build106SourceMemoryLedger.swift").read_text()
assert app.count("Build107CombinedDeviceFeedback.capture(") == 1
assert app.count("Build107CombinedDeviceFeedback.write(") == 1
assert "activeSheet = .shareFeedback(pair.log,pair.json)" in app
assert "ActivitySheet(items: [log,json])" in app
assert "onRunBuild107CombinedFeedback()" in ui
assert "Build106 + 107：一键生成真机反馈 LOG + JSON" in ui
assert "Build103VerificationEvidence.capture(" in source
assert "Build104DeviceGrainEvidence.capture(" in source
assert "source_budget_24_cases_pass" in source
assert "let measured=checkBuild107()" in source
assert "task_info(mach_task_self_" in source
assert 'full13MPOperationMeasured:false' in source
assert 'fullPythonOriginalCertified:false' in source
assert 'firstFailure:measured && touched ? nil' in source
assert 'status:passed ?' in source
assert 'code:103' in source
assert 'stageObserverBytesPerPixel: UInt64 = 960' in ledger
assert memory.count('Build106SourceMemoryLedger.additional(') == 2
assert grain.index('stageObserver?("sourceGrainDyeClouds",out)') < grain.index('layerInputs.removeAll(keepingCapacity:false)') < grain.index('let microStd=settings.microstructureNM')
assert 'MARKETING_VERSION: "1.8.74"' in project
assert 'CURRENT_PROJECT_VERSION: "108"' in project
print("PASS Build107 combined device evidence contract: previous 28+20 parity, Build106 24 budget scenarios, Build107 bounded RSS, one UUID LOG+JSON; NEVER 13MP certification.")


# Build108 actual large frame path MUST be the production source optical
# renderer; NOT a mocked memory-only test. No device pass until true report.
stress = (root / "ios/SpektraFilmPort/Build108SourceOpticalDeviceStress.swift").read_text()
assert 'width:1000,height:1000,grain:true' in stress
assert 'width:1600,height:1250,grain:false' in stress
assert 'OriginalSourcePhysicalImage.developInPlace(' in stress
assert 'stageDoubleObserver:nil' in stress
assert 'Build91PhysicalMemory.validate(p)' in stress
assert 'let sampler=ResidentSampler()' in stress
assert 'repeating:.milliseconds(25)' in stress
assert 'actualOutputSampleCount' in stress
assert 'previousBuild106107: Build107CombinedDeviceFeedback.Report' in stress
assert 'Build107CombinedDeviceFeedback.capture(' in stress
assert 'Build107CombinedDeviceFeedback.logText(' in stress
assert 'full13MPOperationMeasured:false' in stress
assert 'largeImagePythonNumericParityCertified:false' in stress
assert 'fullPythonOriginalCertified:false' in stress
assert 'Build106-107-108-device-feedback-' in stress
assert 'runBuild108FullFrameFeedback()' in app and 'runBuild108FullFrameFeedback()' in ui
assert 'ActivitySheet(items: [log,json])' in app
print("PASS Build108: actual production 1MP grain and 2MP native Float64 optical stage, conservative budget and 25ms RSS, 106-108 one-pair device feedback, no fake 13MP/Python big-frame certification.")
