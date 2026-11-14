import PhotosUI
import SwiftUI
import UIKit

/// iOS 16.5.1 portrait editor: the actual photograph is a permanently
/// mounted full-window canvas. All film wheels and continuous adjustments
/// live in independently collapsible, draggable translucent dock panels.
/// No scrolling container is allowed to move or resize the preview.
struct FloatingEditorWorkspace: View {
    @ObservedObject var model: PhotoEditorModel
    @Binding var selectedPhoto: PhotosPickerItem?
    @Binding var selectedFilmID: String
    @Binding var selectedPaperID: String

    let onOpenPhotoFile: () -> Void
    let onOpenCamera: () -> Void
    let onShareRaw: () -> Void
    let onOpenLUT: () -> Void
    let onOpenCatalog: () -> Void
    let onExport: (ExportResolutionMode) -> Void
    let onSaveToPhotos: (ExportResolutionMode) -> Void
    let onRefresh: () -> Void

    @State private var originalHeld = false
    // Initialize only the photo and toolbar on iOS 16.5.1.
    // The two heavy UIKit picker docks are mounted only after opt-in.
    @State private var controlsVisible = false
    @State private var wheelExpanded = false
    @State private var adjustmentExpanded = false
    // Last opened panel always overlays the older panel.
    @State private var frontDrawer: DrawerSide = .film
    @State private var selectedSettingSection: AdjustmentSection = .exposure
    @State private var comparisonEnabled = false
    @State private var statusReportPresented = false
    @State private var compareFraction = 0.5
    @State private var photoScale: CGFloat = 1.0

    private enum DrawerSide { case film, adjustment }
    private enum AdjustmentSection: String, CaseIterable {
        case exposure = "基础"
        case scanner = "扫描"
        case print = "印相"
        case optics = "光学"
        case dir = "DIR"
        case grain = "颗粒"
    }

    private func openFilmDrawer() {
        withAnimation(.easeOut(duration: 0.22)) {
            wheelExpanded = true
            frontDrawer = .film
        }
    }
    private func closeFilmDrawer() {
        withAnimation(.easeOut(duration: 0.22)) { wheelExpanded = false }
    }
    private func openAdjustmentDrawer() {
        withAnimation(.easeOut(duration: 0.22)) {
            adjustmentExpanded = true
            frontDrawer = .adjustment
        }
    }
    private func closeAdjustmentDrawer() {
        withAnimation(.easeOut(duration: 0.22)) { adjustmentExpanded = false }
    }

    private var films: [MeasuredStock] {
        SpectralPhysics.supportedFilmIDs.compactMap { id in
            GeneratedMeasuredProfiles.entries.first { $0.id == id }
        }
    }
    private var media: [MeasuredStock] {
        SpectralPhysics.supportedPaperIDs.compactMap { id in
            GeneratedMeasuredProfiles.entries.first { $0.id == id }
        }
    }
    private var isReversal: Bool {
        SpectralPhysics.isPositiveFilm(selectedFilmID)
    }
    private func shortName(_ stock: MeasuredStock) -> String {
        stock.name
            .replacingOccurrences(of: "Kodak Professional ", with: "")
            .replacingOccurrences(of: "Kodak ", with: "")
            .replacingOccurrences(of: "Fujifilm ", with: "Fuji ")
            .replacingOccurrences(of: "Crystal Archive Type II", with: "Crystal II")
    }

    var body: some View {
        GeometryReader { canvas in
            let available = canvas.size
            let wheelWidth = max(132, min(168, available.width * 0.42))
            let adjustWidth = max(148, min(204, available.width - wheelWidth - 24))
            ZStack {
                Color.black
                // Fixed top-to-bottom order; image starts right below
                // diagnostics. The toolbar never overlays the preview.
                VStack(spacing: 4) {
                    if controlsVisible && model.hasPhoto {
                        Button {
                            statusReportPresented = true
                        } label: {
                            statusChip
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看完整状态及 Metal 数值诊断报告")
                        .padding(.horizontal, 9)
                        .padding(.top, 7)
                    }
                    GeometryReader { previewSlot in
                        previewArea(size: previewSlot.size)
                            .frame(width: previewSlot.size.width,
                                   height: previewSlot.size.height,
                                   alignment: .top)
                            .clipped()
                    }
                    bottomToolbar
                        .padding(.horizontal, 8)
                        .padding(.bottom, 7)
                }
                .frame(width: available.width, height: available.height)
            }
            // Edge-absorbed drawers replace the two freely floating docks.
            // The last panel opened is visually above the first one.
            .overlay(alignment: .bottom) {
                if controlsVisible && model.hasPhoto {
                    let filmWidth = max(168, min(204, available.width * 0.49))
                    let drawerHeight = min(326, max(280, available.height * 0.45))
                    ZStack(alignment: .bottom) {
                        Group {
                            if wheelExpanded {
                                wheelDock(width: filmWidth)
                                    .frame(height: drawerHeight,
                                           alignment: .top)
                            } else {
                                edgeDrawerTab("胶片\n相纸", symbol: "film",
                                              side: .film)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .zIndex(frontDrawer == .film ? 2.0 : 1.0)

                        Group {
                            if adjustmentExpanded {
                                adjustmentDock(width: available.width,
                                               maxHeight: drawerHeight - 38)
                            } else {
                                edgeDrawerTab("调节", symbol: "slider.horizontal.3",
                                              side: .adjustment)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .zIndex(frontDrawer == .adjustment ? 2.0 : 1.0)
                    }
                    .padding(.bottom, 63)
                    .animation(.easeInOut(duration: 0.22),
                               value: wheelExpanded)
                    .animation(.easeInOut(duration: 0.22),
                               value: adjustmentExpanded)
                }
            }
            .sheet(isPresented: $statusReportPresented) {
                statusReportSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .background(Color.black.ignoresSafeArea())
            // Preserve picker/dock lazy mounting for iOS 16.5.1.
        }
    }

    private func previewImage(_ picture: UIImage?, size: CGSize) -> some View {
        Group {
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height,
                           alignment: .top)
                    .scaleEffect(photoScale, anchor: .top)
            } else {
                VStack(spacing: 11) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 42))
                    Text("导入照片开始")
                        .font(.subheadline)
                }
                .foregroundColor(.white.opacity(0.7))
                .frame(width: size.width, height: size.height)
            }
        }
    }

    @ViewBuilder
    private func previewArea(size: CGSize) -> some View {
        if comparisonEnabled,
           model.originalPreview != nil, model.processedPreview != nil {
            comparisonArea(size: size)
        } else {
            ZStack(alignment: .bottom) {
                previewImage(
                    originalHeld ? model.originalPreview : model.processedPreview,
                    size: size
                )
                if model.hasPhoto && controlsVisible {
                    Text(originalHeld ? "原图" : "按住看原图 · 双击放大")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                let next = photoScale > 1 ? CGFloat(1) : CGFloat(2)
                withAnimation(.easeInOut(duration: 0.2)) {
                    photoScale = next
                }
            }
            .overlay {
                if model.hasPhoto {
                    StableImageHoldRecognizer(isHolding: $originalHeld)
                }
            }
        }
    }

    private func comparisonArea(size: CGSize) -> some View {
        ZStack {
            previewImage(model.processedPreview, size: size)
            previewImage(model.originalPreview, size: size)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: size.width * compareFraction)
                }
            Rectangle()
                .fill(.white)
                .frame(width: 2)
                .position(x: size.width * compareFraction, y: size.height / 2)
            Image(systemName: "arrow.left.and.right")
                .font(.caption)
                .foregroundColor(.black)
                .padding(10)
                .background(.white, in: Circle())
                .position(x: size.width * compareFraction, y: size.height / 2)
            HStack {
                Text("原图")
                Spacer()
                Text("效果")
            }
            .font(.caption2)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    compareFraction = min(0.98, max(0.02,
                        gesture.location.x / max(1, size.width)))
                }
        )
    }

    private var bottomToolbar: some View {
        HStack(spacing: 7) {
            toolButton("camera.fill", name: "NextLevel 专业拍照并直接冲印", action: onOpenCamera)
                .disabled(model.busy)
            if model.capturedRAWURL != nil {
                toolButton("doc", name: "分享拍摄的原始 DNG 文件", action: onShareRaw)
                    .disabled(model.busy)
            }
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo")
            }
            .accessibilityLabel("从相册导入照片")

            toolButton("folder", name: "从文件导入照片", action: onOpenPhotoFile)
            toolButton("cube", name: "导入 .cube LUT", action: onOpenLUT)
            // Keep both original buttons in place. Each opens a size menu:
            // original unchanged, adaptive 50% of live memory, or <=3MP economy.
            // Do not silently shrink after a failed original-size render.
            Menu {
                Button("原始分辨率（不缩小）") {
                    onSaveToPhotos(.original)
                }
                Button("智能安全分辨率（约 50% 内存预算）") {
                    onSaveToPhotos(.safe)
                }
                Button("省内存分辨率（最高 300 万像素）") {
                    onSaveToPhotos(.economy)
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 33, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("保存相册：选择原始、智能安全或省内存分辨率")
            .disabled(!model.hasPhoto || model.busy)
            Menu {
                Button("原始分辨率（不缩小）") {
                    onExport(.original)
                }
                Button("智能安全分辨率（约 50% 内存预算）") {
                    onExport(.safe)
                }
                Button("省内存分辨率（最高 300 万像素）") {
                    onExport(.economy)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 33, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("分享存储：选择原始、智能安全或省内存分辨率")
            .disabled(!model.hasPhoto || model.busy)

            Spacer(minLength: 2)

            toolButton(comparisonEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                       name: "左右滑动对比", action: {
                comparisonEnabled.toggle()
                originalHeld = false
                compareFraction = 0.5
            })
            .disabled(!model.hasPhoto)

            toolButton(controlsVisible ? "eye" : "eye.slash",
                       name: controlsVisible ? "隐藏全部控件" : "显示双拨轮和调整",
                       action: { controlsVisible.toggle() })
        }
        .font(.system(size: 17, weight: .medium))
        .foregroundColor(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 46)
         .background(Color(uiColor: .secondarySystemBackground).opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 15))
    }

    private func toolButton(_ symbol: String, name: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 33, height: 40)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
    }

    /// Compact, always tappable summary. Full diagnostic evidence is scrollable.
    private var statusChip: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.busy ? "正在生成胶片预览…" : model.status)
                .font(.caption2)
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemBackground).opacity(0.93),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusReportSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.hardwareDiagnosticReport != nil {
                        Label("检测结果已完整保存，向下滚动查看全部项目",
                              systemImage: "checklist")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Text(model.hardwareDiagnosticReport ?? model.status)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("完整检测报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        UIPasteboard.general.string =
                            model.hardwareDiagnosticReport ?? model.status
                    } label: {
                        Label("复制全文", systemImage: "doc.on.doc")
                    }
                    .accessibilityLabel("复制完整诊断报告")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        statusReportPresented = false
                    }
                }
            }
        }
    }

    /// A single thin vertical handle remains touchable at either edge.
    /// Film opens by tap/right swipe; adjustment by tap/left swipe.
    private func edgeDrawerTab(_ title: String, symbol: String,
                               side: DrawerSide) -> some View {
        Button {
            if side == .film { openFilmDrawer() }
            else { openAdjustmentDrawer() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.caption)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.primary)
            .frame(width: 38, height: 94)
            .background(
                Color(uiColor: .secondarySystemBackground).opacity(0.94),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(side == .film
            ? "点击或向右滑动展开左侧胶片相纸拨轮"
            : "点击或向左滑动展开右侧全屏宽度调节面板")
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { g in
                    if side == .film && g.translation.width > 28 {
                        openFilmDrawer()
                    } else if side == .adjustment && g.translation.width < -28 {
                        openAdjustmentDrawer()
                    }
                }
        )
    }

    private func wheelDock(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .foregroundColor(.secondary)
                Text("胶片 · 相纸")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer(minLength: 2)
                Button(action: closeFilmDrawer) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                        .frame(width: 33, height: 34)
                }
                .accessibilityLabel("关闭胶片相纸面板，吸附左侧")
            }
            .frame(height: 38)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { g in
                        if g.translation.width < -32 { closeFilmDrawer() }
                    }
            )

            if wheelExpanded {
                Divider().padding(.horizontal, 6)
                Text("胶片 FILM · 双击复原")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .onTapGesture(count: 2) {
                        selectedFilmID = "kodak_portra_400"
                        model.queueSpectralPreview()
                    }
                    .padding(.horizontal, 9)
                    .padding(.top, 5)
                Picker("胶片", selection: $selectedFilmID) {
                    ForEach(films) { film in
                        Text(shortName(film)).font(.caption2).tag(film.id)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(width: width - 6, height: 103)
                .clipped()

                Divider().padding(.horizontal, 7)
                Text(isReversal ? "反转片 DIRECT" : "相纸 PAPER · 双击复原")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .onTapGesture(count: 2) {
                        selectedPaperID = "kodak_portra_endura"
                        model.queueSpectralPreview()
                    }
                    .padding(.horizontal, 9)
                    .padding(.top, 4)
                if isReversal {
                    VStack(spacing: 3) {
                        Image(systemName: "film")
                        Text("反转片直接扫描")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                } else {
                    Picker("相纸", selection: $selectedPaperID) {
                        ForEach(media) { stock in
                            Text(shortName(stock)).font(.caption2).tag(stock.id)
                        }
                    }
                    .pickerStyle(.wheel)
                    .labelsHidden()
                    .frame(width: width - 6, height: 103)
                    .clipped()
                }
                Button(action: onOpenCatalog) {
                    Text("全部 28 款材料")
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 7)
                }
            }
        }
        .frame(width: width)
        .foregroundColor(.primary)
         .background(Color(uiColor: .secondarySystemBackground).opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: 9, y: 3)
    }

    private func adjustmentDock(width: CGFloat, maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .foregroundColor(.secondary)
                Text("调整")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer(minLength: 2)
                Button {
                    model.applyMeasuredSimulation()
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                        .frame(width: 33, height: 34)
                }
                .disabled(!model.hasPhoto || model.busy)
                .accessibilityLabel("应用模拟")
                Button(action: closeAdjustmentDrawer) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .frame(width: 33, height: 34)
                }
                .accessibilityLabel("关闭调节面板，吸附右侧")
            }
            .frame(height: 38)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { g in
                        if g.translation.width > 32 { closeAdjustmentDrawer() }
                    }
            )
            if adjustmentExpanded {
                Divider()
                adjustmentControls
                    .frame(height: maxHeight)
            }
        }
        .frame(width: width, height: maxHeight + 38, alignment: .top)
        .foregroundColor(.primary)
         .background(Color(uiColor: .secondarySystemBackground).opacity(0.88),
                    in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: 9, y: 3)
    }

    // Row 1: horizontal one-line switches with 28x16 tracks.
    private var compactMainSwitches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                compactSwitch("64位", value: $model.hanatosOriginalPrecisionEnabled,
                              section: .exposure) { model.queueSpectralPreview() }
                compactSwitch("扫描", value: $model.originalScannerEnabled,
                              section: .scanner) { model.queueSpectralPreview() }
                compactSwitch("锐化", value: $model.scannerFinishingEnabled,
                              section: .scanner) { onRefresh() }
                compactSwitch("放大机", value: $model.originalPrintOpticsEnabled,
                              section: .print, allowed: !isReversal) {
                    model.queueSpectralPreview()
                }
                compactSwitch("预闪", value: $model.preflashEnabled,
                              section: .print,
                              allowed: !isReversal && model.originalPrintOpticsEnabled) {
                    model.queueSpectralPreview()
                }
                compactSwitch("s023", value: $model.printMorphEnabled,
                              section: .print, allowed: !isReversal) {
                    model.queueSpectralPreview()
                }
                compactSwitch("散射", value: $model.scatterEnabled,
                              section: .optics) { onRefresh() }
                compactSwitch("光晕", value: $model.halationEnabled,
                              section: .optics) { onRefresh() }
                compactSwitch("DIR", value: $model.spatialDIREnabled,
                              section: .dir) { model.queueSpectralPreview() }
                compactSwitch("颗粒", value: $model.grainEnabled,
                              section: .grain) {
                    if model.grainEnabled { model.queueSpectralPreview() }
                    else { onRefresh() }
                }
            }
            .padding(.horizontal, 5)
        }
        .frame(height: 34)
    }

    private func compactSwitch(_ title: String, value: Binding<Bool>,
                               section: AdjustmentSection, allowed: Bool = true,
                               changed: @escaping () -> Void) -> some View {
        Button {
            guard model.hasPhoto && !model.busy && allowed else { return }
            value.wrappedValue.toggle()
            selectedSettingSection = section
            changed()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                ZStack {
                    Capsule()
                        .fill(value.wrappedValue
                              ? Color.accentColor
                              : Color.gray.opacity(0.46))
                        .frame(width: 28, height: 16)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: value.wrappedValue ? 6 : -6)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!model.hasPhoto || model.busy || !allowed)
        .accessibilityLabel(title + (value.wrappedValue ? "，已开启" : "，已关闭"))
        .accessibilityHint("点按切换，并显示该项的二级参数")
    }

    // Row 2: categories; the selected category controls row 3.
    private var settingCategoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(AdjustmentSection.allCases, id: \.self) { section in
                    Button {
                        selectedSettingSection = section
                    } label: {
                        Text(section.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(selectedSettingSection == section
                                             ? Color.accentColor : .primary)
                            .padding(.horizontal, 11)
                            .frame(height: 27)
                            .background(
                                selectedSettingSection == section
                                    ? Color.accentColor.opacity(0.13)
                                    : Color.primary.opacity(0.07),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.rawValue + "二级设置")
                }
            }
            .padding(.horizontal, 5)
        }
        .frame(height: 31)
    }

    // Row 3: show just one parameter section, never the entire switch wall.
    private var adjustmentControls: some View {
        VStack(spacing: 4) {
            compactMainSwitches
            settingCategoryRow
            Divider().padding(.horizontal, 8)
            ScrollView(.vertical) {
                activeSettings
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var activeSettings: some View {
        switch selectedSettingSection {
        case .exposure: exposureSettings
        case .scanner: scannerSettings
        case .print: printSettings
        case .optics: opticsSettings
        case .dir: dirSettings
        case .grain: grainSettings
        }
    }

    private var exposureSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.hanatosOriginalPrecisionEnabled
                 ? "原版双精度光谱响应 · 未近似存储"
                 : "移动快速 Float16 光谱响应 · 已量化")
                .font(.caption2).foregroundColor(.secondary)
            exposureControl("胶片曝光", value: $model.filmExposureEV, enabled: model.hasPhoto,
                            onCommit: { model.queueSpectralPreview() })
            exposureControl(isReversal ? "反转片无需印相" : "相纸曝光",
                            value: $model.printExposureEV,
                            enabled: model.hasPhoto && !isReversal,
                            onCommit: { model.queueSpectralPreview() })
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("效果强度").font(.caption)
                        .onTapGesture(count: 2) {
                            model.strength = 1.0
                            onRefresh()
                        }
                    Spacer(minLength: 0)
                    Button {
                        guard model.hasPhoto && model.lut != nil && !model.busy else { return }
                        model.strength = 1.0
                        onRefresh()
                    } label: {
                        Text("\(Int(model.strength * 100))%")
                            .font(.caption2).monospacedDigit()
                            .frame(minWidth: 49, minHeight: 30, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.hasPhoto || model.lut == nil || model.busy)
                    .accessibilityLabel("效果强度，点击数值恢复默认 100%")
                }
                Slider(value: $model.strength, in: 0...1, step: 0.05,
                       onEditingChanged: { editing in
                    if !editing { onRefresh() }
                })
                .disabled(!model.hasPhoto || model.lut == nil)
            }

            Divider()
            Text("点右侧数值恢复默认 · 双击左侧名称复原")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
    }

    private var scannerSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.originalScannerEnabled {
                resetToggle("原版默认 CAM16-UCS", value: $model.scannerCAM16Enabled,
                            enabled: model.hasPhoto && !model.busy)
                    .onChange(of: model.scannerCAM16Enabled) { _ in
                        model.queueSpectralPreview()
                    }
                Text(model.scannerCAM16Enabled
                     ? "默认色域 · CAM16 查表插值"
                     : "可选色域 · ACES RGC")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                resetToggle("黑白场校准", value: $model.scannerBlackWhiteEnabled,
                            enabled: model.hasPhoto && !model.busy)
                    .onChange(of: model.scannerBlackWhiteEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                if model.scannerBlackWhiteEnabled && !isReversal {
                    resetToggle("按印相曝光计算黑白参考", value: $model.exposureReferenceEnabled,
                                enabled: model.hasPhoto && !model.busy)
                        .onChange(of: model.exposureReferenceEnabled) { _ in
                            model.queueSpectralPreview()
                        }
                    Text(model.exposureReferenceEnabled
                         ? "胶片两端 → 印相显影 → 曝光补偿"
                         : "使用旧版密度端点近似")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if model.scannerFinishingEnabled {
                strengthControl("锐化强度",
                                value: $model.scannerSharpenAmount,
                                range: 0...1.5, suffix: "×", resetTo: 0.7)
            }
        }
    }

    private var printSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            if !isReversal {
                if model.originalPrintOpticsEnabled {
                    Text("胶片 → 二色滤色光谱 → 相纸曝光")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    resetToggle("归一化印相曝光", value: $model.normalizePrintExposure,
                                enabled: model.hasPhoto && !model.busy,
                                resetTo: true)
                        .onChange(of: model.normalizePrintExposure) { _ in
                            model.queueSpectralPreview()
                        }
                    resetToggle("补偿拍摄曝光", value: $model.printExposureCompensation,
                                enabled: model.hasPhoto && !model.busy,
                                resetTo: true)
                        .onChange(of: model.printExposureCompensation) { _ in
                            model.queueSpectralPreview()
                        }
                    morphSlider("青色 C / CC", value: $model.printCyanShift,
                                range: -40...40)
                    morphSlider("洋红 M / CC", value: $model.printMagentaShift,
                                range: -40...40)
                    morphSlider("黄色 Y / CC", value: $model.printYellowShift,
                                range: -40...40)
                    if model.preflashEnabled {
                        morphSlider("预闪曝光", value: $model.preflashExposure,
                                    range: 0...0.2)
                        morphSlider("预闪 M / CC", value: $model.preflashMagentaShift,
                                    range: -40...40)
                        morphSlider("预闪 Y / CC", value: $model.preflashYellowShift,
                                    range: -40...40)
                        Text("原版相纸曝光累加，非 RGB 提亮")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Divider()
                if model.printMorphEnabled {
                    morphSlider("总体伽马", value: $model.printGamma,
                                range: 0.65...1.45, resetTo: 1.0)
                    morphSlider("快乳剂层", value: $model.printFastGamma,
                                range: 0.7...1.4, resetTo: 1.0)
                    morphSlider("慢乳剂层", value: $model.printSlowGamma,
                                range: 0.7...1.4, resetTo: 1.0)
                    morphSlider("显影剂疲劳", value: $model.printDeveloperExhaustion,
                                range: 0...1)
                    Text("原版三层 CDF，默认不改变已有曲线")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var opticsSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            // In the explicitly selected whole-physical path the familiar
            // switches use the source's actual Double photon optics.
            // Outside that path these remain unchanged mobile CI controls.
            if model.halationEnabled {
                strengthControl(model.sourcePixelIOEnabled && model.sourcePhysicalDirectEnabled
                                    ? "原版背反射倍率" : "光晕倍率",
                                value: $model.halationAmount,
                                range: 0...3, suffix: "×", resetTo: 1.0)
            }
            if model.sourcePixelIOEnabled && model.sourcePhysicalDirectEnabled {
                Text("上方两开关现直连 Python 原版 Double 光子域散射／背反射。" +
                     "单独启用可做 A/B 测试，不经过旧版 Core Image。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var dirSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            if model.spatialDIREnabled {
                resetToggle("DIR 原版 FIR/YVV", value: $model.spatialDIRSourceConvolutionEnabled,
                            enabled: model.hasPhoto && !model.busy,
                            resetTo: true)
                    .onChange(of: model.spatialDIRSourceConvolutionEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                Text(model.spatialDIRSourceConvolutionEnabled
                     ? "原版 reflect FIR／YVV IIR，双精度扩散；默认 CI 图像边界存在 Float16 量化"
                     : "移动快速 Core Image Gaussian；非原版精确边界")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if model.spatialDIRSourceConvolutionEnabled {
                    resetToggle("8-bit 原版像素直连（实验）",
                                value:$model.sourcePixelIOEnabled,
                                enabled:model.hasPhoto && !model.busy,
                                resetTo:false)
                        .onChange(of:model.sourcePixelIOEnabled) { _ in
                            if !model.sourcePixelIOEnabled {
                                model.sourcePhysicalDirectEnabled = false
                            }
                            model.queueSpectralPreview()
                        }
                    if model.sourcePixelIOEnabled {
                        resetToggle("逐像素全光学（实验）",
                                    value:$model.sourcePhysicalDirectEnabled,
                                    enabled:model.hasPhoto && !model.busy,
                                    resetTo:false)
                            .onChange(of:model.sourcePhysicalDirectEnabled) { _ in
                                model.queueSpectralPreview()
                            }
                        if model.sourcePhysicalDirectEnabled {
                            resetToggle("原版摄影曝光前处理（Double｜三模块）",
                                        value:$model.sourceCameraPreFilmEnabled,
                                        enabled:model.hasPhoto && !model.busy,
                                        resetTo:false)
                                .onChange(of:model.sourceCameraPreFilmEnabled) { _ in
                                    model.queueSpectralPreview()
                                }
                            if model.sourceCameraPreFilmEnabled {
                                Picker("原版自动测光", selection:$model.sourceCameraMeteringMethod) {
                                    ForEach(OriginalSourceCameraOptics.Metering.allCases,
                                            id:\.self) { method in
                                        Text(method.displayName).tag(method)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of:model.sourceCameraMeteringMethod) { _ in
                                    model.queueSpectralPreview()
                                }
                                morphSlider("曝光前高光恢复 EV",
                                            value:$model.sourceCameraHighlightBoostEV,
                                            range:0...4,resetTo:0)
                                morphSlider("高光恢复范围",
                                            value:$model.sourceCameraHighlightBoostRange,
                                            range:0...1,resetTo:0.3)
                                morphSlider("高光保护 EV",
                                            value:$model.sourceCameraHighlightProtectEV,
                                            range:0...8,resetTo:4)
                                morphSlider("原版摄影镜头模糊 μm",
                                            value:$model.sourceCameraLensBlurUM,
                                            range:0...80,resetTo:0)
                                Text("原版顺序：sRGB 测光→RGB 曝光补偿→Hanatos 光谱→" +
                                     "摄影 EV→全图原版高光 Boost→镜头 FIR/YVV→" +
                                     "胶片 H-D / DIR；高光与镜头计算均为整幅 Double。" +
                                     "关闭时保持 v1.8.29 源精确路径不变；" +
                                     "不包含尚未移植的摄影扩散/UV-IR；光晕在下方原版模块。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            resetToggle("原版乳剂散射＋背反射同时开启（Double）",
                                        value:$model.sourceFilmHalationEnabled,
                                        enabled:model.hasPhoto && !model.busy,
                                        resetTo:false)
                                .onChange(of:model.sourceFilmHalationEnabled) { _ in
                                    model.queueSpectralPreview()
                                }
                            if model.sourceFilmHalationEnabled {
                                morphSlider("乳剂散射比例",
                                            value:$model.sourceFilmScatterAmount,
                                            range:0...1,resetTo:1)
                                morphSlider("乳剂散射空间倍率",
                                            value:$model.sourceFilmScatterScale,
                                            range:0...3,resetTo:1)
                                morphSlider("背反射光晕比例",
                                            value:$model.sourceFilmHalationAmount,
                                            range:0...2,resetTo:1)
                                morphSlider("背反射空间倍率",
                                            value:$model.sourceFilmHalationScale,
                                            range:0...3,resetTo:1)
                                Text("Python 原版 HalationParams：RGB 独立核与指数尾巴；" +
                                     "三次反射、宽度乘 sqrt(k)、衰减 0.5、能量归一。" +
                                     "光子域镜头模糊→乳剂散射→背反射→H-D。" +
                                     "上方两个开关也支持分别启动原版 Double；" +
                                     "此处可同时启动两种光学模块。内存预算增加，" +
                                     "与旧版 Core Image 散射分离。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            resetToggle("原版扫描镜头 / Unsharp（Double）",
                                        value:$model.sourceScannerOpticalEnabled,
                                        enabled:model.hasPhoto && !model.busy,
                                        resetTo:false)
                                .onChange(of:model.sourceScannerOpticalEnabled) { _ in
                                    model.queueSpectralPreview()
                                }
                            if model.sourceScannerOpticalEnabled {
                                morphSlider("源扫描镜头模糊 σ / px",
                                            value:$model.sourceScannerLensBlurSigma,
                                            range:0...8,resetTo:0)
                                morphSlider("源扫描 Unsharp σ / px",
                                            value:$model.sourceScannerUnsharpSigma,
                                            range:0...8,resetTo:1)
                                morphSlider("源扫描 Unsharp 强度",
                                            value:$model.sourceScannerUnsharpAmount,
                                            range:0...2,resetTo:0.7)
                                Text("原版顺序：相纸光谱→XYZ/ACES 线性 RGB→" +
                                     "原版 reflect FIR/YVV 镜头模糊→Unsharp→" +
                                     "sRGB 编码。禁用随机眩光；导出增加真实内存预算。" +
                                     "不经过 Core Image Gaussian 或移动 LUT。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text("实算 Hanatos→胶片 H-D→空间 DIR FIR/YVV→" +
                             "相纸 H-D→光谱扫描；不经过颜色 3D LUT。" +
                             "实验上限提高到 1200 万像素；实际是否允许导出，" +
                             "按这台手机当前物理内存和 App 可用余量逐次检查。" +
                             "整图 Double FIR/YVV 与相纸显影均保留，不缩图；" +
                             "需开启原版 ACES 扫描、Hanatos Float64、" +
                             "负片原版放大机，关闭 CAM16/黑白参考。" +
                             "尚不支持随机颗粒和 RAW；乳剂光晕使用原版 Double。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(model.sourcePhysicalDirectEnabled
                         ? "逐像素全光学支持上方原版 Double 乳剂散射／光晕。" +
                           "随机颗粒与旧版 CI 扫描后处理仍不支持；不静默降级。"
                         : "仅不透明 8-bit：ImageIO→Double DIR→原尺寸 JPEG。" +
                           "普通 DIR 像素直连不支持散射／光晕／颗粒；" +
                           "原版散射需同时开启逐像素全光学。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                strengthControl("抑制剂扩散范围",
                                value: $model.spatialDIRRadiusScale,
                                range: 0.25...3.0, suffix: "×", resetTo: 1.0)
                Text("胶片曝光 → DIR 抑制剂空间扩散 → 密度曲线 → 印相")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("原版 20/200 μm 核；根据模式选择源 FIR/YVV 或 CI 近似")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var grainSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.grainEnabled {
                resetToggle("实测三乳剂亚层", value: $model.grainSublayersEnabled,
                            enabled: model.hasPhoto && !model.busy)
                    .onChange(of: model.grainSublayersEnabled) { _ in
                        onRefresh()
                    }
                if model.grainSublayersEnabled {
                    resetToggle("原版 Metal 显影链",
                                value: $model.grainOriginalMetalEnabled,
                                enabled: model.hasPhoto && !model.busy)
                        .onChange(of: model.grainOriginalMetalEnabled) { _ in
                            onRefresh()
                        }
                    if model.grainOriginalMetalEnabled {
                        Text("实测三乳剂 → 离散显影 → 染料云 → 微结构 → 反射滤波")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        resetToggle("SciPy 原版随机序列（实验性，较慢）",
                                    value: $model.grainOriginalSciPyEnabled,
                                    enabled: model.hasPhoto && !model.busy)
                            .onChange(of: model.grainOriginalSciPyEnabled) { _ in
                                onRefresh()
                            }
                        Text(model.grainOriginalSciPyEnabled
                             ? "逐通道全图 Poisson→Binomial，源固定种子；Metal Float32 后处理。大图可能耗时并受内存预算限制。"
                             : "Metal 快速随机颗粒；统计分布一致，但并非 SciPy 原版逐像素随机序列。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Button {
                            model.checkOriginalMetalHardware()
                        } label: {
                            Text("检测本机 Metal 显影内核")
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.busy)
                    }
                    resetToggle("原版离散 Poisson 颗粒",
                                value: $model.grainDiscreteParticlesEnabled,
                                enabled: model.hasPhoto && !model.busy &&
                                         !model.grainOriginalMetalEnabled)
                        .onChange(of: model.grainDiscreteParticlesEnabled) { _ in
                            onRefresh()
                        }
                    Text("原版 3×3 亚层密度 · 独立显影颗粒")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if !model.grainOriginalMetalEnabled {
                        Text(model.grainDiscreteParticlesEnabled
                             ? "Poisson 薄化：小 λ 逆 CDF，大 λ PTRS"
                             : "保留源颗粒方差；Gaussian 快速近似")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                strengthControl("颗粒强度", value: $model.grainAmount,
                                range: 0...2, suffix: "×", resetTo: 1.0)
            }
        }
    }

    // Double-tap the left caption to reset this switch. Toggle itself
    // retains native single-tap action; no drag/tap recognizer is placed
    // over the actual controls (iOS 16.5.1-safe).
    private func resetToggle(_ title: String, value: Binding<Bool>,
                             enabled: Bool, resetTo: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    value.wrappedValue = resetTo
                }
                .accessibilityHint("双击标签恢复该模块默认状态")
            Toggle(title, isOn: value)
                .labelsHidden()
        }
        .disabled(!enabled)
    }

    private func exposureControl(_ title: String, value: Binding<Double>,
                                 enabled: Bool, onCommit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard enabled else { return }
                        value.wrappedValue = 0
                        onCommit()
                    }
                Spacer(minLength: 0)
                Button {
                    guard enabled else { return }
                    value.wrappedValue = 0
                    onCommit()
                } label: {
                    Text(String(format: "%+.2f EV", value.wrappedValue))
                        .font(.caption2).monospacedDigit()
                        .frame(minWidth: 67, minHeight: 30, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel("\(title)，点击数值恢复默认 0 EV")
            }
            Slider(value: value, in: -2...2, step: 0.25,
                   onEditingChanged: { editing in
                if !editing { onCommit() }
            })
            .disabled(!enabled)
        }
    }

    private func morphSlider(_ title: String, value: Binding<Double>,
                             range: ClosedRange<Double>,
                             resetTo: Double = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard model.hasPhoto && !model.busy else { return }
                        value.wrappedValue = resetTo
                        model.queueSpectralPreview()
                    }
                Spacer(minLength: 0)
                Button {
                    guard model.hasPhoto && !model.busy else { return }
                    value.wrappedValue = resetTo
                    model.queueSpectralPreview()
                } label: {
                    Text(String(format: "%.2f", value.wrappedValue))
                        .font(.caption2).monospacedDigit()
                        .frame(minWidth: 59, minHeight: 30, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.hasPhoto || model.busy)
                .accessibilityLabel("\(title)，点击数值恢复默认 \(String(format: "%.2f", resetTo))")
            }
            Slider(value: value, in: range, step: 0.05,
                   onEditingChanged: { editing in
                if !editing { model.queueSpectralPreview() }
            })
            .disabled(!model.hasPhoto || model.busy)
        }
    }

    private func strengthControl(_ title: String, value: Binding<Double>,
                                 range: ClosedRange<Double>, suffix: String,
                                 resetTo: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard model.hasPhoto else { return }
                        value.wrappedValue = resetTo
                        onRefresh()
                    }
                Spacer(minLength: 0)
                Button {
                    guard model.hasPhoto && !model.busy else { return }
                    value.wrappedValue = resetTo
                    onRefresh()
                } label: {
                    Text(String(format: "%.2f", value.wrappedValue) + suffix)
                        .font(.caption2).monospacedDigit()
                        .frame(minWidth: 59, minHeight: 30, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.hasPhoto || model.busy)
                .accessibilityLabel("\(title)，点击数值恢复默认 \(String(format: "%.2f", resetTo))\(suffix)")
            }
            Slider(value: value, in: range, step: 0.25,
                   onEditingChanged: { editing in
                if !editing { onRefresh() }
            })
            .disabled(!model.hasPhoto)
        }
    }

}

/// Continuous UIKit recognition survives SwiftUI view refresh on iOS 16.5.1:
/// .began/.changed hold original; only .ended/.cancelled/.failed restore look.
private struct StableImageHoldRecognizer: UIViewRepresentable {
    @Binding var isHolding: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isHolding: $isHolding)
    }

    func makeUIView(context: Context) -> UIView {
        let overlay = UIView(frame: .zero)
        overlay.backgroundColor = .clear
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.onPress(_:))
        )
        recognizer.minimumPressDuration = 0.12
        recognizer.allowableMovement = 45
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        overlay.addGestureRecognizer(recognizer)
        return overlay
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.isHolding = $isHolding
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isHolding: Binding<Bool>
        init(isHolding: Binding<Bool>) {
            self.isHolding = isHolding
        }
        @objc func onPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                if !isHolding.wrappedValue { isHolding.wrappedValue = true }
            case .ended, .cancelled, .failed:
                if isHolding.wrappedValue { isHolding.wrappedValue = false }
            default:
                break
            }
        }
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}
