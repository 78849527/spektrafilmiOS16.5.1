#!/usr/bin/env python3
"""Build110 device four-combination evidence route, source-only audit.

Actual certification requires installing the unsigned IPA after signing
and providing a true iOS 16.5.1 JSON+LOG.
"""
from pathlib import Path
from build_ci_version_floor import minimum_build, minimum_minor
r=Path(__file__).resolve().parents[2]
def source(p):return (r/p).read_text()
ui=source("ios/SpektraFilmPort/ContentView.swift")
panel=source("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
code=source("ios/SpektraFilmPort/Build110SourceGamutDeviceEvidence.swift")
project=source("ios/project.yml")
assert "runBuild110GamutEvidence()" in ui
assert "onRunBuild110GamutEvidence()" in panel
assert "onRunBuild110GamutEvidence: {" in ui
assert "let switches=Build110SourceGamutDeviceEvidence.SwitchSnapshot(" in ui
for prop in ("inputOklchToggle:model.sourcePhysicalInputOklchEnabled",
             "outputCAM16Toggle:model.sourcePhysicalCAM16DefaultGamutEnabled",
             "pixelIOEnabled:model.sourcePixelIOEnabled",
             "cameraRawMethod:model.sourceCameraRawMethod.rawValue"):
    assert prop in ui,prop
assert 'Mode(name:"00_xy_legacy_output",oklch:false,cam16:false)' in code
assert 'Mode(name:"10_oklch_only",oklch:true,cam16:false)' in code
assert 'Mode(name:"01_cam16_only",oklch:false,cam16:true)' in code
assert 'Mode(name:"11_oklch_and_cam16",oklch:true,cam16:true)' in code
assert "try OriginalSourcePhysicalImage.developInPlace(" in code
assert "p.sourceInputGamutAlgorithm = mode.oklch ? .oklch : .xy" in code
assert "p.sourceOutputGamut = mode.cam16" in code
assert "actualFloat64OpticalRender:result != nil" in code
assert "sampledPeakResidentBytes:peak" in code
assert "meanAbsoluteDeltaFromBaseline:delta" in code
assert "Build108SourceOpticalDeviceStress.capture(" in code
assert "Build110SourceGamutDeviceEvidence.write(" in ui
assert "Build106-107-108-110-gamut-four-mode-" in code
assert minimum_build(project, 112)
assert minimum_minor(project, 78)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
print("PASS Build110 phone JSON+LOG four actual source Float64 gamut variants, toggles snapshot, production SHA and prior Build108 report integration. Device certification NOT RUN in CI.")
