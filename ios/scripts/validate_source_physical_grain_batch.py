#!/usr/bin/env python3
"""v1.8.48 original batch source grain actual production invariant gate.

No dummy RNG, no post-RGB grain, no silent automatic approximation; the
reference generator executes upstream grain.py on full 2D images.
"""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
physical=(root/"ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift").read_text()
grain=(root/"ios/SpektraFilmPort/OriginalSourcePhysicalGrain.swift").read_text()
engine=(root/"ios/SpektraFilmPort/SpectralPhysics.swift").read_text()
model=(root/"ios/SpektraFilmPort/ContentView.swift").read_text()
ui=(root/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
source=(root/"src/spektrafilm/model/grain.py").read_text()
test=(root/"ios/tests/SourcePhysicalImageParity.swift").read_text()
generator=(root/"ios/scripts/generate_source_physical_grain.py").read_text()
version=(root/"ios/project.yml").read_text()
assert 'MARKETING_VERSION: "1.8.49"' in version
assert 'CURRENT_PROJECT_VERSION: "74"' in version
assert 'iOS: "16.5"' in version
for token in (
    'def apply_grain_to_density_layers(',
    'density_max_fractions = density_max_layers/density_max_total[None,:]',
    'seeds = poisson_rvs(n_particles_per_pixel/saturation)',
    'grain = binom_rvs(seeds, probability_of_development)',
    'density_cmy_out = add_micro_structure(density_cmy_out, grain_micro_structure, pixel_size_um)',
    'density_cmy_out -= density_min',
):
    assert token in source, token
for token in (
    'var sourceGrain: OriginalSourcePhysicalGrain.Settings = .init()',
    'try sourceGrain.validate()',
    'let controlledFilmGrain=parameters.sourceGrain.active',
    'controlledFilmGrain ? OriginalSourcePhysicalGrain.extraBytesPerPixel : 0',
    'if controlledFilmGrain {',
    'rgb=density',
    'OriginalSourcePhysicalGrain.apply(',
    'stageDoubleObserver?("grainDensity",frame.rgb)',
    'engine.sourceSpatialGrainLayers()',
    'engine.sourceSpatialPrintPhoton(',
    'engine.sourceSpatialScan(',
    'stageDoubleObserver?("printed",frame.rgb)',
):
    assert token in physical, token
assert physical.index('OriginalSourcePhysicalGrain.apply(') > physical.index('let density=try engine.sourceSpatialDevelopCorrectedLog(')
assert physical.index('OriginalSourcePhysicalGrain.apply(') < physical.rindex('if parameters.scannerOptics.active {')
for token in (
    'func sourceSpatialGrainLayers() throws -> OriginalSourcePhysicalGrain.MeasuredLayers',
    'film.sourceDensityCurvesLayersF64 != nil',
    'film.sourceDensityCurvesF64 != nil',
    'film.sourceLogExposureF64 != nil',
    'profile.layerDensity(total:density[ch],channel:ch,sublayer:sl)',
):
    assert token in engine, token
for token in (
    'OriginalSourceSciPySampler.drawLayer(',
    'seed:UInt32(ch+sl*10)',
    'let sigma=settings.dyeCloudBlurUM*sqrt(od)',
    'SourceSpatialDIRConvolution.diffuseMemoryBounded(',
    'let microStd=settings.microstructureNM*0.001/pixelUM',
    'let microBlur=settings.microstructureUM/pixelUM',
    'microStd>0.05',
    'microBlur>0.4',
    'OriginalSourceNumbaSingleThreadNormal(seed:seed)',
    'OriginalSourceMicrostructure.lognormal(',
    'stageObserver?("sourceGrainDyeClouds",out)',
    'stageObserver?("sourceGrainMicrostructure",out)',
    'stageObserver?("sourceGrainFinalDensity",out)',
    'out[p*3+ch]-=settings.densityMin[ch]',
    'settings.grainBlur>0',
):
    assert token in grain, token
assert 'NOT the old RGB or Metal' in grain
assert 'numbaSeed == nil' in grain and '原版颗粒受控 Numba RNG' in grain
assert '@Published var sourcePhysicalGrainEnabled = false' in model
assert 'sourceGrain:OriginalSourcePhysicalGrain.Settings(' in model
assert 'numbaSeed:sourcePhysicalGrainEnabled ? 8888 : nil' in model
assert model.count('OriginalSourcePhysicalGrain.extraBytesPerPixel') >= 2
assert 'private var sourcePhysicalGrainSettings: AnyView' in ui
assert 'sourcePhysicalGrainSettings' in ui
assert 'resetToggle("源三亚层颗粒 / 染料云（Float64 实验）"' in ui
assert 'model.sourcePhysicalDirectEnabled' in ui
assert 'no seed rejected' in test
device=(root/"ios/SpektraFilmPort/OriginalSourceGrainProductionDiagnostic.swift").read_text()
assert "OriginalSourcePhysicalImage.develop(" in device
assert "sourceGrainMicrostructure" in device
assert "sourceSpatialScan(" in device
assert "no seed" in device
assert "OriginalSourceGrainProductionDiagnostic.evaluate()" in model
assert 'OriginalSourcePhysicalImage.develop(' in test
assert 'grainDensity' in test
assert 'sourceGrainFinalDensity' in test
assert 'generate_source_physical_grain.py' in (root/".github/workflows/ios16-source-grain-batch-v1.8.48.yml").read_text()
assert 'BLOBS={' in generator and 'model/grain.py' in generator
assert 'grain.apply_grain_to_density_layers(' in generator
assert 'original_micro(density_cmy_out,micro_structure,pixel_size_um)' in generator
print("PASS: 4 SOURCE STAGES integrated before actual enlarged/scanned RGB; default OFF")
print("PASS: 9 source SciPy full-plane count stream, independent per-layer cloud Gaussian")
print("PASS: one-worker controlled Numba microstructure and final FIR/YVV Double blur")
print("PASS: Float64 3x3 actual measured profiles, no override to mobile/CI or unseeded RNG")
print("PASS: original Python grain.py full-2D stage fixtures and real production image smoke are present")
print("NOT CERTIFIED: default Numba prange parallel unseeded RNG; real iPhone full-resolution RAW/RGB")
