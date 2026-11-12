import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class PhotoEditorModel: ObservableObject {
    @Published var originalPreview: UIImage?
    @Published var processedPreview: UIImage?
    @Published var lut: FilmLUT?
    @Published var strength = 1.0
    @Published var showOriginal = false
    @Published var status = "选择照片，再导入 sRGB→sRGB .cube LUT。"
    @Published var busy = false
    @Published var photoDimensions = ""

    // Selection stores original upstream identifiers; it does NOT render a
    // simulated look until a real native spectral engine is connected.
    @Published var selectedFilmID = "kodak_portra_400"
    @Published var selectedPaperID = "kodak_portra_endura"

    // Do not parse bundled JSON during app startup: on iOS 16 the editor
    // must open even if the new stock catalog or a signed resource is damaged.
    init() {
        selectedFilmID = UserDefaults.standard.string(forKey: "selectedFilmStock")
            ?? "kodak_portra_400"
        selectedPaperID = UserDefaults.standard.string(forKey: "selectedPaperStock")
            ?? "kodak_portra_endura"
    }

    func filmChanged() {
        let catalog = MeasuredStockCatalog.shared
        UserDefaults.standard.set(selectedFilmID, forKey: "selectedFilmStock")
        if let preferred = catalog.stock(selectedFilmID)?.targetPrint,
           catalog.papers.contains(where: { $0.id == preferred }) {
            selectedPaperID = preferred
            UserDefaults.standard.set(preferred, forKey: "selectedPaperStock")
        }
        status = "胶片配置已选择：\(catalog.stock(selectedFilmID)?.name ?? selectedFilmID)。目前尚未连接原版物理计算，照片效果仍由外部 LUT 控制。"
    }

    func paperChanged() {
        UserDefaults.standard.set(selectedPaperID, forKey: "selectedPaperStock")
        status = "相纸配置已选择：\(MeasuredStockCatalog.shared.stock(selectedPaperID)?.name ?? selectedPaperID)。原版物理印相计算待接入。"
    }

    private var source: CIImage?
    var hasPhoto: Bool { source != nil }

    func selectFromPhotos(_ selection: PhotosPickerItem?) {
        guard let selection else { return }
        busy = true
        status = "正在读取照片…"
        Task {
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw ImageProcessingError.invalid("相册未提供照片数据")
                }
                try loadPhoto(data)
            } catch {
                status = "相册导入失败：" + error.localizedDescription
            }
            busy = false
        }
    }

    func loadPhotoFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            try loadPhoto(Data(contentsOf: url))
        } catch {
            status = "文件导入失败：" + error.localizedDescription
        }
    }

    private func loadPhoto(_ data: Data) throws {
        let decoded = try PhotoProcessor.decode(data)
        source = decoded
        photoDimensions = "\(Int(decoded.extent.width)) × \(Int(decoded.extent.height))"
        originalPreview = try PhotoProcessor.preview(decoded, lut: nil, strength: 0)
        try refresh()
    }

    func loadLUTFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            lut = try FilmLUT.read(text: text,
                filename: url.deletingPathExtension().lastPathComponent)
            try refresh()
        } catch {
            status = "LUT 导入失败：" + error.localizedDescription
        }
    }

    func refresh() throws {
        guard let source else {
            status = lut == nil ? "请先导入照片。" : "LUT 已导入，请选择照片。"
            return
        }
        processedPreview = try PhotoProcessor.preview(source, lut: lut, strength: strength)
        showOriginal = false
        if let lut {
            status = "已应用 \(lut.title) · \(lut.dimension)³ LUT · \(photoDimensions)"
        } else {
            status = "原图预览成功，尚未导入 LUT（未进行胶片模拟）。"
        }
    }

    func exportJPEG() throws -> URL {
        guard let source else {
            throw ImageProcessingError.invalid("请先导入照片")
        }
        let result = try PhotoProcessor.exportJPEG(source, lut: lut, strength: strength)
        let note = result.downsampled ? "（高于 1250 万像素，已缩小）" : "（原像素尺寸）"
        status = "已导出 \(result.width) × \(result.height) JPEG \(note)"
        return result.url
    }
}

struct ContentView: View {
    @StateObject private var model = PhotoEditorModel()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var activeSheet: ImportSheet?
    @State private var message: String?

    // Use a single native document picker for both file entry points. A
    // restrictive UTType or multiple fileImporter modifiers can hide .cube
    // files and nonstandard images from third-party Files providers.
    private enum ImportSheet: Identifiable {
        case photo
        case lut
        case stocks
        case share(URL)

        var id: String {
            switch self {
            case .photo: return "photo-file"
            case .lut: return "lut-file"
            case .stocks: return "stock-catalog"
            case .share(let url): return "share-" + url.absoluteString
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("原始 Spektrafilm · iOS 移植实验")
                        .font(.subheadline).foregroundStyle(.secondary)

                    ZStack {
                        Rectangle().fill(Color(white: 0.10))
                        if let preview = model.showOriginal
                            ? model.originalPreview : model.processedPreview {
                            Image(uiImage: preview)
                                .resizable().scaledToFit().padding(4)
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 36))
                                Text("导入照片开始")
                            }
                            .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 370)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("照片图库", systemImage: "photo")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            model.status = "请选择 JPEG / HEIC / PNG / TIFF 图片文件"
                            activeSheet = .photo
                        } label: {
                            Label("文件图片", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()

                    // Keep this main editor identical to the stable v0.1
                    // startup path. Open the measured-profile view explicitly.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("原版胶片与相纸").font(.headline)
                        Button {
                            activeSheet = .stocks
                        } label: {
                            Label("打开胶片 / 相纸配置", systemImage: "film.stack")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        Text("胶片配置在独立页面读取；不会影响照片导入和启动。选择配置尚不等于应用物理模拟。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()
                    HStack {
                        Button {
                            model.status = "请选择 .cube 文件；其他扩展名会在选择后提示"
                            activeSheet = .lut
                        } label: {
                            Label("导入 .cube", systemImage: "square.stack.3d.up")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Text(model.lut?.title ?? "未选择 LUT")
                            .font(.caption).lineLimit(2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("LUT 强度")
                            Spacer()
                            Text("\(Int(model.strength * 100))%").monospacedDigit()
                        }
                        Slider(value: $model.strength, in: 0...1, step: 0.05,
                               onEditingChanged: { editing in
                            if !editing { refresh() }
                        })
                        .disabled(model.lut == nil || !model.hasPhoto)
                        Toggle("对比原图", isOn: $model.showOriginal)
                            .disabled(!model.hasPhoto)
                    }

                    Button {
                        do {
                            let url = try model.exportJPEG()
                            activeSheet = .share(url)
                        } catch {
                            message = error.localizedDescription
                        }
                    } label: {
                        Label("导出 JPEG / 分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasPhoto || model.busy)

                    Text(model.status)
                        .font(.footnote).foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Divider()
                    Text("v0.2：已内置原版胶片／相纸的实测数据和选择器，但未连接物理渲染。照片效果仍仅应用外部 3D .cube LUT（要求 sRGB 输入输出、0–1 Domain）。RAW、物理颗粒与光晕待移植。超过 1250 万像素会缩小导出。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("基于 Andrea Volpato 的 Spektrafilm。GPLv3，非官方移植。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("SpektraFilm Port")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: selectedPhoto) { item in
                model.selectFromPhotos(item)
            }
            .sheet(item: $activeSheet) { selection in
                switch selection {
                case .photo:
                    FilesDocumentPicker(onPick: { url in
                        model.loadPhotoFile(url)
                        activeSheet = nil
                    }, onCancel: {
                        activeSheet = nil
                    })
                case .lut:
                    FilesDocumentPicker(onPick: { url in
                        model.loadLUTFile(url)
                        activeSheet = nil
                    }, onCancel: {
                        activeSheet = nil
                    })
                case .stocks:
                    StockCatalogSheet(model: model)
                case .share(let url):
                    ActivitySheet(items: [url])
                }
            }
            .alert("提示", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("确定", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func refresh() {
        do { try model.refresh() }
        catch { message = error.localizedDescription }
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ viewController: UIActivityViewController, context: Context) {}
}

    
/// We intentionally open *all* document items instead of filtering .cube or
/// .image up front. Some providers (iCloud Drive, On My iPhone, third-party
/// file providers) do not advertise uncommon extensions as these UTTypes.
/// We validate the extension and actual content after selecting the file.
private struct FilesDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            // The picker supplies a sandbox copy. Consume it synchronously
            // before dismissing the sheet and releasing the temporary URL.
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}


/// The catalog is opt-in and loaded only after the user opens this sheet.
/// Avoid eager file reads in the editor's init/body, so corrupted or missing
/// re-signed bundle resources cannot prevent the basic app from launching.
private struct StockCatalogSheet: View {
    @ObservedObject var model: PhotoEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: MeasuredStockCatalog?
    @State private var selectedCategory = 0

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    if let error = catalog.error {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("配置读取失败").font(.headline)
                            Text(error).font(.footnote).textSelection(.enabled)
                            Text("照片导入与外部 LUT 功能仍可使用。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding()
                    } else {
                        VStack(spacing: 0) {
                            Picker("类型", selection: $selectedCategory) {
                                Text("拍摄胶片").tag(0)
                                Text("印相相纸").tag(1)
                            }
                            .pickerStyle(.segmented).padding()

                            List {
                                Section {
                                    Text("已读取 \(catalog.filmingStocks.count) 款拍摄胶片和 \(catalog.papers.count) 款相纸。配置来自原版实测资料，尚未接入物理显影计算。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(selectedCategory == 0 ? catalog.filmingStocks : catalog.papers) { stock in
                                    Button {
                                        if selectedCategory == 0 {
                                            model.selectedFilmID = stock.id
                                            model.filmChanged()
                                        } else {
                                            model.selectedPaperID = stock.id
                                            model.paperChanged()
                                        }
                                    } label: {
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(stock.name)
                                                    .foregroundStyle(.primary)
                                                Text("\(stock.polarityLabel) · \(stock.wavelengthCount) 个光谱采样点")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            if selectedCategory == 0 && model.selectedFilmID == stock.id ||
                                               selectedCategory == 1 && model.selectedPaperID == stock.id {
                                                Image(systemName: "checkmark.circle.fill")
                                            }
                                        }
                                    }
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在验证原版光谱配置…").font(.footnote)
                    }
                }
            }
            .navigationTitle("原版胶片与相纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            // Loading here instead of during App/PhotoEditorModel initialization
            // is the critical launch-isolation change of v0.2.1.
            .task {
                if catalog == nil {
                    catalog = MeasuredStockCatalog()
                }
            }
        }
    }
}
