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
    let onOpenLUT: () -> Void
    let onOpenCatalog: () -> Void
    let onExport: (ExportResolutionMode) -> Void
    let onSaveToPhotos: (ExportResolutionMode) -> Void
    let onRefresh: () -> Void

    @State private var originalHeld = false
    // Initialize only the photo and toolbar on iOS 16.5.1.
    // The two heavy UIKit picker docks are mounted only after opt-in.
    @State private var controlsVisible = false
    @State private var wheelsCollapsed = false
    @State private var adjustmentCollapsed = false
    @State private var comparisonEnabled = false
    @State private var statusReportPresented = false
    @State private var compareFraction = 0.5
    @State private var photoScale: CGFloat = 1.0

    @State private var wheelOffset = CGSize.zero
    @State private var adjustOffset = CGSize.zero

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
                previewArea(size: available)
                    .frame(width: available.width, height: available.height)
                    .clipped()
            }
            .overlay(alignment: .top) {
                topToolbar
                    .padding(.horizontal, 8)
                    .padding(.top, 7)
            }
            .overlay(alignment: .bottomLeading) {
                if controlsVisible && model.hasPhoto {
                    wheelDock(width: wheelWidth)
                        .offset(
                            x: wheelOffset.width,
                            y: wheelOffset.height
                        )
                        .padding(.leading, 8)
                        .padding(.bottom, 10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if controlsVisible && model.hasPhoto {
                    adjustmentDock(width: adjustWidth, maxHeight: available.height * 0.43)
                        .offset(
                            x: adjustOffset.width,
                            y: adjustOffset.height
                        )
                        .padding(.trailing, 8)
                        .padding(.bottom, 10)
                }
            }
            .overlay(alignment: .topLeading) {
                if controlsVisible && model.hasPhoto {
                    Button {
                        statusReportPresented = true
                    } label: {
                        statusChip
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看完整状态及 Metal 数值诊断报告")
                    .padding(.top, 61)
                    .padding(.horizontal, 9)
                }
            }
            .sheet(isPresented: $statusReportPresented) {
                statusReportSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .background(Color.black.ignoresSafeArea())
            // Avoid reentrant @State changes from derived model.hasPhoto
            // inside AttributeGraph view updates (v1.0 startup regression).
        }
    }

    private func previewImage(_ picture: UIImage?, size: CGSize) -> some View {
        Group {
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(photoScale)
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

    private var topToolbar: some View {
        HStack(spacing: 7) {
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

    private func wheelDock(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .foregroundColor(.secondary)
                Text("胶片 · 相纸")
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer(minLength: 2)
                Button {
                    wheelsCollapsed.toggle()
                } label: {
                    Image(systemName: wheelsCollapsed ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .frame(width: 25, height: 31)
                }
                .accessibilityLabel(wheelsCollapsed ? "展开拨轮" : "收起拨轮")
            }
            .frame(height: 38)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { gesture in
                        wheelOffset = clampedOffset(
                            previous: wheelOffset, translation: gesture.translation,
                            available: UIScreen.main.bounds.size, panelWidth: width,
                            panelHeight: wheelsCollapsed ? 40 : 296, anchor: .left
                        )
                    }
            )

            if !wheelsCollapsed {
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
                    adjustmentCollapsed.toggle()
                } label: {
                    Image(systemName: adjustmentCollapsed ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .frame(width: 25, height: 31)
                }
                .accessibilityLabel(adjustmentCollapsed ? "展开调整" : "收起调整")
            }
            .frame(height: 38)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { gesture in
                        adjustOffset = clampedOffset(
                            previous: adjustOffset, translation: gesture.translation,
                            available: UIScreen.main.bounds.size, panelWidth: width,
                            panelHeight: adjustmentCollapsed ? 40 : maxHeight,
                            anchor: .right
                        )
                    }
            )
            if !adjustmentCollapsed {
                Divider()
                ScrollView {
                    adjustmentControls
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .frame(height: max(170, min(maxHeight, 365)))
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

    private var adjustmentControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            resetToggle("Hanatos 原版 Float64", value: $model.hanatosOriginalPrecisionEnabled,
                        enabled: model.hasPhoto && !model.busy,
                        resetTo: true)
                .onChange(of: model.hanatosOriginalPrecisionEnabled) { _ in
                    model.queueSpectralPreview()
                }
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
            resetToggle("扫描光源 · ACES 色域", value: $model.originalScannerEnabled,
                        enabled: model.hasPhoto && !model.busy)
                .onChange(of: model.originalScannerEnabled) { _ in
                    model.queueSpectralPreview()
                }
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
            resetToggle("扫描锐化 / 微眩光", value: $model.scannerFinishingEnabled,
                        enabled: model.hasPhoto)
                .onChange(of: model.scannerFinishingEnabled) { _ in onRefresh() }
            if model.scannerFinishingEnabled {
                strengthControl("锐化强度",
                                value: $model.scannerSharpenAmount,
                                range: 0...1.5, suffix: "×", resetTo: 0.7)
            }
            Divider()
            if !isReversal {
                resetToggle("原版放大机归一化 / CMY", value: $model.originalPrintOpticsEnabled,
                            enabled: model.hasPhoto && !model.busy)
                    .onChange(of: model.originalPrintOpticsEnabled) { _ in
                        model.queueSpectralPreview()
                    }
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
                    resetToggle("相纸预闪光", value: $model.preflashEnabled,
                                enabled: model.hasPhoto && !model.busy)
                        .onChange(of: model.preflashEnabled) { _ in
                            model.queueSpectralPreview()
                        }
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
                resetToggle("相纸显影曲线 s023", value: $model.printMorphEnabled,
                            enabled: model.hasPhoto && !model.busy)
                    .onChange(of: model.printMorphEnabled) { _ in
                        model.queueSpectralPreview()
                    }
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
            resetToggle("乳剂散射", value: $model.scatterEnabled,
                        enabled: model.hasPhoto)
                .onChange(of: model.scatterEnabled) { _ in onRefresh() }
            resetToggle("背反射光晕", value: $model.halationEnabled,
                        enabled: model.hasPhoto)
                .onChange(of: model.halationEnabled) { _ in onRefresh() }
            if model.halationEnabled {
                strengthControl("光晕倍率", value: $model.halationAmount,
                                range: 0...3, suffix: "×", resetTo: 1.0)
            }
            Divider()
            resetToggle("原版 DIR 空间显影", value: $model.spatialDIREnabled,
                        enabled: model.hasPhoto && !model.busy)
                .onChange(of: model.spatialDIREnabled) { _ in
                    model.queueSpectralPreview()
                }
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
                        Text("实算 Hanatos→胶片 H-D→空间 DIR FIR/YVV→" +
                             "相纸 H-D→光谱扫描；不经过颜色 3D LUT。" +
                             "实验上限提高到 1200 万像素；实际是否允许导出，" +
                             "按这台手机当前物理内存和 App 可用余量逐次检查。" +
                             "整图 Double FIR/YVV 与相纸显影均保留，不缩图；" +
                             "需开启原版 ACES 扫描、Hanatos Float64、" +
                             "负片原版放大机，关闭 CAM16/黑白参考。" +
                             "尚不支持随机颗粒、光晕与 RAW。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("仅不透明 8-bit 照片：ImageIO→Double DIR→原尺寸 JPEG；" +
                         "不支持颗粒、光晕、散射和扫描后处理；不静默降级。")
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
            resetToggle("密度颗粒", value: $model.grainEnabled,
                        enabled: model.hasPhoto && !model.busy)
                .onChange(of: model.grainEnabled) { enabled in
                    if enabled { model.queueSpectralPreview() }
                    else { onRefresh() }
                }
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

            Button {
                model.applyMeasuredSimulation()
            } label: {
                Text("应用模拟")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasPhoto || model.busy)

            if model.busy {
                ProgressView("计算中").font(.caption2)
            } else {
                Text("拨轮停止后自动计算")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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

    private enum DockAnchor { case left, right }

    private func clampedOffset(previous: CGSize, translation: CGSize,
                               available: CGSize, panelWidth: CGFloat,
                               panelHeight: CGFloat, anchor: DockAnchor) -> CGSize {
        let x = previous.width + translation.width
        let y = previous.height + translation.height
        let horizontal = max(0, available.width - panelWidth - 16)
        let vertical = min(0, -available.height + panelHeight + 85)
        return CGSize(
            width: anchor == .left ? min(horizontal, max(0, x))
                 : min(0, max(-horizontal, x)),
            height: min(0, max(vertical, y))
        )
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
