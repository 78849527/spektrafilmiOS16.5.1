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
    @State private var showPhotoPicker = false
    @State private var showLUTPicker = false
    @State private var showShare = false
    @State private var exportedURL: URL?
    @State private var message: String?

    private var cubeType: UTType {
        UTType(filenameExtension: "cube", conformingTo: .data) ?? .data
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
                            showPhotoPicker = true
                        } label: {
                            Label("文件图片", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()
                    HStack {
                        Button {
                            showLUTPicker = true
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
                            exportedURL = try model.exportJPEG()
                            showShare = true
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
                    Text("阶段 1：只应用标准 3D .cube LUT。要求 sRGB 输入／输出、0–1 Domain。不是完整的光谱胶片模拟；RAW、物理颗粒、光晕待移植。导出超过 1250 万像素会等比缩小。")
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
            .fileImporter(isPresented: $showPhotoPicker, allowedContentTypes: [.image]) {
                result in
                switch result {
                case .success(let url): model.loadPhotoFile(url)
                case .failure(let error): message = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $showLUTPicker, allowedContentTypes: [cubeType]) {
                result in
                switch result {
                case .success(let url): model.loadLUTFile(url)
                case .failure(let error): message = error.localizedDescription
                }
            }
            .sheet(isPresented: $showShare) {
                if let exportedURL {
                    ActivitySheet(items: [exportedURL])
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
