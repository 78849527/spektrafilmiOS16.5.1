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

    // Debounce scrolling wheels; never let a stale render replace new settings.
    private var renderGeneration = 0
    private var pendingRender: Task<Void, Never>?

    func queueSpectralPreview() {
        pendingRender?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        guard hasPhoto else { return }
        pendingRender = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled && generation == renderGeneration else { return }
            applyMeasuredSimulation(generation: generation)
        }
    }

    private func invalidateSimulation() {
        pendingRender?.cancel()
        renderGeneration &+= 1
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
        invalidateSimulation()
        let decoded = try PhotoProcessor.decode(data)
        source = decoded
        photoDimensions = "\(Int(decoded.extent.width)) × \(Int(decoded.extent.height))"
        originalPreview = try PhotoProcessor.preview(decoded, lut: nil, strength: 0)
        try refresh()
        queueSpectralPreview()
    }

    func loadLUTFile(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let importedLUT = try FilmLUT.read(text: text,
                filename: url.deletingPathExtension().lastPathComponent)
            invalidateSimulation()
            lut = importedLUT
            busy = false
            try refresh()
        } catch {
            status = "LUT 导入失败：" + error.localizedDescription
        }
    }

    /// Compute an internal optical LUT from measured wavelength data.
    /// Keep the proven photo importer and CoreImage renderer unchanged.
    func applyMeasuredSimulation() {
        pendingRender?.cancel()
        renderGeneration &+= 1
        applyMeasuredSimulation(generation: renderGeneration)
    }

    private func applyMeasuredSimulation(generation: Int) {
        guard hasPhoto else {
            status = "请先选择照片，再模拟真实胶片数据。"
            return
        }
        let filmID = UserDefaults.standard.string(forKey: "compactFilmStock") ?? "kodak_portra_400"
        let paperID = UserDefaults.standard.string(forKey: "compactPaperStock") ?? "kodak_portra_endura"
        guard SpectralPhysics.supportedFilmIDs.contains(filmID),
              SpectralPhysics.supportedPaperIDs.contains(paperID) else {
            status = "该组合暂时只有原版目录数据，没有可用的光学模拟。请从目录中选择标注「可模拟」的胶片与相纸。"
            return
        }
        let sourceNames = Dictionary(uniqueKeysWithValues:
            GeneratedMeasuredProfiles.entries.map { ($0.id, $0.name) }
        )
        let filmName = sourceNames[filmID] ?? filmID
        let paperName = sourceNames[paperID] ?? paperID
        busy = true
        status = "正在计算 \(filmName) → \(paperName)，81 波长实测数据…"
        let cameraExposure = filmExposureEV
        let enlargerExposure = printExposureEV
        Task {
            do {
                let cubeData = try await Task.detached(priority: .userInitiated) {
                    try SpectralPhysics.makeCubeData(
                        filmID: filmID, paperID: paperID,
                        exposureEV: cameraExposure, paperEV: enlargerExposure,
                        size: 17
                    )
                }.value
                guard generation == renderGeneration else { return }
                lut = FilmLUT(
                    title: "实测曲线·\(filmName) → \(paperName) (实验)",
                    dimension: 17, rgbaFloatData: cubeData
                )
                strength = 1.0
                try refresh()
                status = "已应用 \(filmName) → \(paperName) · 胶片 \(String(format: "%+.2f", cameraExposure)) EV · 相纸 \(String(format: "%+.2f", enlargerExposure)) EV。仍是简化光谱模拟。"
            } catch {
                guard generation == renderGeneration else { return }
                status = "光谱计算失败：" + error.localizedDescription
            }
            if generation == renderGeneration { busy = false }
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
    @AppStorage("compactFilmStock") private var selectedFilmID = "kodak_portra_400"
    @AppStorage("compactPaperStock") private var selectedPaperID = "kodak_portra_endura"

    // The inline wheels show only the measured profiles backed by physics.
    private var wheelFilms: [MeasuredStock] {
        SpectralPhysics.supportedFilmIDs.compactMap { id in
            GeneratedMeasuredProfiles.entries.first { $0.id == id }
        }
    }

    private var wheelPapers: [MeasuredStock] {
        SpectralPhysics.supportedPaperIDs.compactMap { id in
            GeneratedMeasuredProfiles.entries.first { $0.id == id }
        }
    }

    private func shortStockName(_ stock: MeasuredStock) -> String {
        stock.name
            .replacingOccurrences(of: "Kodak Professional ", with: "")
            .replacingOccurrences(of: "Kodak ", with: "")
            .replacingOccurrences(of: "Fujifilm ", with: "Fuji ")
            .replacingOccurrences(of: "Crystal Archive Type II", with: "Crystal II")
    }

    private var activePairIsSupported: Bool {
        SpectralPhysics.supportedFilmIDs.contains(selectedFilmID) &&
        SpectralPhysics.supportedPaperIDs.contains(selectedPaperID)
    }

    private var currentStockDescription: String {
        let names = Dictionary(uniqueKeysWithValues:
            GeneratedMeasuredProfiles.entries.map { ($0.id, $0.name) }
        )
        return (names[selectedFilmID] ?? selectedFilmID) +
               " → " + (names[selectedPaperID] ?? selectedPaperID)
    }

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
                        if model.hasPhoto {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Text(model.showOriginal ? "原图" : "长按查看原图")
                                        .font(.caption2)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(Color.black.opacity(0.55), in: Capsule())
                                }
                                .padding(12)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 370)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    // iOS 16.5.1: press on preview to see the unedited original;
                    // the pressing callback restores the current processing on release.
                    .onLongPressGesture(
                        minimumDuration: 0.18,
                        maximumDistance: 18,
                        pressing: { isPressing in
                            model.showOriginal = model.hasPhoto && isPressing
                        },
                        perform: {}
                    )

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
                    Text("胶片 × 相纸")
                        .font(.headline)
                    Text("上下拨动左侧胶片或相纸，停下即自动更新预览。")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    GeometryReader { geometry in
                        let columnWidth = max(118, (geometry.size.width - 12) / 2)
                        HStack(alignment: .top, spacing: 12) {
                            // Two independent vertical wheels in the lower-left.
                            VStack(alignment: .leading, spacing: 2) {
                                Text("胶片 FILM")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                Picker("胶片", selection: $selectedFilmID) {
                                    ForEach(wheelFilms) { film in
                                        Text(shortStockName(film))
                                            .font(.caption)
                                            .tag(film.id)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .labelsHidden()
                                .frame(width: columnWidth - 14, height: 128)
                                .clipped()

                                Divider().padding(.vertical, 3)

                                Text("相纸 PAPER")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)
                                Picker("相纸", selection: $selectedPaperID) {
                                    ForEach(wheelPapers) { paper in
                                        Text(shortStockName(paper))
                                            .font(.caption)
                                            .tag(paper.id)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .labelsHidden()
                                .frame(width: columnWidth - 14, height: 128)
                                .clipped()

                                Button("完整胶片目录") {
                                    activeSheet = .stocks
                                }
                                .font(.caption2)
                                .padding(.top, 6)
                            }
                            .frame(width: columnWidth - 14, alignment: .leading)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            )

                            // All continuous adjustments stay on the right.
                            VStack(alignment: .leading, spacing: 11) {
                                Text("调整")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.secondary)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("胶片曝光")
                                        .font(.caption)
                                    Text(String(format: "%+.2f EV", model.filmExposureEV))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                    Slider(value: $model.filmExposureEV,
                                           in: -2...2, step: 0.25,
                                           onEditingChanged: { editing in
                                        if !editing { model.queueSpectralPreview() }
                                    })
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("相纸曝光")
                                        .font(.caption)
                                    Text(String(format: "%+.2f EV", model.printExposureEV))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                    Slider(value: $model.printExposureEV,
                                           in: -2...2, step: 0.25,
                                           onEditingChanged: { editing in
                                        if !editing { model.queueSpectralPreview() }
                                    })
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text("效果强度")
                                            .font(.caption)
                                        Spacer(minLength: 0)
                                        Text("\(Int(model.strength * 100))%")
                                            .font(.caption2)
                                            .monospacedDigit()
                                    }
                                    Slider(value: $model.strength,
                                           in: 0...1, step: 0.05,
                                           onEditingChanged: { editing in
                                        if !editing { refresh() }
                                    })
                                    .disabled(model.lut == nil || !model.hasPhoto)
                                }

                                Button {
                                    model.applyMeasuredSimulation()
                                } label: {
                                    Text("应用模拟")
                                        .font(.caption)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.hasPhoto || !activePairIsSupported)

                                if model.busy {
                                    ProgressView("计算中")
                                        .font(.caption2)
                                } else {
                                    Text("拨轮停止后自动计算")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(width: columnWidth, alignment: .leading)
                            .padding(.vertical, 7)
                        }
                    }
                    .frame(height: 360)
                    .onChange(of: selectedFilmID) { _ in
                        model.queueSpectralPreview()
                    }
                    .onChange(of: selectedPaperID) { _ in
                        model.queueSpectralPreview()
                    }
                    Text(currentStockDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Text("6 款负片 × 3 款相纸；原版实测曲线驱动的简化光谱模拟。")
                        .font(.caption2)
                        .foregroundColor(.secondary)

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
                    Text("v0.4：已接入 6 款原版负片与 3 款相纸的 81 波长实测曲线，内部生成 17³ 光学色彩加速表。未移植原版 Hanatos 光谱重建、染料耦合、光晕、颗粒与完整色彩校正；反转片仍仅能查看资料。保留 sRGB .cube 和 JPEG 导出。")
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
