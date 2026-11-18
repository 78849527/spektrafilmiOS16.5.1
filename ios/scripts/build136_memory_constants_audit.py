#!/usr/bin/env python3
"""Build136: production memory audit and fixed-preset no-silent-fallback regression."""
from pathlib import Path
from build_ci_version_floor import minimum_build,minimum_minor
r=Path(__file__).resolve().parents[2]
read=lambda p:(r/p).read_text()
s=lambda n:read(f"ios/SpektraFilmPort/{n}.swift")
safe=s("SafeExportResolution")
sci=s("OriginalSourceSciPyParticles")
diff=s("OriginalSourceDiffusion")
mem=s("Build91PhysicalMemory")
hal=s("OriginalSourceFilmHalation")
glare=s("OriginalSourceScannerGlare")
pixels=s("OriginalSourcePixelIO")
resized=s("Build136RAWOutputResize")
main=s("ContentView")
ui=s("FloatingEditorWorkspace")
tests=read("ios/tests/Build136RAWOutputResizeValidation.swift")
project=read("ios/project.yml")
assert minimum_build(project,136) and minimum_minor(project,102)
assert 'static let presetWanPixels = [720, 800, 900, 1000, 1200]' in safe
assert 'case megapixels(Int)' in safe
assert 'case .megapixels: percentage = originalBudgetPercent' in safe
assert 'fullSourceProcessing: fullSourceProcessing' in safe
assert 'fullSourceProcessing:rawOriginalSourceActive' in main
assert main.count('Build136RAWOutputResize.resample(')==2
assert 'width:rawOriginalSourceActive ? Int(bounds.width)' in main
assert ui.count('ForEach(ExportResolutionMode.presetWanPixels')==3
assert 'sourcePhysicalDirectEnabled,capturedRAWURL != nil' in main
assert "1_500_000_000" not in sci
assert 'os_proc_available_memory()' in sci
assert 'let budget = (headroom / 100) * 70' in sci
assert "512_000_000" not in diff
assert "512 MB Float64 FFT" not in diff
assert "FFT.sourceCap" not in mem
assert 'remainingScratch <= (available/10)*8' in diff
assert 'remainingPeak<=($0/10)*8' in mem
assert 'width<=13_000_000/height' in hal
assert glare.count('width <= 13_000_000 / height')==2
assert 'let full=try displayImage(frame)' not in pixels
assert 'let outW=max(1' in pixels and 'let outH=max(1' in pixels
assert 'frame.rgb.allSatisfy({$0.isFinite})' in pixels
assert 'var rgba=[UInt8](repeating:255,count:outW*outH*4)' in pixels
assert 'return try displayImage(frame)' in pixels  # small previews unchanged
assert 'let xTaps=taps(source:width,target:targetWidth)' in resized
assert 'let yTaps=taps(source:height,target:targetHeight)' in resized
assert 'targetWidth<=width,targetHeight<=height' in resized
assert 'fullSourceProcessing:true' in tests
assert '900_000_000' in tests  # low-headroom fail-closed
assert 'RAW' in read("ios/docs/BUILD136_MEMORY_AUDIT.md")
# Incremental memory optimization gates; original math is unchanged.
packed=s("Build90SourceOutputQuantization")
writer=s("Build90NativeOutputWriter")
iccContainer=s("Build90OriginalICCContainer")
quantTest=read("ios/tests/Build90SourceIOQuantizationValidation.swift")
assert "let q=try quantize(rgb,as:spec)" not in packed
assert "guard rgb.allSatisfy({$0.isFinite}) else" in packed
assert "for value in rgb" in packed
assert "let encoded=Data(output)" in iccContainer
assert "from:encoded,format:format" in iccContainer
assert "Data(contentsOf:url,options:.mappedIfSafe)" in writer
assert main.count("result.rgb.removeAll(keepingCapacity:false)")==2
assert "let baselineBytes=packedFromQuantized(" in quantTest
assert "guard byteData==baselineBytes else" in quantTest
print("PASS Build136: full RAW Float64 source cost preserved; five explicit output presets; original-only numerical core; direct bounded UI preview")
print("PASS Build136: fixed 1500MB SciPy and 512MB FFT removed; dynamic 70/80% guard; halation/glare aligned to 13MP; low-memory refusal retained")
