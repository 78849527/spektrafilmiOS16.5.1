import Foundation
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Build134: only files created by SpektraFilm are eligible for in-app removal.
/// Imported originals held by a Files provider or Photos are never enumerated.
enum Build134LocalRAWStorage {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }
    struct Entry: Identifiable {
        let url: URL
        let bytes: Int64
        let updated: Date?
        let cameraCapture: Bool
        var id: String { url.standardizedFileURL.path }
    }
    private static func documents() throws -> URL {
        guard let url=FileManager.default.urls(
            for:.documentDirectory,in:.userDomainMask).first else {
            throw Failure.invalid("无法找到本机 App 文档目录")
        }
        return url.standardizedFileURL
    }
    private static func accepted(_ url:URL,documents root:URL)->Bool? {
        let file=url.standardizedFileURL
        let parent=file.deletingLastPathComponent()
        let camera=root.appendingPathComponent("SpektraFilm RAW").standardizedFileURL
        let imported=root.appendingPathComponent("SpektraFilm RAW Imports").standardizedFileURL
        let name=file.deletingPathExtension().lastPathComponent
        let ext=file.pathExtension.lowercased()
        if parent == camera,ext == "dng",name.hasPrefix("SF-RAW-"),
           UUID(uuidString:String(name.dropFirst(7))) != nil {
            return true
        }
        // Build79 imports are uniquely named UUID.<actual RAW kind>.
        // No freeform filenames, nested paths or external locations.
        if parent == imported,UUID(uuidString:name) != nil,
           ["dng","raf","arw","nef","cr2","cr3","orf","rw2"].contains(ext) {
            return false
        }
        return nil
    }
    static func list() throws -> [Entry] {
        let fm=FileManager.default
        let root=try documents()
        var entries=[Entry]()
        for dir in ["SpektraFilm RAW","SpektraFilm RAW Imports"] {
            let folder=root.appendingPathComponent(dir,isDirectory:true)
            guard fm.fileExists(atPath:folder.path) else {continue}
            let urls=try fm.contentsOfDirectory(
                at:folder,includingPropertiesForKeys:[
                    .isRegularFileKey,.isSymbolicLinkKey,
                    .fileSizeKey,.contentModificationDateKey
                ],options:[.skipsHiddenFiles]
            )
            for url in urls {
                guard let kind=accepted(url,documents:root) else {continue}
                let values=try url.resourceValues(forKeys:[
                    .isRegularFileKey,.isSymbolicLinkKey,
                    .fileSizeKey,.contentModificationDateKey
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {continue}
                entries.append(Entry(
                    url:url,bytes:Int64(values.fileSize ?? 0),
                    updated:values.contentModificationDate,
                    cameraCapture:kind
                ))
            }
        }
        return entries.sorted {
            ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast)
        }
    }

    /// The DNG is authoritative. The small JPEG is a catalog-only thumbnail,
    /// NEVER an input to either Apple RAW or Float64 source rendering.
    private static func previewDirectory() throws -> URL {
        guard let support=FileManager.default.urls(
            for:.applicationSupportDirectory,in:.userDomainMask
        ).first else {
            throw Failure.invalid("无法找到 App 缩略图目录")
        }
        let folder=support.appendingPathComponent(
            "SpektraFilm RAW Thumbnails",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true
        )
        return folder
    }

    private static func thumbnailURL(for raw:URL) throws -> URL {
        try previewDirectory().appendingPathComponent(
            raw.lastPathComponent+".jpg"
        )
    }

    private static func makeSmallJPEG(_ companion:Data) -> Data? {
        guard let source=CGImageSourceCreateWithData(
            companion as CFData,[kCGImageSourceShouldCache:false] as CFDictionary
        ),let thumb=CGImageSourceCreateThumbnailAtIndex(
            source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:320,
                kCGImageSourceShouldCacheImmediately:true
            ] as CFDictionary
        ) else { return nil }
        let data=NSMutableData()
        guard let writer=CGImageDestinationCreateWithData(
            data,UTType.jpeg.identifier as CFString,1,nil
        ) else {return nil}
        CGImageDestinationAddImage(
            writer,thumb,[
                kCGImageDestinationLossyCompressionQuality:0.78
            ] as CFDictionary
        )
        return CGImageDestinationFinalize(writer) ? data as Data : nil
    }

    /// Capture once, return its retained DNG URL. A thumbnail failure must
    /// not discard the RAW or silently replace it with the companion JPEG.
    static func archiveCameraRAW(
        raw:Data,companion:Data
    ) throws -> URL {
        guard !raw.isEmpty else {
            throw Failure.invalid("拍摄未返回 DNG 原始数据")
        }
        let folder=try documents().appendingPathComponent(
            "SpektraFilm RAW",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true
        )
        let target=folder.appendingPathComponent(
            "SF-RAW-"+UUID().uuidString+".dng"
        )
        try raw.write(to:target,options:.atomic)
        // DNG keeps its bytes and metadata. Thumbnail is derived only from
        // the already-returned companion JPEG and is capped at 320px.
        if let bytes=makeSmallJPEG(companion),
           let thumb=try? thumbnailURL(for:target) {
            try? bytes.write(to:thumb,options:.atomic)
        }
        return target
    }

    static func isManaged(_ url:URL) -> Bool {
        guard let root=try? documents(),
              accepted(url,documents:root) != nil,
              let attributes=try? url.resourceValues(
                forKeys:[.isRegularFileKey,.isSymbolicLinkKey]
              ) else {return false}
        return attributes.isRegularFile == true &&
               attributes.isSymbolicLink != true
    }

    /// Catalog-only embedded preview fallback for older DNG/RAF captures.
    /// Never create a thumbnail by demosaicing a full-size sensor RAW.
    static func thumbnailData(for url:URL) -> Data? {
        guard isManaged(url) else {return nil}
        if let preview=try? thumbnailURL(for:url),
           let data=try? Data(contentsOf:preview),
           !data.isEmpty {
            return data
        }
        guard let source=CGImageSourceCreateWithURL(
            url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary
        ),let image=CGImageSourceCreateThumbnailAtIndex(
            source,0,[
                kCGImageSourceCreateThumbnailFromImageIfAbsent:false,
                kCGImageSourceThumbnailMaxPixelSize:320,
                kCGImageSourceShouldCacheImmediately:false
            ] as CFDictionary
        ) else {return nil}
        let output=NSMutableData()
        guard let dest=CGImageDestinationCreateWithData(
            output,UTType.jpeg.identifier as CFString,1,nil
        ) else {return nil}
        CGImageDestinationAddImage(dest,image,nil)
        return CGImageDestinationFinalize(dest) ? output as Data : nil
    }
    static func delete(_ url: URL) throws {
        let root=try documents()
        guard accepted(url,documents:root) != nil else {
            throw Failure.invalid("拒绝删除 App 管理范围之外的原始文件")
        }
        let target=url.standardizedFileURL
        // Revalidate immediately before unlink: no folders, symbolic links
        // or renamed arbitrary files, and no deletion by guessed paths.
        guard try list().contains(where:{$0.url.standardizedFileURL == target}) else {
            throw Failure.invalid("文件已移动或不属于 App 保存的 RAW 列表")
        }
        try FileManager.default.removeItem(at:target)
        if let preview=try? thumbnailURL(for:target) {
            try? FileManager.default.removeItem(at:preview)
        }
    }
}

/// Async, capped preview for catalog use. An unavailable embedded thumbnail
/// is represented by an icon, not a full-size RAW decode or JPEG optical input.
private struct Build134RAWThumbnail: View {
    let item: Build134LocalRAWStorage.Entry
    @State private var image:UIImage?

    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:9).fill(Color.secondary.opacity(0.09))
            if let image {
                Image(uiImage:image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                    .clipped()
                    .cornerRadius(9)
            } else {
                VStack(spacing:5) {
                    Image(systemName:"photo.on.rectangle.angled")
                        .font(.system(size:27))
                    Text("RAW")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .aspectRatio(4.0/3.0,contentMode:.fit)
        .task(id:item.id) {
            image=nil
            let url=item.url
            let bytes=await Task.detached(priority:.utility) {
                Build134LocalRAWStorage.thumbnailData(for:url)
            }.value
            image=bytes.flatMap { UIImage(data:$0) }
        }
        .accessibilityLabel(item.cameraCapture
            ? "相机 RAW 缩略图" : "导入 RAW 缩略图")
    }
}

struct Build134LocalRAWManagerView: View {
    @ObservedObject var model: PhotoEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var saved=[Build134LocalRAWStorage.Entry]()
    @State private var selected:Build134LocalRAWStorage.Entry?
    @State private var failure:String?
    private let columns=[
        GridItem(.flexible(),spacing:10),
        GridItem(.flexible(),spacing:10)
    ]

    private func reload() {
        do {
            saved=try Build134LocalRAWStorage.list()
            failure=nil
        } catch {
            failure=error.localizedDescription
        }
    }

    private func openForProcessing(_ item:Build134LocalRAWStorage.Entry) {
        guard !model.busy else {return}
        guard Build134LocalRAWStorage.isManaged(item.url) else {
            failure="RAW 原片已移动或删除，无法打开"
            reload()
            return
        }
        model.openSavedRAWFromLibrary(item.url)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    Text("先连续拍摄，再从这里选 RAW 冲印。缩略图只用于浏览；冲印仍读取完整 DNG／RAF 原片。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("本机 RAW · \(saved.count) 张")
                        .font(.subheadline.weight(.semibold))
                    if let failure {
                        Text("操作失败："+failure)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                    if saved.isEmpty {
                        Text("暂无本机 RAW。相机选择 RAW DNG，拍摄后会自动保存在这里。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.vertical,24)
                    }
                    LazyVGrid(columns:columns,spacing:12) {
                        ForEach(saved) { item in
                            VStack(alignment:.leading,spacing:6) {
                                Button {openForProcessing(item)} label: {
                                    VStack(alignment:.leading,spacing:5) {
                                        Build134RAWThumbnail(item:item)
                                        Text(item.cameraCapture ? "相机 DNG" : "导入 RAW")
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.primary)
                                        Text(item.url.lastPathComponent)
                                            .font(.system(size:10,design:.monospaced))
                                            .lineLimit(1)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(model.busy)
                                HStack(spacing:3) {
                                    Text(ByteCountFormatter.string(
                                        fromByteCount:item.bytes,countStyle:.file
                                    ))
                                    .lineLimit(1)
                                    Spacer(minLength:2)
                                    if model.isCurrentSavedRAW(item.url) {
                                        Image(systemName:"checkmark.circle.fill")
                                            .accessibilityLabel("当前编辑中")
                                    }
                                    Button(role:.destructive) {
                                        selected=item
                                    } label: {
                                        Image(systemName:"trash")
                                            .frame(width:30,height:32)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(model.busy)
                                    .accessibilityLabel("删除本机文件 "+item.url.lastPathComponent)
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius:12)
                                    .fill(Color.secondary.opacity(0.05))
                            )
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle("本机 RAW 素材库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.navigationBarLeading) {
                    Button("刷新") {reload()}
                }
                ToolbarItem(placement:.navigationBarTrailing) {
                    Button("完成") {dismiss()}
                }
            }
            .onAppear(perform:reload)
            .alert(item:$selected) { item in
                Alert(
                    title:Text("确认永久删除 RAW？"),
                    message:Text(
                        item.url.lastPathComponent +
                        (model.isCurrentSavedRAW(item.url)
                          ? "\n当前冲印正在使用此原片，删除后将退出本次编辑。"
                          : "") +
                        "\n此操作不可撤销。只有 App 内的保存副本会删除。"
                    ),
                    primaryButton:.destructive(Text("删除本机 RAW")) {
                        do {
                            guard !model.busy else {
                                throw Build134LocalRAWStorage.Failure.invalid(
                                    "正在冲印，禁止删除所需 RAW"
                                )
                            }
                            try Build134LocalRAWStorage.delete(item.url)
                            model.didDeleteSavedRAW(item.url)
                            reload()
                        } catch {
                            failure=error.localizedDescription
                        }
                    },
                    secondaryButton:.cancel(Text("取消"))
                )
            }
        }
    }
}
