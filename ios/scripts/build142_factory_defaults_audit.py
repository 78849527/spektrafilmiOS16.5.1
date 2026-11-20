#!/usr/bin/env python3
"""Build142: factory reset exactly follows current source defaults.

No hardcoded duplicate table: discovers all adjustment declarations and
asserts reset covers every one with its literal current initializer.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
app = (root / "ios/SpektraFilmPort/ContentView.swift").read_text()
ui = (root / "ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
project = (root / "ios/project.yml").read_text()
from build_ci_version_floor import minimum_build, minimum_minor

assert minimum_build(project, 142)
assert minimum_minor(project, 108)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project

decl = app.split('    @Published var filmExposureEV = 0.0', 1)[1].split(
    '    @Published var sourceFilmHalationScale = 1.0', 1
)[0]
decl = '    @Published var filmExposureEV = 0.0' + decl + (
    '    @Published var sourceFilmHalationScale = 1.0'
)
pattern = re.compile(r'(?m)^\s*@Published var (\w+)(?:\s*:[^=\n]+)?\s*=\s*([^\n]+)')
definitions = dict((name, value.strip()) for name, value in pattern.findall(decl))
# One existing multi-line, strongly typed optical source input choice.
assert '@Published var sourceCameraRawMethod:' in decl
assert 'SpectralPhysics.CameraRawMethod = .hanatos2025' in decl
definitions['sourceCameraRawMethod'] = '.hanatos2025'

block = app.split('    func resetAllProcessingToDefaults() throws {', 1)[1].split(
    '    /// A display-only preference;', 1
)[0]
reset_section = block.split('        // Camera/Photos/Files input and crop', 1)[0]
assignments = dict(
    (name, value.strip())
    for name, value in re.findall(
        r'(?m)^\s*([A-Za-z_]\w*)\s*=\s*([^\n]+)', reset_section
    )
)
assert len(definitions) == 100, (
    "Adjustments have changed; update factory reset to cover all source fields",
    len(definitions)
)
for name, default in definitions.items():
    assert name in assignments, f"Missing factory reset: {name}"
    assert assignments[name] == default, (
        name, assignments[name], "original default", default
    )
assert len([name for name in definitions if name in assignments]) == 100

# After all defaults are restored, only the explicitly supported RAW
# source dependency overrides may remain on, NEVER the obsolete 8-bit route.
raw = block.split('        if rawMode {\n            strength=1.0',1)[1].split(
    '        rawFullResolutionPreview=false',1
)[0]
for prerequisite in (
    "hanatosOriginalPrecisionEnabled=true",
    "originalScannerEnabled=true",
    "originalPrintOpticsEnabled=true",
    "spatialDIREnabled=true",
    "spatialDIRSourceConvolutionEnabled=true",
    "sourcePixelIOEnabled=true",
    "sourcePhysicalDirectEnabled=true",
    "rawOriginalSourceActive=true",
):
    assert prerequisite in raw, prerequisite
assert 'if rawMode && capturedRAWURL == nil' in block
assert 'try Build79RAWSignature.probeFile(url) != nil' in block
assert 'guard hasPhoto,!busy,!isRecipeApplying' in block
assert 'invalidateSimulation()' in block
assert block.count('queueSpectralPreview()') == 1
assert block.index('invalidateSimulation()') < block.index('filmExposureEV=0.0')
assert block.index('lut=nil') < block.index('queueSpectralPreview()')
assert 'densityGrainStage=nil' in block and 'spatialDIRStage=nil' in block
assert 'rawFullResolutionPreview=false' in block
for name in ('rawCropSelection', 'rawCropReferencePreview',
             'capturedRAWURL', 'originalPhotoData', 'source',
             'savedRecipes', 'photoSessionRevision', 'rawFastModeActive'):
    assert not re.search(rf'(?m)^\s*{name}\s*=', block), (
        name, "Factory reset must not alter current photo/RAW/crop/recipes"
    )
assert 'recipeUndo=nil' in block
assert 'recipeFilmSelectionToIgnore=defaultFilm' in block
assert 'recipePaperSelectionToIgnore=defaultPaper' in block
assert 'UserDefaults.standard.set(defaultFilm,forKey:"compactFilmStock")' in block
assert 'UserDefaults.standard.set(defaultPaper,forKey:"compactPaperStock")' in block
assert 'let defaultFilm="kodak_portra_400"' in block
assert 'let defaultPaper="kodak_portra_endura"' in block

assert '@State private var resetAllParametersAlert = false' in ui
assert 'resetAllParametersAlert=true' in ui
assert '.alert("恢复全部默认配置？"' in ui
assert 'Button("恢复默认配置",role:.destructive)' in ui
assert 'try model.resetAllProcessingToDefaults()' in ui
assert 'savedFastSettings=nil' in ui
assert 'model.isRecipeApplying' in ui
assert '当前照片、RAW 原片、已裁切区域和已保存配方保留' in ui
print("PASS Build142 factory defaults: exact 100 live source declarations; RAW original full-precision prerequisites preserved; photo/crop/recipes unchanged; one rebuild and confirmed UI")
print("NOT CERTIFIED: real iOS16.5.1 interaction and user image/colour comparison")
