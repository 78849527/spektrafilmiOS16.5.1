#!/usr/bin/env python3
"""Read-only source acceptance B. Verifies evidence scope, NOT source completion."""
from pathlib import Path
import subprocess,json,sys
r=Path(__file__).resolve().parents[2]
source="4e1ab8faf4ebfe47a6bac7e85e657881d68d2bf1"
def read(path):return (r/path).read_text()
assert subprocess.call(["git","merge-base","--is-ancestor",source,"HEAD"],cwd=r)==0
changed=subprocess.check_output(["git","diff","--name-only",source,"HEAD"],cwd=r,text=True).splitlines()
assert all(x.startswith(("ios/tests/FinalSource","ios/scripts/final_closure_B_",".github/workflows/final-closure-B-","docs/FINAL-CLOSURE-B-")) for x in changed),changed
p=read("ios/project.yml")
assert 'MARKETING_VERSION: "1.8.74"' in p and 'CURRENT_PROJECT_VERSION: "108"' in p
ui=read("ios/SpektraFilmPort/ContentView.swift")
writer=read("ios/SpektraFilmPort/Build90NativeOutputWriter.swift")
icc=read("ios/SpektraFilmPort/Build90OriginalICCContainer.swift")
phys=read("ios/SpektraFilmPort/OriginalSourcePhysicalImage.swift")
apple=read("ios/SpektraFilmPort/Build93AppleRAWImport.swift")
lib=read("ios/SpektraFilmPort/Build95LibRaw16Ingress.swift")
assert "CIRAWFilter(imageURL: url)" in apple
assert "LibRaw" in lib and "16-bit" in lib and "NOT" in lib
assert "Build90OriginalICCContainer.embed(" in writer
assert "Build90OriginalICCContainer.extract(" in writer
assert "kCGImagePropertyExifDictionary" in writer and "kCGImagePropertyGPSDictionary" in writer
assert "guard options.format != .exr" in writer
assert "Source XMP preservation beyond ImageIO" in icc
assert "sourceImageData:data" in phys and "exportPhysicalOriginalFile" in phys
no_cameras=[str(z.relative_to(r)) for z in r.rglob("*") if z.is_file() and z.suffix.lower() in (".raf",".dng",".cr3",".arw",".nef") and ".git" not in z.parts]
result={"sourceSHA":source,"version":"1.8.74 Build108","readOnlyProduction":True,
"realRAWFilesInRepo":no_cameras,
"rawpyNumericParity":"BLOCKED_NO_INDEPENDENT_ORIGINAL_RAW",
"appleLibRaw":"COMPATIBILITY_MODE_NOT_SOURCE_EQUIVALENCE",
"sourceICC":"JPEG_APP2_PNG_iCCP_TIFF_TAG_34675_PRESENT",
"physicalSourceWriterDirectUI":("exportPhysicalOriginalFile(" in ui),
"EXR":"BLOCKED_NO_ENCODER","XMP":"BLOCKED_NO_PRESERVATION_CERTIFICATION",
"EXIF_IPTC_GPS":"PENDING_ACTUAL_DISK_TEST",
"formalCertificate":False}
out=Path(sys.argv[1]);out.write_text(json.dumps(result,indent=2,ensure_ascii=False)+"\n")
print("PASS acceptance B static source: RAW file count",len(no_cameras),
"sourceICC present; XMP/EXR/rawpy blocked; direct UI writer",result["physicalSourceWriterDirectUI"])
