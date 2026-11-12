import Foundation

/// Entries generated exclusively from original upstream measured profile JSON.
/// The full unchanged spectral data files are bundled for a later native engine.
struct MeasuredStock: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let medium: String
    let stage: String
    let polarity: String
    let usage: String
    let channelModel: String
    let targetPrint: String?
    let referenceIlluminant: String
    let viewingIlluminant: String
    let wavelengthCount: Int
    let filename: String
    let sha256: String
    let profileVersion: String
    let license: String

    var categoryLabel: String {
        if medium == "paper" { return "相纸" }
        if usage == "cine" { return "电影胶片" }
        return "摄影胶片"
    }

    var polarityLabel: String {
        switch polarity {
        case "negative": return "负片"
        case "positive": return "反转片"
        default: return polarity
        }
    }
}

private struct MeasuredCatalogManifest: Decodable {
    let schemaVersion: Int
    let sourceRepository: String
    let profiles: [MeasuredStock]
}

struct MeasuredStockCatalog {
    static let shared = MeasuredStockCatalog()

    let profiles: [MeasuredStock]
    let error: String?

    init(bundle: Bundle = .main) {
        guard let resourceRoot = bundle.resourceURL else {
            profiles = []
            error = "无法读取 App 资源目录"
            return
        }
        // XcodeGen copies the folder reference 'Resources' intact.
        let candidates = [
            resourceRoot.appendingPathComponent("Resources/profiles/index.json"),
            resourceRoot.appendingPathComponent("profiles/index.json")
        ]
        guard let indexURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            profiles = []
            error = "未找到内置光谱配置索引，请确认构建时执行了 stage_profiles.py"
            return
        }

        do {
            let decoded = try JSONDecoder().decode(
                MeasuredCatalogManifest.self, from: Data(contentsOf: indexURL)
            )
            guard decoded.schemaVersion == 1,
                  decoded.sourceRepository == "andreavolpato/spektrafilm" else {
                profiles = []
                error = "光谱配置索引版本或来源不匹配"
                return
            }
            // Read-only metadata. Do not synthesize a rendered look from it.
            profiles = decoded.profiles
            error = nil
        } catch {
            profiles = []
            self.error = "光谱配置索引解析失败：" + error.localizedDescription
        }
    }

    var filmingStocks: [MeasuredStock] {
        profiles.filter { $0.medium == "film" && $0.stage == "filming" &&
            $0.channelModel == "color" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var papers: [MeasuredStock] {
        profiles.filter { $0.medium == "paper" && $0.stage == "printing" &&
            $0.channelModel == "color" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func stock(_ id: String) -> MeasuredStock? {
        profiles.first { $0.id == id }
    }

    func hasBundledSource(for stock: MeasuredStock) -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let direct = resources.appendingPathComponent("Resources/profiles/" + stock.filename)
        let alternate = resources.appendingPathComponent("profiles/" + stock.filename)
        return FileManager.default.fileExists(atPath: direct.path) ||
               FileManager.default.fileExists(atPath: alternate.path)
    }
}
