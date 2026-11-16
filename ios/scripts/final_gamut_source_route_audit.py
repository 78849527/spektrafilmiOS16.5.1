#!/usr/bin/env python3
"""Scope/production-route guard: this is NOT complete source certification."""
from pathlib import Path
r=Path(__file__).resolve().parents[2]
def get(x):return (r/x).read_text()
ui=get("ios/SpektraFilmPort/ContentView.swift")
g=get("ios/SpektraFilmPort/Build81OriginalInputGamut.swift")
panel=get("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
phys=get("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
project=get("ios/project.yml")
assert "sourcePhysicalCAM16DefaultGamutEnabled = false" in ui
assert "p.sourceOutputGamut=Build89OriginalOutputGamut.Settings()" in ui
assert "sourcePhysicalCAM16DefaultGamutEnabled" in panel
assert "sourceOutputGamut: Build89OriginalOutputGamut.Settings? = nil" in phys
assert "return try compressOklch(xy,knee:knee,locus:locus)" in g
assert "sourcePhysicalInputOklchEnabled = false" in ui
assert "p.sourceInputGamutAlgorithm = .oklch" in ui
assert "sourcePhysicalInputOklchEnabled" in panel
assert "inputGamutAlgorithm:sourceInputGamutAlgorithm" in get("ios/SpektraFilmPort/SpectralPhysics.swift")
assert "algorithm:inputGamutAlgorithm" in get("ios/SpektraFilmPort/Build82OriginalSpectralRuntime.swift")
assert "var sourceInputGamutAlgorithm: Build81OriginalInputGamut.Algorithm = .xy" in phys
assert "private static func cmaxNode(" in g
assert "for _ in 0..<18" in g
assert "0.05+0.95*Double(LIndex)/63.0" in g
assert "Build89OriginalOutputGamut.Settings()" in ui
assert 'MARKETING_VERSION: "1.8.76"' in project
assert 'CURRENT_PROJECT_VERSION: "110"' in project
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
print("PASS FINAL CLOSURE A: source input Oklch native route and original CAM16 opt-in on exact physical engine; old defaults unchanged; no full-source certification.")
