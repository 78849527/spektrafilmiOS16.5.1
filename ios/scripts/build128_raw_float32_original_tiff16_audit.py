#!/usr/bin/env python3
"""Build128 source audit: real Apple RAW Float32 ingress and original TIFF16.

Distinguishes verified transport from unproven rawpy/Apple conversion parity.
"""
from pathlib import Path
from build_ci_version_floor import minimum_minor, minimum_build
root=Path(__file__).resolve().parents[2]
s=(root/"ios/SpektraFilmPort/ContentView.swift").read_text()
ui=(root/"ios/SpektraFilmPort/FloatingEditorWorkspace.swift").read_text()
bridge=(root/"ios/SpektraFilmPort/Build128RAWFloat32Transport.swift").read_text()
original=(root/"ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift").read_text()
ingress=(root/"ios/SpektraFilmPort/Build78FloatTIFFIngress.swift").read_text()
recipe=(root/"ios/SpektraFilmPort/Build126Recipe.swift").read_text()
project=(root/"ios/project.yml").read_text()
assert minimum_minor(project,94) and minimum_build(project,128)
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project

for proof in [
    "enum Build128RAWFloat32Transport",
    "makeVerifiedCopy(_ rawImage:CIImage)",
    "OriginalSourcePixelIO.validatePixelDimensions(",
    "maximumAllowedPixels:16_000_000",
    "SafeExportResolution.currentProcessHeadroom()",
    "CGColorSpace(name:CGColorSpace.extendedSRGB)",
    "context.writeTIFFRepresentation(",
    "format:.RGBAf",
    "colorSpace:extended,options:[:]",
    "Build111PhotoInputProfile.inspect(",
    "profile.declaredDepth==32",
    "profile.decodedDepth==32",
    "profile.floatingComponents",
    "(profile.color == .extendedSRGB ||",
    "profile.color == .sRGB)",
    "profile.directCompatible",
    "try? FileManager.default.removeItem(at:file)",
]:
    assert proof in bridge,proof
bridge_code="\n".join(line for line in bridge.splitlines() if not line.lstrip().startswith("//"))
assert ".RGBA8" not in bridge_code and ".RGBA16" not in bridge_code
assert ".RGBA16" not in bridge
assert ".lanczos" not in bridge
assert "kCGImageDestinationLossyCompressionQuality" not in bridge
assert "source:CGImageSource,image:CGImage" in ingress
assert "Double(Float(bitPattern:raw))" in ingress
assert "image.bitmapInfo.contains(.floatComponents)" in ingress

for proof in [
    "func convertActiveRAWToFloat32ExtendedSRGBCopy()",
    "Build93AppleRAWImport.open(originalDNG)",
    "Build128RAWFloat32Transport.makeVerifiedCopy(",
    "data:result.bytes,",
    "rawURL:originalDNG,rawCompatible:false,",
    "inputProfile:result.admission",
    "try commitDecodedPhoto(",
    "convertActiveRAWTo8BitSRGBCopy()",
    "func preflightSavedRecipe(_ recipe:Build126Recipe) throws",
    'let expected=recipe.inputContract ?? "uint8SRGB"',
    "guard actual==expected else",
    'expected=="uint8SRGB"',
    'p.declaredDepth==8,p.decodedDepth==8',
    'p.color == .sRGB,!p.hasAlphaChannel',
    'inputContract:sourcePixelIOEnabled ? currentRecipeInputContract() : nil',
    'try OriginalSourcePixelIO.exportPhysicalOriginalFile(',
    'bytes,parameters:physical,format:.tiff,',
    'bitDepth:16,outputSpace:"sRGB",',
    "cctfEncoded:physical.sourceOutputCCTFEncoding",
    "if tiff16 && sourcePixelIOEnabled &&",
    "if tiff16 && !sourcePixelIOEnabled",
]:
    assert proof in s,proof
assert "inputContract:String?" in recipe
assert "private func currentRecipeInputContract() -> String?" in s
assert "guard let p=photoInputProfile else {return nil}" in s
assert "guard sourcePixelIOEnabled,let p=photoInputProfile" not in s
assert '"float32ExtendedSRGB"' in recipe
assert '"float32SRGB"' in recipe
assert "missing" not in recipe[:100]
assert "static func exportPhysicalOriginalFile(" in original
assert "Build90NativeOutputWriter.write(" in original
assert "优先：生成 RAW 的 Float32 高位深 TIFF（保留 DNG）" in ui
assert "兼容：生成 RAW 的 8-bit sRGB JPEG（保留 DNG）" in ui
assert "model.convertActiveRAWToFloat32ExtendedSRGBCopy()" in ui
capture=s[s.index("func loadCapturedPhoto("):s.index("func loadPhotoFile(")]
assert "convertActiveRAWToFloat32ExtendedSRGBCopy()" not in capture
assert "data:nil,rawURL:rawFile,rawCompatible:true" in capture
assert "JPEG 伴随片没有进入编辑器" in capture
assert "rawFastModeActive=rawCompatible" in s
print("PASS Build128/129: opt-in DNG→Float32 TIFF with actual sRGB/extended ICC checks, original Float64 TIFF16, preserved 8-bit recipes")
print("NOT CERTIFIED: Apple CIRAWFilter versus original Python rawpy numeric parity or full-image iOS16.5.1 hardware render")
