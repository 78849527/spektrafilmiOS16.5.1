#!/usr/bin/env python3
"""Build111 input eligibility, conversion and Build110 evidence source audit.
Not a substitute for real iOS16.5.1 device acceptance.
"""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
src=lambda p:(root/p).read_text()
model=src("ios/SpektraFilmPort/ContentView.swift")
ui=src("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
detector=src("ios/SpektraFilmPort/Build111PhotoInputProfile.swift")
report=src("ios/SpektraFilmPort/Build110SourceGamutDeviceEvidence.swift")
project=src("ios/project.yml")
assert model.count("Build111PhotoInputProfile.inspect(data,entry:entry)")==1
assert "try loadPhoto(capture.processed,entry:.camera)" in model
assert "try loadPhoto(Data(contentsOf: url),entry:.file)" in model
assert "try loadPhoto(data)" in model  # photos
assert "if rawCompatible || inputProfile?.directCompatible != true" in model
assert "photoInputProfile=inputProfile" in model
assert "photoDirectInputReady" in model
assert "try loadPhoto(converted,entry:.converted)" in model
assert "photoOriginalBeforeColorConversion=original" in model
assert "if !isOn && !model.photoDirectInputReady" in ui
assert 'Button("转换 P3 为 sRGB 副本")' in ui
assert ".confirmationDialog(" in ui
assert "inputCompatibilityBanner" in ui
assert "CGImageSourceGetType(imageSource)" in detector
assert "CGImageSourceCreateImageAtIndex(" in detector
assert "CFEqual(space,srgb)" in detector
assert "CFEqual(space,p3)" in detector
assert "ctx.setRenderingIntent(.relativeColorimetric)" in detector
assert "CGImageDestinationAddImage(dest,output,options)" in detector
assert "after.directCompatible" in detector
assert "Preserve Build78 certified" in detector
assert "color == .extendedSRGB" in detector
assert "selectedPhotoDirectCompatible" in report
assert "selectedPhotoP3ColorSyncConverted" in report
# Legacy Build111 checks must remain valid after later grouped IPA builds.
# Validate minimum supported version without rejecting the current Build115.
import re
version = re.search(r'MARKETING_VERSION:\s*"1\\.8\\.(\\d+)"', project)
build = re.search(r'CURRENT_PROJECT_VERSION:\s*"(\\d+)"', project)
assert version and int(version.group(1)) >= 78, "Build111 input-profile baseline was lost"
assert build and int(build.group(1)) >= 112, "Build111 minimum build was lost"
assert 'IPHONEOS_DEPLOYMENT_TARGET: "16.5"' in project
print("PASS Build111 unified camera Photos Files profile admission and consented P3 ColorSync copy; physical iPhone not yet tested")
