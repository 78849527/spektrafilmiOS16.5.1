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
    @Published var status = "选择照片，再导入 sRGB→sRGB .cube LUT。"
    @Published var busy = false
    @Published var photoDimensions = ""
    @Published var filmExposureEV = 0.0
    @Published var printExposureEV = 0.0
    @Published var scatterEnabled = false
    @Published var halationEnabled = false
    @Published var halationAmount = 1.0
    @Published var grainEnabled = false
    @Published var grainAmount = 1.0
    // Experimental source-scanner path is OPT-IN. Initial UI and
    // old calculated looks remain identical to user-tested v1.0.1.
    @Published var originalScannerEnabled = false
    @Published var scannerCAM16Enabled = false
    @Published var scannerBlackWhiteEnabled = false
    @Published var scannerFinishingEnabled = false
    @Published var scannerSharpenAmount = 0.7
    // New v1.3 effects opt-in. The confirmed-safe v1.0.1 floating UI
    // and old v1.2 scanner results remain unchanged until toggled.
    @Published var exposureReferenceEnabled = false
    @Published var printMorphEnabled = false
    @Published var printGamma = 1.0
    @Published var printFastGamma = 1.0
    @Published var printSlowGamma = 1.0
    @Published var printDeveloperExhaustion = 0.0
    // Original enlarger/filtered-light experiments. OFF by default:
    // v1.0.1 UI and all v1.3 optics retain existing results.
    @Published var enlargerEnabled = false
    @Published var enlargerNormalize = true
    @Published var enlargerMShift = 0.0
    @Published var enlargerYShift = 0.0
    @Published var enlargerPreflash = 0.0
    @Published var enlargerFlashMShift = 0.0
    @Published var enlargerFlashYShift = 0.0
    private var densityGrainStage: DensityGrainStage?

    private var scannerFinishSettings: ScannerFinishSettings {
        let filmID = UserDefaults.standard.string(forKey: "compactFilmStock")
            ?? "kodak_portra_400"
        return ScannerFinishSettings(
            enabled: scannerFinishingEnabled,
            applyGlare: !SpectralPhysics.isPositiveFilm(filmID),
            unsharpAmount: scannerSharpenAmount,
            glarePercent: 0.03,
            seed: 8888
        )
    }

    private var grainSettings: DensityGrainSettings? {
        guard grainEnabled, grainAmount > 0, let stage = densityGrainStage else {
            return nil
        }
        return DensityGrainSettings(stage: stage, amount: grainAmount, seed: 8888)
    }

    // Spatial convolution settings depend on the original stock's base
    // material and antihalation layer. Original film data lives in generated
    // metadata; no large JSON bundle is read at app launch.
    private var spatialSettings: SpatialOpticsSettings {
        let selected = UserDefaults.standard.string(forKey: "compactFilmStock")
            ?? "kodak_portra_400"
        let info = GeneratedMeasuredProfiles.entries.first { $0.id == selected }
        return SpatialOpticsSettings(
            scatterAmount: scatterEnabled ? 1.0 : 0.0,
            halationAmount: halationEnabled ? halationAmount : 0.0,
            filmUse: info?.usage ?? "still",
            antihalation: info?.antihalation ?? "strong"
        )
    }

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
            densityGrainStage = nil
            grainEnabled = false
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
        let selectionDescription = SpectralPhysics.isPositiveFilm(filmID)
            ? (filmName + " · 反转片直扫")
            : (filmName + " → " + paperName)
        busy = true
        status = "正在计算 \(selectionDescription)，原版 Hanatos2025 光谱输入…"
        let cameraExposure = filmExposureEV
        let enlargerExposure = printExposureEV
        let requiresGrainStage = grainEnabled
        let originalScanner = originalScannerEnabled
        let referenceBW = scannerBlackWhiteEnabled
        let cam16 = scannerCAM16Enabled
        let enlargerSettings = OriginalEnlarger.Settings(
            enabled: enlargerEnabled,
            normalizeExposure: enlargerNormalize,
            mShift: enlargerMShift, yShift: enlargerYShift,
            preflashExposure: enlargerPreflash,
            preflashMShift: enlargerFlashMShift,
            preflashYShift: enlargerFlashYShift
        )
        let useExposureReference = exposureReferenceEnabled
        let printMorph = printMorphEnabled
            ? OriginalPrintMorph.Settings(
                gamma: printGamma, fast: printFastGamma,
                slow: printSlowGamma, developerExhaustion: printDeveloperExhaustion
              )
            : OriginalPrintMorph.Settings()
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let cube = try SpectralPhysics.makeCubeData(
                        filmID: filmID, paperID: paperID,
                        exposureEV: cameraExposure, paperEV: enlargerExposure,
                        size: 17,
                        sourceScanner: originalScanner,
                        scannerBlackWhite: referenceBW,
                        cam16Gamut: cam16,
                        printReferenceCorrection: useExposureReference,
                        printMorph: printMorph,
                        enlarger: enlargerSettings
                    )
                    let density = try requiresGrainStage
                        ? SpectralPhysics.makeDensityStageData(
                            filmID: filmID, paperID: paperID,
                            exposureEV: cameraExposure, paperEV: enlargerExposure,
                            size: 17,
                            sourceScanner: originalScanner,
                            scannerBlackWhite: referenceBW,
                            cam16Gamut: cam16,
                            printReferenceCorrection: useExposureReference,
                            printMorph: printMorph,
                            enlarger: enlargerSettings
                          ) : nil
                    return (cube, density)
                }.value
                guard generation == renderGeneration else { return }
                if let stage = result.1 {
                    densityGrainStage = DensityGrainStage(
                        toDensity: stage.inputCube,
                        fromDensity: stage.printCube,
                        cubeDimension: stage.size,
                        maxDensity: stage.ranges
                    )
                } else {
                    densityGrainStage = nil
                }
                lut = FilmLUT(
                    title: "实测光谱 · \(selectionDescription) (实验)",
                    dimension: 17, rgbaFloatData: result.0
                )
                strength = 1.0
                try refresh()
                status = "已应用 \(selectionDescription)，胶片 \(String(format: "%+.2f", cameraExposure)) EV。" +
                    (requiresGrainStage ? "显影密度颗粒 → 原版印相链路已启用。" : "原版光谱链路已启用。")
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
        processedPreview = try PhotoProcessor.preview(
            source, lut: lut, strength: strength, spatial: spatialSettings,
            grain: grainSettings, scanner: scannerFinishSettings
        )
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
        let result = try PhotoProcessor.exportJPEG(
            source, lut: lut, strength: strength, spatial: spatialSettings,
            grain: grainSettings, scanner: scannerFinishSettings
        )
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
            FloatingEditorWorkspace(
                model: model,
                selectedPhoto: $selectedPhoto,
                selectedFilmID: $selectedFilmID,
                selectedPaperID: $selectedPaperID,
                onOpenPhotoFile: {
                    model.status = "请选择 JPEG / HEIC / PNG / TIFF 图片文件"
                    activeSheet = .photo
                },
                onOpenLUT: {
                    model.status = "请选择 .cube 文件"
                    activeSheet = .lut
                },
                onOpenCatalog: {
                    activeSheet = .stocks
                },
                onExport: {
                    do {
                        let url = try model.exportJPEG()
                        activeSheet = .share(url)
                    } catch {
                        message = error.localizedDescription
                    }
                },
                onRefresh: { refresh() }
            )
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: selectedPhoto) { item in
                model.selectFromPhotos(item)
            }
            .onChange(of: selectedFilmID) { _ in
                model.queueSpectralPreview()
            }
            .onChange(of: selectedPaperID) { _ in
                model.queueSpectralPreview()
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


