#!/usr/bin/env python3
"""RAW catalog: capture first, browse thumbnail, open original later (static contract)."""
from pathlib import Path

root=Path(__file__).resolve().parents[2]
read=lambda path:(root/path).read_text()
manager=read("ios/SpektraFilmPort/Build134LocalRAWManager.swift")
app=read("ios/SpektraFilmPort/ContentView.swift")
camera=read("ios/SpektraFilmPort/NextLevelCamera.swift")
for token in (
    'static func archiveCameraRAW(',
    'try raw.write(to:target,options:.atomic)',
    'makeSmallJPEG(companion)',
    'kCGImageSourceThumbnailMaxPixelSize:320',
    'kCGImageSourceCreateThumbnailFromImageIfAbsent:false',
    'static func thumbnailData(for url:URL) -> Data?',
    'let bytes=await Task.detached(priority:.utility)',
    'GridItem(.flexible(),spacing:10)',
    'LazyVGrid(columns:columns,spacing:12)',
    'model.openSavedRAWFromLibrary(item.url)',
    'model.didDeleteSavedRAW(item.url)',
    'try FileManager.default.removeItem(at:target)',
    'try? FileManager.default.removeItem(at:preview)',
    '确认永久删除 RAW',
):
    assert token in manager,token
assert 'CGImageSourceCreateThumbnailAtIndex(' in manager
# The full sensor RAW must remain byte-preserved and must never be substituted
# with the gallery's small JPEG or decoded simply to paint a list tile.
catalog=manager.split('static func thumbnailData(for url:URL) -> Data?')[1].split('static func delete(')[0]
assert 'CIImage(' not in catalog and 'CIRAWFilter(' not in catalog
archive=app.split('func archiveCapturedRAWForLater(')[1].split('func openSavedRAWFromLibrary(')[0]
assert 'Build134LocalRAWStorage.archiveCameraRAW(' in archive
assert 'Build93AppleRAWImport.open(' not in archive
assert 'loadCapturedPhoto(' not in archive
for token in (
    'func openSavedRAWFromLibrary(_ url:URL)',
    'Build134LocalRAWStorage.isManaged(url)',
    'pendingImportedRAWURL=url',
    'openPreservedRAWDirect()',
    'archiveCapturedRAWForLater(photo)',
    'if photo.rawDNG != nil {',
):
    assert token in app,token
for token in (
    'let onCapture:(NextLevelCapturedPhoto)->String?',
    'camera.onCapture={ photo in',
    'savedRAWCount+=1',
    'if camera.format == .raw {',
    '可继续拍摄，退出后从素材库选片冲印',
):
    assert token in camera,token
assert 'rawDNG:raw' in camera
print("PASS RAW gallery source: each Bayer DNG archived unmodified; bounded companion thumbnail; continuous camera capture; original selected separately, deletion scoped to App; no JPEG optical fallback")
print("PENDING: physical iOS16.5.1 burst/thumbnail/RAF embedded-preview and gallery-to-Float64 tests")
