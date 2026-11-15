import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("Build98 temporary file test: " + message) }
}
let manager=FileManager.default
let tmp=manager.temporaryDirectory
let owned=tmp.appendingPathComponent(
    "SpektraFilmPort-" + UUID().uuidString
).appendingPathExtension("jpg")
let old=tmp.appendingPathComponent(
    "SpektraFilm-RGB16-" + UUID().uuidString
).appendingPathExtension("tiff")
let young=tmp.appendingPathComponent(
    "SpektraFilm-original-output-" + UUID().uuidString
).appendingPathExtension("png")
let unrelated=tmp.appendingPathComponent(
    "SpektraFilmPort-not-uuid"
).appendingPathExtension("jpg")
for p in [owned,old,young,unrelated] {
    try Data([1,2,3]).write(to:p)
}
defer {
    for p in [owned,old,young,unrelated] {
        try? manager.removeItem(at:p)
    }
}
require(Build98ExportTemporaryFiles.isOwnedExport(owned),"owned jpg")
require(Build98ExportTemporaryFiles.isOwnedExport(old),"owned tiff")
require(Build98ExportTemporaryFiles.isOwnedExport(young),"owned png")
require(!Build98ExportTemporaryFiles.isOwnedExport(unrelated),
        "unrelated non-UUID must be safe")
require(!Build98ExportTemporaryFiles.isOwnedExport(
    manager.homeDirectoryForCurrentUser
        .appendingPathComponent("SpektraFilm-RGB16-" + UUID().uuidString)
        .appendingPathExtension("tiff")
), "external/RAW Documents must never be deleted")
require(!Build98ExportTemporaryFiles.removeAfterUse(unrelated),
        "non-export temp not removed")
require(manager.fileExists(atPath:unrelated.path),"unrelated still exists")
require(Build98ExportTemporaryFiles.removeAfterUse(owned),
        "owned share output removed")
require(!manager.fileExists(atPath:owned.path),"owned file actually removed")

let now=Date()
try manager.setAttributes(
    [.modificationDate:now.addingTimeInterval(
        -(Build98ExportTemporaryFiles.staleAfter + 120)
    )],ofItemAtPath:old.path
)
let removed=Build98ExportTemporaryFiles.removeStale(
    now:now, maxEntries:Int.max
)
require(removed >= 1, "orphaned expired output removed")
require(!manager.fileExists(atPath:old.path),
        "expired tiff actually removed")
require(manager.fileExists(atPath:young.path),
        "new shared exports stay until dismissal")
require(manager.fileExists(atPath:unrelated.path),
        "unrelated files survive crash recovery")
print("PASS Build98 owned temp exports: jpeg/tiff/png; share completion, " +
      "24h stale expiry, unrelated and external RAW safety")
