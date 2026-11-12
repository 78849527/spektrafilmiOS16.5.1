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
    @Published var filmExposureEV = 0.0
    @Published var printExposureEV = 0.0

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

    /// Compute an internal optical LUT from measured wavelength data.
    /// Keep the proven photo importer and CoreImage renderer unchanged.
    func applyMeasuredSimulation() {
        guard hasPhoto else {
            status = "请先选择照片，再模拟真实胶片数据。"
            return
        }
        let filmID = UserDefaults.standard.string(forKey: "compactFilmStock") ?? "kodak_portra_400"
        let paperID = UserDefaults.standard.string(forKey: "compactPaperStock") ?? "kodak_portra_endura"
        guard filmID == "kodak_portra_400" && paperID == "kodak_portra_endura" else {
            status = "v0.3 实验引擎目前仅支持 Portra 400 + Portra Endura；请在胶片目录中选回这一组合。"
            return
        }
        guard !busy else { return }
        busy = true
        status = "正在使用 81 个波长采样计算 Portra 400 → Portra Endura 的光学色彩表…"
        let cameraExposure = filmExposureEV
        let enlargerExposure = printExposureEV
        Task {
            do {
                let cubeData = try await Task.detached(priority: .userInitiated) {
                    try SpectralPhysics.makeCubeData(
                        exposureEV: cameraExposure, paperEV: enlargerExposure,
                        size: 17
                    )
                }.value
                lut = FilmLUT(
                    title: "实测曲线·Portra 400 + Portra Endura (实验)",
                    dimension: 17, rgbaFloatData: cubeData
                )
                strength = 1.0
                try refresh()
                status = "已应用简化光谱模拟 · 胶片 \(String(format: "%+.2f", cameraExposure)) EV · 相纸 \(String(format: "%+.2f", enlargerExposure)) EV。非原版完整渲染。"
            } catch {
                status = "光谱计算失败：" + error.localizedDescription
            }
            busy = false
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
                    Button {
                        activeSheet = .stocks
                    } label: {
                        Label("原版胶片与相纸（iOS 16.5.1）", systemImage: "film.stack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    Text("轻量目录保留；v0.3 新增 Portra 400 + Portra Endura 简化光谱模拟。")
                        .font(.caption2).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 9) {
                        Text("原版实测曲线模拟 · v0.3 实验").font(.headline)
                        Text("当前仅支持 Kodak Portra 400 → Kodak Portra Endura。采用原始感光曲线、负片与相纸特性曲线及染料光谱；谱线重建与色彩校正仍是简化版本。")
                            .font(.caption).foregroundStyle(.secondary)

                        HStack {
                            Text("胶片曝光")
                            Spacer()
                            Text(String(format: "%+.2f EV", model.filmExposureEV)).monospacedDigit()
                        }
                        Slider(value: $model.filmExposureEV, in: -2...2, step: 0.25)
                            .disabled(model.busy)
                        HStack {
                            Text("印相曝光")
                            Spacer()
                            Text(String(format: "%+.2f EV", model.printExposureEV)).monospacedDigit()
                        }
                        Slider(value: $model.printExposureEV, in: -2...2, step: 0.25)
                            .disabled(model.busy)
                        Button {
                            model.applyMeasuredSimulation()
                        } label: {
                            Label("计算并应用光谱模拟", systemImage: "waveform.path")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !model.hasPhoto)
                        if model.busy {
                            ProgressView("光谱数据计算中…")
                        }
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
                    Text("v0.3 实验：81 波长实测数据驱动的简化胶片／印相光学计算。内部生成 17³ 颜色加速表。没有移植原版 Hanatos 光谱重建、染料耦合、光晕、颗粒与完整色彩校正。仍支持外部 sRGB .cube LUT 和 JPEG 导出（最多 1250 万像素）。")
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
                    CompactStockCatalogView()
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
