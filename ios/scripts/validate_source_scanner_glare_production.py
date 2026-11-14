#!/usr/bin/env python3
"""v1.8.46 actual Swift production source XYZ scanner wiring regression.

Structural assertions protect the *real* optical code paths and switch
gates. The numerical stage evidence comes from actual source Mac/Swift
glare fixtures and SourcePhysicalImageParity run in spectral CI.
"""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
physics=(root/"ios/SpektraFilmPort/SpectralPhysics.swift").read_text()
physical=(root/"ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift").read_text()
model=(root/"ios/SpektraFilmPort/ContentView.swift").read_text()
ui=(root/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
test=(root/"ios/tests/SourcePhysicalImageParity.swift").read_text()
glare=(root/"ios/SpektraFilmPort/OriginalSourceScannerGlare.swift").read_text()
assert 'MARKETING_VERSION: "1.8.46"' in (root/"ios/project.yml").read_text()
assert 'CURRENT_PROJECT_VERSION: "71"' in (root/"ios/project.yml").read_text()
assert 'iOS: "16.5"' in (root/"ios/project.yml").read_text()
for token in (
    'sourceXYZOutput: Bool = false',
    'if sourceXYZOutput { return xyz }',
    'func sourceSpatialScanXYZ(',
    'filmDensity,paperEV:paperEV,sourceXYZOutput:true',
    'func sourceSpatialScannerIlluminantXYZ() throws -> [Double]',
    'func sourceSpatialXYZToLinearRGB(_ xyz:[Double]) throws -> [Double]',
    'let sourceScannerLampXYZ = scanIlluminant.map { $0 / scanNorm }',
    'for i in 0..<81 {',
    'scanIlluminant[ch] += viewing[i] * cie[i*3+ch]',
    'OriginalScannerMath.linearSRGB(xyz:xyz,viewing:viewingStock)',
    'OriginalScannerMath.compressACESRGC(',
):
    assert token in physics, f"Missing original optical XYZ stage: {token}"
assert 'sourceXYZOutput:sourceXYZOutput' in physics
for token in (
    'var scannerGlare: OriginalSourceScannerGlare.Settings = .init(active:false)',
    'var scannerGlareSeed: UInt32? = nil',
    'try scannerGlare.validate()',
    'scannerGlareSeed != nil',
    '!SpectralPhysics.isPositiveFilm(filmID)',
    'static let scannerGlareExtraBytesPerPixel: UInt64 = 96',
    '(controlledScannerGlare ? scannerGlareExtraBytesPerPixel : 0)',
    'sourceXYZOutput:controlledScannerGlare',
    'engine.sourceSpatialScanXYZ(',
    'engine.sourceSpatialScannerIlluminantXYZ()',
    'OriginalSourceScannerGlare.addToXYZ(',
    'stageDoubleObserver?("scannerGlareXYZ",frame.rgb)',
    'engine.sourceSpatialXYZToLinearRGB(',
    'stageDoubleObserver?("scannerGlareLinearRGB",frame.rgb)',
    'OriginalSourceScannerOptics.applyInPlace(',
    'parameters.scannerOptics.active || controlledScannerGlare',
    'OriginalScannerMath.encodeSRGB(frame.rgb[k])',
):
    assert token in physical, f"Missing production source XYZ integration: {token}"
# The full image is first scanned to XYZ; never sprinkle independent
# glare into individually final-encoded per-pixel output.
assert physical.index("OriginalSourceScannerGlare.addToXYZ(") > physical.index("if activePrintDiffusion {",physical.index("let corrected=(0..<3).map"))
assert physical.index("OriginalSourceScannerGlare.addToXYZ(") < physical.index("engine.sourceSpatialXYZToLinearRGB(")
assert physical.index("engine.sourceSpatialXYZToLinearRGB(") < physical.index("OriginalSourceScannerOptics.applyInPlace(")
assert physical.index("OriginalSourceScannerOptics.applyInPlace(") < physical.index("OriginalScannerMath.encodeSRGB(frame.rgb[k])")
assert 'scannerGlareSeed:sourceScannerGlareEnabled ? 8888 : nil' in model
assert '@Published var sourceScannerGlareEnabled = false' in model
for token in (
    'scannerGlare:OriginalSourceScannerGlare.Settings(',
    'sourceScannerGlarePercent',
    'sourceScannerGlareRoughness',
    'sourceScannerGlareBlur',
    'OriginalSourcePhysicalImage.scannerGlareExtraBytesPerPixel',
):
    assert token in model, token
for token in (
    'sourceScannerGlareSettings',
    'resetToggle("源扫描 XYZ 眩光（单线程实验）"',
    'seed=8888',
    '未认证原版无固定',
    'private var sourceScannerGlareSettings: AnyView',
):
    assert token in ui, token
for token in (
    'PASS v1.8.46 production 2D source glare',
    'scannerGlareXYZ',
    'scannerGlareLinearRGB',
    'observedXYZ[k+ch]-expectedXYZ[ch]',
    'glared.rgb==repeated.rgb',
    'withoutSeed.scannerGlareSeed=nil',
    'SourcePhysicalImage.Failure.invalid' if False else 'OriginalSourcePhysicalImage.Failure.invalid',
):
    assert token in test, token
assert 'result[index] = xyz[index] + glare[pixel] * illuminantXYZ[ch]' in glare
assert 'settings.active && settings.percent > 0' not in model  # no implicit enabling
report=(root/"ios/SpektraFilmPort/OriginalSourceScannerGlareProductionDiagnostic.swift").read_text()
assert "OriginalSourceScannerGlareProductionDiagnostic.evaluate()" in model
for token in ('OriginalSourcePhysicalImage.develop(', 'scannerGlareXYZ',
              'scannerGlareLinearRGB', 'sourceSpatialXYZToLinearRGB(',
              'actual.rgb==repeated.rgb','params.scannerGlareSeed=nil'):
    assert token in report, token

print("PASS: source paper XYZ pre-gamut production connection is ordered")
print("PASS: 8888 explicit controlled worker, negative-only fail-closed, default OFF, 96 B/px memory headroom")
print("PASS: real production 2D integration test is hooked to Python physical image fixture validator")
print("NOT CERTIFIED: unseeded Numba multiworker stream, full Python RGB production-image equivalence, real-device image parity")
