import Foundation
import SwiftUI

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
    private static func accepted(_ url:URL,documents root:URL)->(camera:Bool)? {
        let file=url.standardizedFileURL
        let parent=file.deletingLastPathComponent()
        let camera=root.appendingPathComponent("SpektraFilm RAW").standardizedFileURL
        let imported=root.appendingPathComponent("SpektraFilm RAW Imports").standardizedFileURL
        let name=file.deletingPathExtension().lastPathComponent
        let ext=file.pathExtension.lowercased()
        if parent == camera,ext == "dng",name.hasPrefix("SF-RAW-"),
           UUID(uuidString:String(name.dropFirst(7))) != nil {
            return (camera:true)
        }
        // Build79 imports are uniquely named UUID.<actual RAW kind>.
        // No freeform filenames, nested paths or external locations.
        if parent == imported,UUID(uuidString:name) != nil,
           ["dng","raf","arw","nef","cr2","cr3","orf","rw2"].contains(ext) {
            return (camera:false)
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
                    cameraCapture:kind.camera
                ))
            }
        }
        return entries.sorted {
            ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast)
        }
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
    }
}

struct Build134LocalRAWManagerView: View {
    @ObservedObject var model: PhotoEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var saved=[Build134LocalRAWStorage.Entry]()
    @State private var selected:Build134LocalRAWStorage.Entry?
    @State private var failure:String?

    private func reload() {
        do {
            saved=try Build134LocalRAWStorage.list()
            failure=nil
        } catch {
            failure=error.localizedDescription
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("这里只管理 App 自己保存的 RAW 原片副本。删除后不可撤销；不会删除照片图库或其他文件夹中的原片。若没有外部备份，删除会永久丢失该 DNG／RAF。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if let failure {
                        Text("操作失败："+failure)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
                Section("本机 RAW · \(saved.count) 个") {
                    if saved.isEmpty {
                        Text("没有 App 保存的 RAW 文件")
                            .foregroundColor(.secondary)
                    }
                    ForEach(saved) { item in
                        HStack(spacing:10) {
                            VStack(alignment:.leading,spacing:4) {
                                Text(item.cameraCapture ? "相机 DNG" : "导入 RAW 副本")
                                    .font(.subheadline)
                                Text(item.url.lastPathComponent)
                                    .font(.system(size:10,design:.monospaced))
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(
                                    fromByteCount:item.bytes,countStyle:.file))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if model.isCurrentSavedRAW(item.url) {
                                    Text("当前编辑正在使用")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer(minLength:8)
                            Button(role:.destructive) {
                                selected=item
                            } label: {
                                Image(systemName:"trash")
                                    .frame(width:36,height:36)
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.busy)
                            .accessibilityLabel("删除本机文件 "+item.url.lastPathComponent)
                        }
                    }
                }
            }
            .navigationTitle("本机 RAW 管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.navigationBarTrailing) {
                    Button("完成") { dismiss() }
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
                                    "正在冲印，禁止删除所需 RAW")
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
