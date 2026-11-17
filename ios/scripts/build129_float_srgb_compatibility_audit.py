#!/usr/bin/env python3
"""Build129: fix actual Apple RAW Float32 sRGB ICC incompatibility.

No permissive generic Float32 route or 8-bit fallback. Test compiles and
runs an actual RGBAf TIFF roundtrip separately on macOS CI.
"""
from pathlib import Path
from build_ci_version_floor import minimum_build, minimum_minor
p=Path(__file__).resolve().parents[2]
model=(p/"ios/SpektraFilmPort/ContentView.swift").read_text()
admit=(p/"ios/SpektraFilmPort/Build111PhotoInputProfile.swift").read_text()
floatio=(p/"ios/SpektraFilmPort/Build78FloatTIFFIngress.swift").read_text()
bridge=(p/"ios/SpektraFilmPort/Build128RAWFloat32Transport.swift").read_text()
recipe=(p/"ios/SpektraFilmPort/Build126Recipe.swift").read_text()
project=(p/"ios/project.yml").read_text()
test=(p/"ios/tests/Build129FloatSRGBIngressValidation.swift").read_text()
assert minimum_build(project,129) and minimum_minor(project,95)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
for keyword in [
    "floatingComponents && declaredDepth==32",
    "decodedDepth==32 && color == .sRGB",
    'return format == "TIFF"',
    "floatingComponents && (decodedDepth==16 ||",
    "decodedDepth==32) && color == .extendedSRGB",
    "CFEqual(space,srgb)","CFEqual(space,p3)"
]:
    assert keyword in admit,keyword
for keyword in [
    "image.bitmapInfo.contains(.floatComponents)",
    "let srgb=CGColorSpace(name:CGColorSpace.sRGB)",
    "image.bitsPerComponent==32 && CFEqual(colour,srgb)",
    "CFEqual(colour,extended)",
    "Float16 只接受 extended sRGB",
    "Float(bitPattern:raw)",
    "guard alpha.isFinite,alpha==1.0 else"
]:
    assert keyword in floatio,keyword
for keyword in [
    "context.writeTIFFRepresentation(",
    "format:.RGBAf","colorSpace:extended,options:[:]",
    "profile.floatingComponents",
    "profile.declaredDepth==32",
    "profile.decodedDepth==32",
    "(profile.color == .extendedSRGB ||",
    "profile.color == .sRGB)",
    "profile.directCompatible",
    "try? FileManager.default.removeItem(at:file)"
]:
    assert keyword in bridge,keyword
for keyword in [
    'return "float32SRGB"',
    'return "float32ExtendedSRGB"',
    "profileInput", # not required; handled below
]:
    if keyword=="profileInput":continue
    assert keyword in model,keyword
assert '"float32SRGB"' in recipe
assert 'let expected=recipe.inputContract ?? "uint8SRGB"' in model
assert "guard actual==expected else" in model
assert "rawURL:originalDNG,rawCompatible:false" in model
assert "convertActiveRAWTo8BitSRGBCopy()" in model
assert "format:.tiff," in model and "bitDepth:16" in model
assert "model" not in bridge[:30]
for keyword in [
    "Build128RAWFloat32Transport.makeVerifiedCopy(input)",
    "Build78FloatTIFFIngress.decode(",
    "inspection(.sRGB,32,true).directCompatible",
    "!inspection(.displayP3,32,true).directCompatible",
    "!inspection(.untagged,32,true).directCompatible",
    "!inspection(.sRGB,32,false).directCompatible",
    "!inspection(.sRGB,16,true).directCompatible"
]:
    assert keyword in test,keyword
# Negative: no actual 8-bit component format chosen for RAW Float32.
code="\n".join(x for x in bridge.splitlines() if not x.strip().startswith("//"))
assert "format:.RGBA8" not in code and "format:.RGBA16" not in code
assert ".resize" not in bridge and "lanczos" not in bridge
print("PASS Build129 source: actual Float32 ICC sRGB or extended, strict TIFF/float-only route; 8-bit/P3/unmarked refuse; legacy recipes unchanged")
print("NOT CERTIFIED: actual iOS16.5.1 camera DNG Apple RAW visual/numeric parity until device acceptance")
