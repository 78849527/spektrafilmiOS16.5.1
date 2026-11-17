#!/usr/bin/env python3
"""Build134: concrete in-app RAW lifecycle, dependable iOS16 gesture, reduced UI retention."""
from pathlib import Path
root=Path(__file__).resolve().parents[2]
get=lambda p:(root/p).read_text()
app=get("ios/SpektraFilmPort/ContentView.swift")
ui=get("ios/SpektraFilmPort/FloatingEditorWorkspace.swift")
storage=get("ios/SpektraFilmPort/Build134LocalRAWManager.swift")
pixel=get("ios/SpektraFilmPort/OriginalSourcePixelIO.swift")
processor=get("ios/SpektraFilmPort/PhotoProcessor.swift")
project=get("ios/project.yml")
for token in (
    "SpektraFilm RAW",
    "SpektraFilm RAW Imports",
    "UUID(uuidString:name)",
    "UUID(uuidString:String(name.dropFirst(7)))",
    "isSymbolicLink != true",
    "FileManager.default.removeItem(at:target)",
    "确认永久删除 RAW",
    "model.didDeleteSavedRAW(item.url)",
    "model.isCurrentSavedRAW(item.url)",
    "model.busy",
):
    assert token in storage, token
for token in (
    "rawManagerPresented",
    "onManageLocalRAW:",
    "Build134LocalRAWManagerView(model:model)",
    "func didDeleteSavedRAW(_ url:URL)",
    "source=nil",
    "rawOriginalSourceActive=false",
    "rawMemorySourceExtent",
    "PhotoProcessor.clearTransientCaches()",
    "OriginalSourcePixelIO.displayPreviewImage(",
    "try autoreleasepool { () throws -> URL in",
):
    assert token in app, token
for token in (
    "Menu {",
    "onManageLocalRAW()",
    "onDoubleTap:togglePhotoZoom",
    "UITapGestureRecognizer(",
    "doubleTap.numberOfTapsRequired=2",
    "private var photoFloatingNotices",
    "按住看原图 · 双击放大",
):
    assert token in ui, token
assert "StableImageHoldRecognizer(isHolding: $originalHeld)" not in ui
assert "context.clearCaches()" in processor
assert "maxEdge:Int=1600" in pixel
assert "context.interpolationQuality = .high" in pixel
from build_ci_version_floor import minimum_build,minimum_minor
assert minimum_build(project,134) and minimum_minor(project,100)
print("PASS Build134 scoped local RAW deletion / active file invalidation / genuine UIKit double tap / bounded preview and native export memory lifecycle")
print("NOT CERTIFIED: actual on-device file deletion, gesture interaction and original RAW TIFF16 export require physical iPhone validation")
