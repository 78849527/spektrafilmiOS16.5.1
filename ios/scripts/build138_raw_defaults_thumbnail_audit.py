#!/usr/bin/env python3
"""Build138 source gates: RAW portrait gallery, automatic exact mode, stock refresh.

These checks validate the intended route and no-fallback invariants only.
They do NOT assert actual iPhone16.5.1 performance or visual parity.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
read = lambda p: (root / p).read_text()
app = read("ios/SpektraFilmPort/ContentView.swift")
gallery = read("ios/SpektraFilmPort/Build134LocalRAWManager.swift")
ui = read("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")

assert ".aspectRatio(4.0/3.0,contentMode:.fit)" not in gallery
assert ".aspectRatio(actualAspectRatio,contentMode:.fit)" in gallery
assert gallery.count("kCGImageSourceCreateThumbnailWithTransform:true") >= 2
assert "orientLegacyThumbnail(_ data:Data,rawURL:URL)" in gallery
assert 'raw.lastPathComponent+".upright-v2.jpg"' in gallery
assert "kCGImageSourceThumbnailMaxPixelSize:320" in gallery
assert "CIImage(" not in gallery and "CIRAWFilter(" not in gallery
assert "try raw.write(to:target,options:.atomic)" in gallery

# File-imported DNG/RAF and locally archived RAW open without a second tap.
assert 'rawNeedsChoice = !(kind == .raf || kind == .dng)' in app
assert "if !rawNeedsChoice {\n                    openPreservedRAWDirect()" in app
assert "func openSavedRAWFromLibrary(_ url:URL)" in app
assert "openPreservedRAWDirect()" in app
assert "func openPreservedRAWDirect()" in app
assert "case .raf: openPreservedRAW16Bit(preferOriginalSource:true)" in app
assert "case .dng: openPreservedRAWWithApple(preferOriginalSource:true)" in app

# Exact mode is activated explicitly after a successful decode, not by a
# second manual film-selection change; normal images are unaffected.
activate = app.split("private func activateDirectRAWPrecision() throws {", 1)[1].split(
    "    /// Import preview remains independent", 1
)[0]
for required in (
    "sourcePixelIOEnabled=true",
    "sourcePhysicalDirectEnabled=true",
    "rawOriginalSourceActive=true",
    "originalScannerEnabled=true",
    "originalPrintOpticsEnabled=true",
    "hanatosOriginalPrecisionEnabled=true",
    "spatialDIRSourceConvolutionEnabled=true",
    "queueSpectralPreview()",
    "lut=nil",
):
    assert required in activate, required
assert "try activateDirectRAWPrecision()" in app
assert "func loadPhotoFile(_ url: URL)" in app
assert "func selectFromPhotos(_ selection: PhotosPickerItem?)" in app
assert "try loadPhoto(Data(contentsOf: url),entry:.file)" in app

# Full RAW exposure/H-D/scan reads the actual selected stock IDs and bypasses
# the 17^3 compatibility LUT. Generation/busy checks prevent stale exports.
assert "if rawOriginalSourceActive && sourcePhysicalDirectEnabled {" in app
assert "activeSimulationGeneration=generation" in app
assert "try refresh()" in app
assert "simulationAwaitingCurrentSettings=false" in app
assert "try P1OriginalRawACESIngress.developSourceCandidate(" in app
assert 'UserDefaults.standard.string(forKey:"compactFilmStock")' in app
assert 'UserDefaults.standard.string(forKey:"compactPaperStock")' in app
assert "let sourceRAWReady=model.rawOriginalSourceActive &&" in ui
assert "(model.lut != nil || (mode == .physical && sourceRAWReady))" in ui
assert "model.rawOriginalSourceActive=false" in ui

print("PASS Build138 static: EXIF-correct portrait RAW gallery; auto exact RAW; current stock/paper source; no JPEG/LUT substitution")
print("PENDING: iOS16.5.1 on-device portrait/rotation matrix, source RAW render, film parity, memory and performance")
