import Foundation

/// Build100 production-readiness status is deliberately NOT an algorithm
/// certificate. No public UI label may infer full original-Python numeric
/// parity from CI compilation, source fixture existence or a 16-bit file.
enum Build100Readiness {
    enum Result: String, Codable {
        case notRun = "not_run"
        case needsReview = "needs_review"
        case blocked = "blocked"
    }

    struct Item: Codable {
        let id: String
        let title: String
        let result: Result
        let evidence: String
    }

    struct Report: Codable {
        let schema: Int
        let version: String
        let build: String
        let generatedUTC: String
        let platform: String
        let osVersion: String
        let mode: String
        let sourceLoaded: Bool
        let processedPreviewAvailable: Bool
        let selectedMaterialPending: Bool
        let runtimeDiagnosticReportExists: Bool
        let releaseCertification: String
        let manualChecks: [Item]
    }

    static func manualChecklist() -> [Item] {
        let names: [(String, String)] = [
            ("cold_start_5x", "iOS 16.5.1 冷启动与反复进入编辑页 5 次"),
            ("photo_import_rollback", "相册、文件、LUT 导入/取消/失败保留当前会话"),
            ("wheel_30x", "连续切换胶片/相纸 30 次，预览和导出不串配"),
            ("mode_switch", "快速/原版精细模式多次切换后恢复原参数"),
            ("hold_split_zoom", "长按原图、分屏滑动、双击缩放无冲突"),
            ("jpeg_3_sizes", "原图/安全/经济 JPEG 导出与回读"),
            ("tiff16_roundtrip", "iPhone 真实 TIFF16 输出与文件回读位深"),
            ("photos_share", "Photos 权限、分享扩展和文件打开、用户确认写入"),
            ("large_memory", "实际大图内存峰值、Jetsam 与连续导出"),
            ("source_original_parity", "原版 Python 对 iPhone Float64 整图逐阶段数值比较"),
            ("rng_distribution", "Python 默认无种子/多线程颗粒随机统计等价"),
            ("icc_metadata", "高位深输入/ICC/EXIF/XMP 及宽色域端到端验证")
        ]
        return names.map {
            Item(id:$0.0, title:$0.1, result:.notRun, evidence:"")
        }
    }

    /// This is a runtime snapshot, not a claim that listed checks ran.
    static func capture(
        version: String, build: String, date: Date, platform: String,
        osVersion: String, sourceLoaded: Bool,
        processedPreviewAvailable: Bool, selectedMaterialPending: Bool,
        runtimeDiagnosticReportExists: Bool, sourcePixelMode: Bool,
        fullPhysicalMode: Bool
    ) -> Report {
        let mode: String
        if fullPhysicalMode { mode = "source_float64_experimental" }
        else if sourcePixelMode { mode = "source_8bit_direct_limited" }
        else { mode = "mobile_compatible" }
        let iso=ISO8601DateFormatter()
        iso.formatOptions=[.withInternetDateTime]
        return Report(
            schema:1, version:version, build:build,
            generatedUTC:iso.string(from:date), platform:platform,
            osVersion:osVersion, mode:mode,
            sourceLoaded:sourceLoaded,
            processedPreviewAvailable:processedPreviewAvailable,
            selectedMaterialPending:selectedMaterialPending,
            runtimeDiagnosticReportExists:runtimeDiagnosticReportExists,
            releaseCertification:"not_certified",
            manualChecks:manualChecklist()
        )
    }

    static func encode(_ report: Report) throws -> Data {
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return try encoder.encode(report)
    }

    /// Persist evidence in the app's Documents directory. This must NEVER
    /// be removed by Build98 temporary JPEG/TIFF lifecycle management.
    static func write(_ report: Report, documents: URL) throws -> URL {
        let folder=documents.appendingPathComponent(
            "SpektraFilm Verification", isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder, withIntermediateDirectories:true
        )
        let url=folder.appendingPathComponent(
            "Build100-checklist-" + UUID().uuidString
        ).appendingPathExtension("json")
        try encode(report).write(to:url,options:.atomic)
        return url
    }
}
