import SwiftUI

// Build-time generated original Spektrafilm stock metadata.
// This file deliberately avoids loading any spectral JSON at startup.
struct MeasuredStock: Identifiable, Hashable {
    let id: String
    let name: String
    let medium: String
    let stage: String
    let polarity: String
    let targetPrint: String?
    let wavelengthCount: Int
    let profileVersion: String
    let sha256: String
}

struct CompactStockCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("compactFilmStock") private var filmID = "kodak_portra_400"
    @AppStorage("compactPaperStock") private var paperID = "kodak_portra_endura"
    @State private var category = 0

    private var films: [MeasuredStock] {
        GeneratedMeasuredProfiles.entries.filter { $0.medium == "film" && $0.stage == "filming" }
    }
    private var papers: [MeasuredStock] {
        GeneratedMeasuredProfiles.entries.filter { $0.stage == "printing" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("iOS 16.5.1 · 20 款胶片、8 种印相介质")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                Picker("类型", selection: $category) {
                    Text("胶片 \(films.count)").tag(0)
                    Text("印相 \(papers.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                List(category == 0 ? films : papers) { stock in
                    Button {
                        if category == 0 {
                            filmID = stock.id
                            if let p = stock.targetPrint, papers.contains(where: { $0.id == p }) {
                                paperID = p
                            }
                        } else {
                            paperID = stock.id
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stock.name).foregroundStyle(.primary)
                                Text("\(stock.wavelengthCount) 采样点 · \(stock.profileVersion)")
                                    .font(.caption).foregroundStyle(.secondary)
                                let canSimulate = category == 0
                                    ? SpectralPhysics.supportedFilmIDs.contains(stock.id)
                                    : SpectralPhysics.supportedPaperIDs.contains(stock.id)
                                Text(canSimulate
                                    ? (category == 0 && stock.polarity == "positive"
                                       ? "反转片：直接扫描" : "实测光谱：可模拟")
                                    : "仅原版数据目录")
                                    .font(.caption2)
                                    .foregroundColor(canSimulate ? Color.green : Color.secondary)
                            }
                            Spacer()
                            if (category == 0 && filmID == stock.id) ||
                               (category == 1 && paperID == stock.id) {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                Text("20 款原版拍摄胶片和 8 款印相介质已接入。16 款负片可选择相纸/电影印片；4 款反转片使用直接扫描，不需相纸。仍不代表完整原版显影与颗粒处理已全部移植。")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
            .navigationTitle("原始胶片数据目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
