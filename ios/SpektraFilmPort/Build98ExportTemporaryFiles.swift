import Foundation

/// Build98: only SpektraFilm-generated files in the app's OWN temporary
/// directory are eligible for automatic cleanup. Preserved RAW originals
/// live in Documents and are explicitly outside this lifecycle.
enum Build98ExportTemporaryFiles {
    private static let outputPrefixes = [
        "SpektraFilmPort-", "SpektraFilmPort-source-io-",
        "SpektraFilm-RGB16-", "SpektraFilm-original-output-"
    ]
    private static let outputExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "png"]
    static let staleAfter: TimeInterval = 24 * 60 * 60

    static func isOwnedExport(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let directory = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent() == directory,
              outputExtensions.contains(target.pathExtension.lowercased())
        else { return false }
        let stem = target.deletingPathExtension().lastPathComponent
        // Require a filename generated with UUID suffix by our encoders;
        // do not remove arbitrary temporary files with a familiar prefix.
        return outputPrefixes.contains { prefix in
            guard stem.hasPrefix(prefix) else { return false }
            return UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil
        }
    }

    @discardableResult
    static func removeAfterUse(_ url: URL) -> Bool {
        guard isOwnedExport(url) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch { return false }
    }

    /// Startup crash-recovery sweep, intentionally bounded so the UI does
    /// not scan an unlimited number of files. Never touch newer exports
    /// that might be in an ongoing share or Photos write.
    @discardableResult
    static func removeStale(
        now: Date = Date(), maxEntries: Int = 256
    ) -> Int {
        let manager = FileManager.default
        let candidates: [URL]
        do {
            candidates = try manager.contentsOfDirectory(
                at: manager.temporaryDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch { return 0 }
        var removed = 0
        for file in candidates.prefix(max(0, maxEntries)) {
            guard isOwnedExport(file),
                  let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                  ),
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= staleAfter
            else { continue }
            if removeAfterUse(file) { removed += 1 }
        }
        return removed
    }
}
