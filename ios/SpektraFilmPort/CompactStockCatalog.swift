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
        GeneratedMeasuredProfiles.entries.filter { $0.medium == "paper" && $0.stage == "printing" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("适配 iOS 16.5.1 · 当前仅 Portra400+Endura 支持模拟")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                Picker("类型", selection: $category) {
                    Text("胶片 \(films.count)").tag(0)
                    Text("相纸 \(papers.count)").tag(1)
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
                Text("胶片和相纸全目录只显示原始元数据；v0.3 的实验光学引擎仅支持 Portra 400 与 Portra Endura，其他组合尚不可用。")
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
