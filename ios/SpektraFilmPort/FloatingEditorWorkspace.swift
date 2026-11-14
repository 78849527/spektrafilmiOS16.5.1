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
    // iOS 16.5.1: split opening into a light shell, control rows,
    // then the current parameter page to avoid a full AttributeGraph
    // replacement during the same edge-button tap transaction.
    @State private var adjustmentRowsReady = false
    @State private var adjustmentDetailReady = false
    // Last opened panel always overlays the older panel.
    @State private var frontDrawer: DrawerSide = .film
    @State private var selectedFeature: AdjustmentFeature? = .basic
    // Confirm before changing any OTHER user-selected settings.
    @State private var pendingSourceMode: SourceModeChange?
    @State private var comparisonEnabled = false
    @State private var statusReportPresented = false
    @State private var compareFraction = 0.5
    @State private var photoScale: CGFloat = 1.0

    private enum DrawerSide { case film, adjustment }
    private enum AdjustmentFeature: String {
        case basic = "基础"
        case scanner = "扫描"
        case sharpening = "锐化"
        case enlarger = "放大机"
        case preflash = "预闪"
        case morphology = "s023"
        case halation = "光晕"
        case dir = "DIR"
        case grain = "颗粒"
    }

    // These hard requirements are confirmed by the current source
    // processor validators, not inferred temporary UI restrictions.
    private enum SourceModeChange: String, Identifiable {
        case pixel, physical, disablePixel, disablePhysical
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pixel: return "开启 8-bit 原版像素直连"
            case .physical: return "开启逐像素全光学"
            case .disablePixel: return "关闭像素直连并退出关联模式？"
            case .disablePhysical: return "退出逐像素全光学？"
            }
        }
    }

    private var directPixelMode: Bool { model.sourcePixelIOEnabled }
    private var fullPhysicalMode: Bool {
        model.sourcePixelIOEnabled && model.sourcePhysicalDirectEnabled
    }

    private func confirmedFeatureLock(_ feature: AdjustmentFeature) -> String? {
        if fullPhysicalMode {
            switch feature {
            case .scanner:
                return "全光学依赖原版扫描；请先关闭逐像素全光学"
            case .enlarger where !isReversal:
                return "负片全光学依赖原版放大机；请先关闭逐像素全光学"
            case .dir:
                return "像素直连依赖 DIR；请先关闭像素直连"
            default: break
            }
        }
        if directPixelMode {
            switch feature {
            case .sharpening, .grain:
                return "原版像素直连不支持旧版扫描锐化或随机颗粒"
            case .halation where !fullPhysicalMode:
                return "普通像素直连不支持旧版光晕；需先进入逐像素全光学"
            case .dir:
                return "原版像素直连依赖 DIR；请先关闭像素直连"
            default: break
            }
        }
        return nil
    }

    private func confirmedSimpleLock(_ title: String) -> String? {
        if fullPhysicalMode {
            switch title {
            case "64位":
                return "逐像素全光学要求 Hanatos Float64"
            case "CAM16", "曝光参考":
                return "原版全光学扫描不支持 CAM16、黑白参考及曝光参考"
            default: break
            }
        }
        if directPixelMode && !fullPhysicalMode && title == "散射" {
            return "普通像素直连不支持散射；请先开启逐像素全光学"
        }
        return nil
    }

    private func requiredChanges(for mode: SourceModeChange) -> [String] {
        var changes: [String] = []
        if mode == .disablePixel {
            if model.sourcePhysicalDirectEnabled {
                changes.append("同步关闭依赖像素直连的逐像素全光学")
            }
            return changes
        }
        if mode == .disablePhysical {
            if model.scatterEnabled {
                changes.append("关闭普通像素直连不支持的乳剂散射")
            }
            if model.halationEnabled {
                changes.append("关闭普通像素直连不支持的背反射光晕")
            }
            return changes
        }
        if abs(model.strength - 1.0) > 1e-9 {
            changes.append("效果强度恢复为 100%")
        }
        if model.grainEnabled { changes.append("关闭随机密度颗粒") }
        if model.scannerFinishingEnabled { changes.append("关闭旧版扫描锐化") }
        if mode == .pixel {
            if model.scatterEnabled { changes.append("关闭旧版散射") }
            if model.halationEnabled { changes.append("关闭旧版背反射光晕") }
        } else {
            if !model.hanatosOriginalPrecisionEnabled { changes.append("启用 Hanatos Float64") }
            if !model.originalScannerEnabled { changes.append("启用原版 ACES 扫描") }
            if !isReversal && !model.originalPrintOpticsEnabled {
                changes.append("启用原版放大机")
            }
            if model.scannerCAM16Enabled { changes.append("关闭 CAM16") }
            if model.scannerBlackWhiteEnabled { changes.append("关闭黑白场校准") }
            if model.exposureReferenceEnabled { changes.append("关闭曝光参考") }
        }
        return changes
    }

    private func requestSourceMode(_ mode: SourceModeChange) {
        guard model.hasPhoto && !model.busy else { return }
        if mode == .pixel && model.sourcePixelIOEnabled {
            requestSourceMode(.disablePixel)
            return
        }
        if mode == .physical && model.sourcePhysicalDirectEnabled {
            requestSourceMode(.disablePhysical)
            return
        }
        if mode == .disablePixel || mode == .disablePhysical {
            if requiredChanges(for: mode).isEmpty {
                commitSourceMode(mode)
            } else {
                pendingSourceMode = mode
            }
            return
        }
        // The old SourcePixelIO validator requires the original DIR
        // source convolution and a selected film/paper LUT. These
        // prerequisites are not silently fabricated by the UI.
        guard model.spatialDIREnabled,
              model.spatialDIRSourceConvolutionEnabled,
              model.lut != nil else { return }
        if mode == .physical && !model.sourcePixelIOEnabled { return }
        if requiredChanges(for: mode).isEmpty {
            commitSourceMode(mode)
        } else {
            pendingSourceMode = mode
        }
    }

    private func commitSourceMode(_ mode: SourceModeChange) {
        // Called only after confirmation of the affected settings.
        if mode == .disablePixel {
            model.sourcePixelIOEnabled = false
            model.sourcePhysicalDirectEnabled = false
            model.queueSpectralPreview()
            return
        }
        if mode == .disablePhysical {
            model.sourcePhysicalDirectEnabled = false
            // Ordinary 8-bit direct DIR rejects these old CI effects.
            model.scatterEnabled = false
            model.halationEnabled = false
            model.queueSpectralPreview()
            return
        }
        model.strength = 1.0
        model.grainEnabled = false
        model.scannerFinishingEnabled = false
        if mode == .pixel {
            model.scatterEnabled = false
            model.halationEnabled = false
            model.sourcePixelIOEnabled = true
            model.sourcePhysicalDirectEnabled = false
        } else {
            model.hanatosOriginalPrecisionEnabled = true
            model.originalScannerEnabled = true
            if !isReversal { model.originalPrintOpticsEnabled = true }
            model.scannerCAM16Enabled = false
            model.scannerBlackWhiteEnabled = false
            model.exposureReferenceEnabled = false
            model.sourcePixelIOEnabled = true
            model.sourcePhysicalDirectEnabled = true
        }
        selectedFeature = .dir
        model.queueSpectralPreview()
    }

    private func sourceModeControl(_ title: String,
                                   mode: SourceModeChange) -> some View {
        let isOn = mode == .pixel
            ? model.sourcePixelIOEnabled : model.sourcePhysicalDirectEnabled
        let prerequisite = model.spatialDIREnabled &&
            model.spatialDIRSourceConvolutionEnabled &&
            model.lut != nil && (mode == .pixel || model.sourcePixelIOEnabled)
        return HStack(spacing: 7) {
            Text(title)
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                requestSourceMode(mode)
            } label: {
                miniatureSwitch(isOn: isOn)
                    .frame(width: 42, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy || (!isOn && (!prerequisite || !model.hasPhoto)))
            .accessibilityLabel(title + (isOn ? "，关闭" : "，开启"))
            .accessibilityHint("若需改变其他已开启选项，会先列明并要求确认")
        }
        .opacity(!isOn && !prerequisite ? 0.45 : 1)
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
        guard !adjustmentExpanded else {
            frontDrawer = .adjustment
            return
        }
        // Do not animate replacement of a large SwiftUI view hierarchy.
        // It used to be inserted in the same transaction as both @State
        // mutations; user reported a real-device crash on opening.
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            adjustmentRowsReady = false
            adjustmentDetailReady = false
            frontDrawer = .adjustment
            adjustmentExpanded = true
        }
        // Each stage is scheduled only while the drawer is still open,
        // so closing quickly cannot mount a detached control tree.
        DispatchQueue.main.async {
            guard adjustmentExpanded else { return }
            adjustmentRowsReady = true
            DispatchQueue.main.async {
                guard adjustmentExpanded && adjustmentRowsReady else { return }
                adjustmentDetailReady = true
            }
        }
    }
    private func closeAdjustmentDrawer() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            adjustmentDetailReady = false
            adjustmentRowsReady = false
            adjustmentExpanded = false
        }
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
                }
            }
            .sheet(isPresented: $statusReportPresented) {
                statusReportSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert(item: $pendingSourceMode) { mode in
                Alert(
                    title: Text(mode.title),
                    message: Text(
                        "原版算法已确认需要调整以下设置：\n" +
                        requiredChanges(for: mode).joined(separator: "；") +
                        "\n\n确认后才会关闭冲突项。不会自动切换近似算法。"
                    ),
                    primaryButton: .default(Text("确认并切换")) {
                        commitSourceMode(mode)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
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

    /// An always-touchable edge button expands each snapped drawer.
    /// No drawer swipe/drag gesture: avoids conflicts with the long-hold
    /// original preview, film/paper wheels, and iOS 16.5.1 cold start.
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
            ? "点击展开左侧胶片相纸拨轮"
            : "点击展开右侧全屏宽度调节面板")
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
            if adjustmentExpanded {
                Divider()
                if adjustmentRowsReady {
                    adjustmentControls
                        .frame(height: maxHeight)
                } else {
                    Color.clear
                        .frame(height: maxHeight)
                        .accessibilityHidden(true)
                }
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

    // First row: only features with parameter panels. Basic is a
    // direct editor, not a master switch. Tapping a disabled feature
    // activates it AND opens its own parameters below; tapping its
    // label again selects it without disabling. The tiny dedicated
    // switch turns it OFF and removes its parameters immediately.
    private var featureRow: AnyView {
        AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 5) {
                Button { selectedFeature = .basic } label: {
                    Text("基础")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 29)
                        .foregroundColor(selectedFeature == .basic ? .accentColor : .primary)
                        .background(
                            selectedFeature == .basic
                                ? Color.accentColor.opacity(0.15)
                                : Color.primary.opacity(0.07),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!model.hasPhoto || model.busy)
                .accessibilityLabel("基础，点按显示曝光与效果强度")

                featureToggle("扫描", feature: .scanner,
                              value: $model.originalScannerEnabled) {
                    model.queueSpectralPreview()
                }
                featureToggle("锐化", feature: .sharpening,
                              value: $model.scannerFinishingEnabled) {
                    onRefresh()
                }
                featureToggle("放大机", feature: .enlarger,
                              value: $model.originalPrintOpticsEnabled,
                              allowed: !isReversal) {
                    model.queueSpectralPreview()
                }
                featureToggle("预闪", feature: .preflash,
                              value: $model.preflashEnabled,
                              allowed: !isReversal && model.originalPrintOpticsEnabled) {
                    model.queueSpectralPreview()
                }
                featureToggle("s023", feature: .morphology,
                              value: $model.printMorphEnabled,
                              allowed: !isReversal) {
                    model.queueSpectralPreview()
                }
                featureToggle("光晕", feature: .halation,
                              value: $model.halationEnabled) {
                    onRefresh()
                }
                featureToggle("DIR", feature: .dir,
                              value: $model.spatialDIREnabled) {
                    model.queueSpectralPreview()
                }
                featureToggle("颗粒", feature: .grain,
                              value: $model.grainEnabled) {
                    if model.grainEnabled { model.queueSpectralPreview() }
                    else { onRefresh() }
                }
            }
            .padding(.horizontal, 6)
        }
            .frame(height: 34)
        )
    }

    private func featureToggle(_ title: String, feature: AdjustmentFeature,
                               value: Binding<Bool>, allowed: Bool = true,
                               changed: @escaping () -> Void) -> some View {
        let ready = model.hasPhoto && !model.busy && allowed
        let confirmedLock = confirmedFeatureLock(feature)
        return HStack(spacing: 2) {
            Button {
                guard ready else { return }
                if !value.wrappedValue {
                    guard confirmedLock == nil else { return }
                    value.wrappedValue = true
                    changed()
                }
                selectedFeature = feature
            } label: {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title + "，开启并显示二级参数")
            .accessibilityHint(confirmedLock ?? "点击功能名称查看二级菜单")
            .disabled(!ready || (!value.wrappedValue && confirmedLock != nil))
            Button {
                guard ready && confirmedLock == nil else { return }
                let next = !value.wrappedValue
                value.wrappedValue = next
                if next {
                    selectedFeature = feature
                } else if selectedFeature == feature {
                    selectedFeature = nil
                }
                changed()
            } label: {
                miniatureSwitch(isOn: value.wrappedValue)
                    .frame(width: 34, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title + (value.wrappedValue
                                        ? "，关闭并收起参数" : "，开启并展开参数"))
            .accessibilityHint(confirmedLock ?? "原版算法可用")
            .disabled(!ready || confirmedLock != nil)
            .opacity(confirmedLock == nil ? 1 : 0.45)
        }
        .foregroundColor(selectedFeature == feature && value.wrappedValue
                         ? .accentColor : .primary)
        .background(selectedFeature == feature && value.wrappedValue
                    ? Color.accentColor.opacity(0.15)
                    : Color.primary.opacity(0.07), in: Capsule())
        .disabled(!ready)
    }

    // Second row: ONLY independent on/off functions with no
    // parameter page. Advanced child switches remain inside their
    // parent's detailed page to preserve the original dependencies.
    private var simpleSwitchRow: AnyView {
        AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 5) {
                simpleToggle("64位", value: $model.hanatosOriginalPrecisionEnabled) {
                    model.queueSpectralPreview()
                }
                simpleToggle("散射", value: $model.scatterEnabled) {
                    onRefresh()
                }
                if model.originalScannerEnabled {
                    simpleToggle("CAM16", value: $model.scannerCAM16Enabled) {
                        model.queueSpectralPreview()
                    }
                    if model.scannerBlackWhiteEnabled && !isReversal {
                        simpleToggle("曝光参考", value: $model.exposureReferenceEnabled) {
                            model.queueSpectralPreview()
                        }
                    }
                }
                if model.originalPrintOpticsEnabled && !isReversal {
                    simpleToggle("归一化", value: $model.normalizePrintExposure,
                                 resetTo: true) {
                        model.queueSpectralPreview()
                    }
                    simpleToggle("曝光补偿", value: $model.printExposureCompensation,
                                 resetTo: true) {
                        model.queueSpectralPreview()
                    }
                }
                if model.grainEnabled && model.grainSublayersEnabled {
                    if model.grainOriginalMetalEnabled {
                        simpleToggle("SciPy", value: $model.grainOriginalSciPyEnabled) {
                            onRefresh()
                        }
                    }
                    simpleToggle("Poisson", value: $model.grainDiscreteParticlesEnabled,
                                 allowed: !model.grainOriginalMetalEnabled) {
                        onRefresh()
                    }
                }
            }
            .padding(.horizontal, 6)
        }
            .frame(height: 34)
        )
    }

    private func miniatureSwitch(isOn: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.gray.opacity(0.46))
                .frame(width: 28, height: 16)
            Circle()
                .fill(.white)
                .frame(width: 12, height: 12)
                .offset(x: isOn ? 6 : -6)
        }
    }

    private func simpleToggle(_ title: String, value: Binding<Bool>,
                              allowed: Bool = true, resetTo: Bool = false,
                              changed: @escaping () -> Void) -> some View {
        let confirmedLock = confirmedSimpleLock(title)
        return Button {
            guard model.hasPhoto && !model.busy && allowed && confirmedLock == nil else { return }
            value.wrappedValue.toggle()
            changed()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                miniatureSwitch(isOn: value.wrappedValue)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .onTapGesture(count: 2) {
            guard model.hasPhoto && !model.busy && allowed && confirmedLock == nil else { return }
            value.wrappedValue = resetTo
            changed()
        }
        .disabled(!model.hasPhoto || model.busy || !allowed || confirmedLock != nil)
        .opacity(confirmedLock == nil ? 1 : 0.45)
        .accessibilityLabel(title + (value.wrappedValue ? "，已开启" : "，已关闭"))
        .accessibilityHint(confirmedLock ?? "单击切换；双击恢复默认")
    }

    // Top feature row and pure-switch second row. The parameter
    // region below exists only for an enabled selected feature.
    // Incident CF7DCF7C-9351-46BA-8B3D-8A712A99DC15, iOS 16.5.1:
    // The .ips traces 40+ recursive Swift generic metadata demangle frames
    // to adjustmentControls.getter, followed by STACK GUARD SIGSEGV.
    // Avoid a giant nested SwiftUI opaque type; each child is explicitly
    // type-erased BEFORE composing it with parent views.
    private var adjustmentControls: AnyView {
        AnyView(
            VStack(spacing: 3) {
                featureRow
                simpleSwitchRow
                Divider().padding(.horizontal, 8)
                adjustmentDetailContent
            }
        )
    }

    private var adjustmentDetailContent: AnyView {
        guard adjustmentDetailReady else {
            return AnyView(
                Color.clear
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            )
        }
        return AnyView(
            ScrollView(.vertical) {
                activeSettings
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        )
    }

    // Do NOT use @ViewBuilder with a 9-case generic ConditionalContent tree.
    // Explicit AnyView at this dispatch boundary prevents eager metadata
    // reconstruction of all nine complex parameter pages on drawer open.
    private var activeSettings: AnyView {
        guard let selectedFeature else { return AnyView(EmptyView()) }
        switch selectedFeature {
        case .basic:
            return AnyView(exposureSettings)
        case .scanner:
            return model.originalScannerEnabled
                ? AnyView(scannerSettings) : AnyView(EmptyView())
        case .sharpening:
            return model.scannerFinishingEnabled
                ? AnyView(sharpeningSettings) : AnyView(EmptyView())
        case .enlarger:
            return model.originalPrintOpticsEnabled && !isReversal
                ? AnyView(enlargerSettings) : AnyView(EmptyView())
        case .preflash:
            return model.preflashEnabled &&
                   model.originalPrintOpticsEnabled && !isReversal
                ? AnyView(preflashSettings) : AnyView(EmptyView())
        case .morphology:
            return model.printMorphEnabled && !isReversal
                ? AnyView(morphologySettings) : AnyView(EmptyView())
        case .halation:
            return model.halationEnabled
                ? AnyView(halationSettings) : AnyView(EmptyView())
        case .dir:
            return model.spatialDIREnabled
                ? AnyView(dirSettings) : AnyView(EmptyView())
        case .grain:
            return model.grainEnabled
                ? AnyView(grainSettings) : AnyView(EmptyView())
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
                Text(model.scannerCAM16Enabled
                     ? "默认色域 · CAM16 查表插值"
                     : "可选色域 · ACES RGC")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                resetToggle("黑白场校准", value: $model.scannerBlackWhiteEnabled,
                            enabled: model.hasPhoto && !model.busy && !fullPhysicalMode)
                    .onChange(of: model.scannerBlackWhiteEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                if model.scannerBlackWhiteEnabled && !isReversal {
                    Text(model.exposureReferenceEnabled
                         ? "胶片两端 → 印相显影 → 曝光补偿"
                         : "使用旧版密度端点近似")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var sharpeningSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.scannerFinishingEnabled {
                strengthControl("锐化强度",
                                value: $model.scannerSharpenAmount,
                                range: 0...1.5, suffix: "×", resetTo: 0.7)
            }
        }
    }

    private var enlargerSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.originalPrintOpticsEnabled && !isReversal {
                Text("胶片 → 二色滤色光谱 → 相纸曝光")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                morphSlider("青色 C / CC", value: $model.printCyanShift,
                            range: -40...40)
                morphSlider("洋红 M / CC", value: $model.printMagentaShift,
                            range: -40...40)
                morphSlider("黄色 Y / CC", value: $model.printYellowShift,
                            range: -40...40)
            }
        }
    }

    private var preflashSettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.preflashEnabled && model.originalPrintOpticsEnabled && !isReversal {
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
    }

    private var morphologySettings: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.printMorphEnabled && !isReversal {
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

    private var halationSettings: some View {
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
                            enabled: model.hasPhoto && !model.busy && !directPixelMode,
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
                    sourceModeControl("8-bit 原版像素直连（实验）", mode: .pixel)
                    if model.sourcePixelIOEnabled {
                        sourceModeControl("逐像素全光学（实验）", mode: .physical)
                        if model.sourcePhysicalDirectEnabled {
                            // Explicit type-erasure boundary: this optional
                            // source spectroscopy panel must NOT reintroduce
                            // v1.8.36 Swift runtime generic stack overflow.
                            sourceCameraSpectralSettings
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

    /// Upstream CameraParams.filter_uv / filter_ir and
    /// SettingsParams.rgb_to_raw_method. The full-physical source stage
    /// consumes the same data; no mobile LUT approximation.
    /// Keep this heavy view erased at a separate boundary on iOS 16.
    private var sourceCameraSpectralSettings: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Picker("相机原版光谱重建", selection: $model.sourceCameraRawMethod) {
                    if !model.sourceCameraUVEnabled &&
                       !model.sourceCameraIREnabled {
                        Text("Hanatos 2025（默认）")
                            .tag(SpectralPhysics.CameraRawMethod.hanatos2025)
                    }
                    Text("Mallett 2019（81 波长积分）")
                        .tag(SpectralPhysics.CameraRawMethod.mallett2019)
                }
                .pickerStyle(.menu)
                .onChange(of: model.sourceCameraRawMethod) { _ in
                    model.queueSpectralPreview()
                }
                Text("Python 原版的两条光谱重建路径。UV/IR 滤镜只在" +
                     " Mallett 2019 精确重算感光度时开放；Hanatos TC LUT" +
                     " 尚不能带着滤镜直接复用。不会忽略或模拟滤镜。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if model.sourceCameraRawMethod == .mallett2019 {
                    resetToggle("相机 UV 光谱截止", value: $model.sourceCameraUVEnabled,
                                enabled: model.hasPhoto && !model.busy,
                                resetTo: false)
                        .onChange(of: model.sourceCameraUVEnabled) { _ in
                            model.queueSpectralPreview()
                        }
                    if model.sourceCameraUVEnabled {
                        morphSlider("UV 截止强度",
                                    value:$model.sourceCameraUVAmount,
                                    range:0...1,resetTo:1)
                        morphSlider("UV 截止波长 nm",
                                    value:$model.sourceCameraUVCutoffNM,
                                    range:380...780,resetTo:410)
                        morphSlider("UV 过渡宽度 nm",
                                    value:$model.sourceCameraUVWidthNM,
                                    range:0.1...100,resetTo:8)
                    }
                    resetToggle("相机 IR 光谱截止", value: $model.sourceCameraIREnabled,
                                enabled: model.hasPhoto && !model.busy,
                                resetTo: false)
                        .onChange(of: model.sourceCameraIREnabled) { _ in
                            model.queueSpectralPreview()
                        }
                    if model.sourceCameraIREnabled {
                        morphSlider("IR 截止强度",
                                    value:$model.sourceCameraIRAmount,
                                    range:0...1,resetTo:1)
                        morphSlider("IR 截止波长 nm",
                                    value:$model.sourceCameraIRCutoffNM,
                                    range:380...780,resetTo:675)
                        morphSlider("IR 过渡宽度 nm",
                                    value:$model.sourceCameraIRWidthNM,
                                    range:0.1...100,resetTo:15)
                    }
                }
            }
            .padding(.vertical, 4)
        )
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
