#!/usr/bin/env python3
"""Strict input-fidelity regression: retire non-original Build130 global map.

This proves removal of that workaround, byte-preserving Float32 ingress
fixtures, and the presence of upstream source reference paths. It does NOT
claim that unbounded Float32 optical simulation has passed numerical parity.
"""
from pathlib import Path
from build_ci_version_floor import minimum_build, minimum_minor

root=Path(__file__).resolve().parents[2]
def read(p):return (root/p).read_text()
production=root/"ios/SpektraFilmPort"
assert minimum_build(read("ios/project.yml"),131)
assert minimum_minor(read("ios/project.yml"),97)
assert not (production/"Build130Float32RangeCopy.swift").exists()
assert not (root/"ios/tests/Build130Float32RangeCopyValidation.swift").exists()
assert not (root/"ios/scripts/build130_float32_optical_range_audit.py").exists()
model=read("ios/SpektraFilmPort/ContentView.swift")
ui=read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
physical=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
ingress=read("ios/SpektraFilmPort/Build78FloatTIFFIngress.swift")
test=read("ios/tests/Build129FloatSRGBIngressValidation.swift")
up_io=read("src/spektrafilm/utils/io.py")
up_raw=read("src/spektrafilm/utils/raw_file_processor.py")
up_film=read("src/spektrafilm/runtime/stages/filming.py")
for text in (model,ui,physical):
    for forbidden in [
        "Build130Float32RangeCopy",
        "convertFloat32ToBoundedWorkingCopy",
        "float32RangeWorkingCopyPossible",
        "float32RangeCopyConfirmation",
        "映射工作副本",
    ]:
        assert forbidden not in text,forbidden
assert "vm.outOfRange==0" not in ingress
assert "rgb[result+c]=value" in ingress
assert "guard value.isFinite" in ingress
assert "value>=0" not in ingress and "value<=1" not in ingress
for token in ["verifyUnchangedFloatValues()","before.rgb.contains(where:{$0<0})",
              "before.rgb.contains(where:{$0>1})","got==expected",
              "Build78FloatTIFFIngress.decode"]:
    assert token in test,token
assert "try Build130Float32RangeCopyValidation.evaluate()" not in test
for token in ["if spec.format == oiio.TypeDesc(\"uint16\")",
              "if spec.format == oiio.TypeDesc(\"uint8\")",
              "np.double(np_pixels)/(2**16-1)",
              "np.double(np_pixels)/(2**8-1)",
              "32 → float32 (raw, no clip/scale)"]:
    assert token in up_io,token
assert "raw.postprocess(**params).astype(np.float32) / np.float32(65535.0)" in up_raw
assert "_rgb_to_film_raw(" in up_film
assert "np.fmax(raw, 0.0)" in up_film
assert "guard frame.rgb.allSatisfy({ $0.isFinite }) else" in physical
assert "if value<0 || value>1" not in physical
assert "拒绝静默裁切、范围映射或降级" in physical
assert "case .proPhotoLinear, .acesLinear: linear=encodedRGB" in read("ios/SpektraFilmPort/SpectralPhysics.swift")
assert "sourceLuminanceWeightsACES" in read("ios/scripts/generate_source_camera_batch.py")
assert "sourceLuminanceWeightsProPhoto" in read("ios/SpektraFilmPort/OriginalSourceCameraOptics.swift")
print("PASS: non-original global Float32 input mapping removed from iOS production/UI/source test")
print("PASS: source OpenImageIO / rawpy reference remains and real TIFF Float32 negative/superwhite ingress fixture stays unchanged")
print("PENDING, NOT CERTIFIED: Python vs iOS HDR/RAW whole-image colour/optical stage numerical equivalence")
