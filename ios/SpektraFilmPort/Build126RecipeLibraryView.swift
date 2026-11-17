import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Build126: lightweight recipe shelf, deliberately NOT a second photo album.
/// Images are optional 240px covers only; sensor RAW and full photos stay out.
struct Build126RecipeLibraryView:View {
    @ObservedObject var model:PhotoEditorModel
    @Binding var selectedFilmID:String
    @Binding var selectedPaperID:String
    @Environment(\.dismiss) private var dismiss

    @State private var newName=""
    @State private var saveCover=false
    @State private var editingID:UUID?
    @State private var editingName=""
    @State private var deletion:Build126Recipe?
    @State private var importPresented=false
    @State private var exportedURL:URL?
    @State private var feedback:String?

    private var sortedRecipes:[Build126Recipe] {
        model.savedRecipes.sorted {
            if $0.favorite != $1.favorite {return $0.favorite}
            return $0.modifiedAt > $1.modifiedAt
        }
    }
    private var canCapture:Bool {
        model.hasPhoto && !model.busy &&
        !model.simulationAwaitingCurrentSettings &&
        !model.isRecipeApplying && model.processedPreview != nil &&
        model.lut != nil
    }

    private func run(_ work:() throws->Void) {
        do {try work()}
        catch {feedback=error.localizedDescription}
    }
    private func apply(_ recipe:Build126Recipe) {
        do {
            try model.applySavedRecipe(recipe)
            // The editor's stock picker mirrors model.UserDefaults.
            // A running recipe transaction owns the single render.
            selectedFilmID=recipe.filmID
            selectedPaperID=recipe.paperID
            dismiss()
        } catch {
            feedback=error.localizedDescription +
                "\n已放弃应用。照片、原有参数与预览均未改变。"
        }
    }
    private func recipeRow(_ recipe:Build126Recipe)->some View {
        VStack(alignment:.leading,spacing:6) {
            HStack(alignment:.center,spacing:10) {
                if let data=recipe.coverJPEG,let image=UIImage(data:data) {
                    Image(uiImage:image)
                        .resizable()
                        .scaledToFill()
                        .frame(width:54,height:54)
                        .clipped()
                        .cornerRadius(7)
                        .accessibilityLabel("可选配方效果缩略图；不包含完整原片")
                } else {
                    Image(systemName:"camera.filters")
                        .frame(width:54,height:54)
                        .background(Color.primary.opacity(0.06),
                                    in:RoundedRectangle(cornerRadius:7))
                }
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:5) {
                        Text(recipe.name).font(.subheadline).fontWeight(.semibold)
                        if recipe.favorite {
                            Image(systemName:"star.fill")
                                .font(.caption2)
                        }
                    }
                    Text(recipe.bools["sourcePhysicalDirectEnabled"] == true
                         ? "精细全光学 · 严格校验"
                         : (recipe.bools["sourcePixelIOEnabled"] == true
                            ? "8-bit 原版像素直连 · 严格校验" : "快速冲印"))
                        .font(.caption2).foregroundColor(.secondary)
                    Text("胶片／相纸 + 101 项参数" +
                         (recipe.embeddedLUT == nil ? "" : " + 自定义 LUT"))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer(minLength:2)
                Button("应用") {apply(recipe)}
                    .buttonStyle(.bordered)
                    .disabled(!model.hasPhoto || model.busy ||
                              model.isRecipeApplying ||
                              model.simulationAwaitingCurrentSettings)
                Menu {
                    Button("收藏／取消收藏") {
                        run {try model.toggleRecipeFavorite(recipe)}
                    }
                    Button("重命名") {
                        editingID=recipe.id
                        editingName=recipe.name
                    }
                    Button("复制配置") {
                        run {try model.duplicateSavedRecipe(recipe)}
                    }
                    Button("导出配置文件") {
                        run {exportedURL=try model.exportSavedRecipe(recipe)}
                    }
                    Button("删除配置",role:.destructive) {
                        deletion=recipe
                    }
                } label: {
                    Image(systemName:"ellipsis.circle")
                }
            }
            if editingID==recipe.id {
                HStack {
                    TextField("新配方名称",text:$editingName)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") {
                        run {
                            try model.renameSavedRecipe(recipe,to:editingName)
                            editingID=nil
                        }
                    }
                    Button("取消") {editingID=nil}
                }
                .font(.caption)
            }
        }
        .padding(.vertical,4)
    }

    var body:some View {
        NavigationStack {
            Form {
                Section("保存当前效果") {
                    TextField("配方名称，例如：重庆夜色 Portra 400",
                              text:$newName)
                        .textInputAutocapitalization(.never)
                    Toggle("附带效果缩略图（最多 240px）",
                           isOn:$saveCover)
                    Text("只保存冲印参数。默认不存储图片；选择封面仅保存一张小缩略图。")
                        .font(.caption2).foregroundColor(.secondary)
                    Button("保存完整配置") {
                        run {
                            try model.addSavedRecipe(
                                name:newName,includeCover:saveCover
                            )
                            newName=""
                        }
                    }
                    .disabled(!canCapture ||
                              newName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                Section("我的冲印配方（" + String(model.savedRecipes.count) + "）") {
                    if model.savedRecipes.isEmpty {
                        Text("尚无配方。先打开照片，调出满意效果后保存。")
                            .foregroundColor(.secondary)
                    }
                    ForEach(sortedRecipes) { recipe in
                        recipeRow(recipe)
                    }
                }
                Section("备份与交换") {
                    Button("从文件导入配方") {
                        importPresented=true
                    }
                    if let url=exportedURL {
                        ShareLink(item:url) {
                            Label("分享已导出的配方文件",
                                  systemImage:"square.and.arrow.up")
                        }
                    }
                    Text("导入只加入配方库，不应用，不保存照片；" +
                         "应用前仍重新检查相机 RAW、8-bit、DIR 及光学前置条件。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("我的冲印配方")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) {
                    Button("完成"){dismiss()}
                }
            }
            .fileImporter(isPresented:$importPresented,
                          allowedContentTypes:[.json]) { result in
                switch result {
                case .success(let url):
                    run {try model.importSavedRecipe(url)}
                case .failure(let error):
                    feedback=error.localizedDescription
                }
            }
            .confirmationDialog(
                "确定删除这个配方？",
                isPresented:Binding(
                    get:{deletion != nil},
                    set:{if !$0 {deletion=nil}}
                ),
                titleVisibility:.visible
            ) {
                Button("删除配方",role:.destructive) {
                    if let item=deletion {
                        run {try model.deleteSavedRecipe(item)}
                    }
                    deletion=nil
                }
                Button("取消",role:.cancel){deletion=nil}
            } message: {
                Text("只删除保存的参数和可选缩略图，不影响当前照片或原始 DNG。")
            }
            .alert("配方提示",isPresented:Binding(
                get:{feedback != nil},
                set:{if !$0 {feedback=nil}}
            )) {
                Button("关闭",role:.cancel){feedback=nil}
            } message: {
                Text(feedback ?? "")
            }
        }
    }
}
