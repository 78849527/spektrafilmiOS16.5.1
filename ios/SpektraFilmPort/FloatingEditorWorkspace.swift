import PhotosUI
import SwiftUI
import UIKit

/// iOS 16.5.1 portrait editor: the photograph stays permanently mounted.
/// Film/paper and continuous adjustments share ONE bottom sheet, switched
/// by top text tabs; materials are horizontally scrollable, not side docks.
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
    let onOpenRecipes: () -> Void
    let onExport: (ExportResolutionMode) -> Void
    /// Build96: separate actual 16-bit TIFF share destination; Photos stay JPEG.
    let onExportTIFF16: (ExportResolutionMode) -> Void
    let onSaveToPhotos: (ExportResolutionMode) -> Void
    let onRefresh: () -> Void
    let onShareBuild100Readiness: () -> Void
    let onRunBuild101DeviceParity: () -> Void
    let onRunBuild103Metrics: () -> Void
    let onRunBuild104Grain: () -> Void
    let onRunBuild107CombinedFeedback: () -> Void
    let onRunBuild108FullFrameFeedback: () -> Void
    let onRunBuild110GamutEvidence: () -> Void
    let onRunBuild114FourGates: () -> Void
    let onRunBuild115ParallelGrain: () -> Void
    let onRunBuild116GrainMemory: () -> Void
    let onRunBuild118LargeMemory: (Int) -> Void
    let onDiagnosticSheetDismissed: () -> Void
    let onCaptureBuild77Evidence: () -> Void

    @State private var originalHeld = false
    // Only the photo and toolbar mount initially on iOS 16.5.1.
    // A single lower editor is mounted by the explicit "调整" button.
    @State private var controlsVisible = false
    @State private var unifiedEditorExpanded = false
    @State private var selectedEditorPage: EditorPage = .adjustment
    @State private var selectedDailyCategory: DailyCategory = .light
    @State private var selectedProcessStage: ProcessStage = .film
    // Preserve the proven staged mounting for the heavy adjustment tree:
    // SwiftUI iOS 16.5.1 crashed when all pages mounted in one transaction.
    @State private var adjustmentRowsReady = false
    @State private var adjustmentDetailReady = false
    @State private var selectedFeature: AdjustmentFeature? = .basic
    // Confirm before changing any OTHER user-selected settings.
    @State private var pendingSourceMode: SourceModeChange?
    @State private var sourceInputCompatibilityAlert=false
    // Build121: diagnostic copy is transient UI state, never a new optical
    // preference or a way to bypass the existing production dependencies.
    @State private var switchExplanation:SwitchExplanation?
    @State private var precisionEdit:PrecisionRequest?
    // The fast/editor configuration is saved only when first entering a
    // source-pixel mode. Leaving that mode restores the exact user values,
    // not a hardcoded default set. Never persist a snapshot across images.
    @State private var savedFastSettings: FastSettingsSnapshot?
    @State private var comparisonEnabled = false
    @State private var statusReportPresented = false
    @State private var compareFraction = 0.5
    @State private var photoScale: CGFloat = 1.0
    // Build127: material browsing state never alters optical settings.
    // IDs only, no cached photos/processed images.
    @AppStorage("sf.build127.filmFavorites") private var favoriteFilmIDsStored=""
    @AppStorage("sf.build127.recentFilms") private var recentFilmIDsStored=""
    @State private var recipeApplyError:String?

    // View-only grouping: changing a page does not change source algorithms.
    private enum EditorPage: String {
        case film = "胶片与配方"
        case adjustment = "调整"
        case workflow = "工艺"
        case laboratory = "实验室"
    }
    private enum DailyCategory: String, CaseIterable {
        case light = "光线"
        case color = "色彩"
        case texture = "质感"
        case detail = "细节"
    }
    private enum ProcessStage: String, CaseIterable {
        case camera = "拍摄"
        case film = "胶片"
        case paper = "相纸"
        case scanner = "扫描"
    }
    // Build112 purely presents the EXISTING two independent source switches.
    // No added saved mode, optical model, default, or alternate renderer.
    private enum SourceColorRoute {
        case classic, oklch, cam16, both
        var label:String {
            switch self {
            case .classic: return "经典 xy / ACES"
            case .oklch: return "Oklch 输入"
            case .cam16: return "CAM16-UCS 输出"
            case .both: return "Oklch + CAM16"
            }
        }
        var usesOklch:Bool { self == .oklch || self == .both }
        var usesCAM16:Bool { self == .cam16 || self == .both }
    }
    private enum AdjustmentFeature: String {
        case basic = "基础"
        case scanner = "扫描"
        case sharpening = "锐化"
        case enlarger = "放大机"
        case preflash = "预闪"
        case morphology = "s023"
        case halation = "光晕"
        case dir = "DIR"
        case cameraDiffusion = "摄影扩散"
        case printDiffusion = "印相扩散"
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

    @MainActor
    private struct FastSettingsSnapshot {
        let strength: Double
        let grain: Bool
        let scannerFinishing: Bool
        let scatter: Bool
        let halation: Bool
        let dir: Bool
        let sourceConvolution: Bool
        let hanatosDouble: Bool
        let sourceScanner: Bool
        let printOptics: Bool
        let cam16: Bool
        let blackWhite: Bool
        let exposureReference: Bool

        init(_ model: PhotoEditorModel) {
            strength=model.strength
            grain=model.grainEnabled
            scannerFinishing=model.scannerFinishingEnabled
            scatter=model.scatterEnabled
            halation=model.halationEnabled
            dir=model.spatialDIREnabled
            sourceConvolution=model.spatialDIRSourceConvolutionEnabled
            hanatosDouble=model.hanatosOriginalPrecisionEnabled
            sourceScanner=model.originalScannerEnabled
            printOptics=model.originalPrintOpticsEnabled
            cam16=model.scannerCAM16Enabled
            blackWhite=model.scannerBlackWhiteEnabled
            exposureReference=model.exposureReferenceEnabled
        }
        func restore(_ model: PhotoEditorModel) {
            model.strength=strength
            model.grainEnabled=grain
            model.scannerFinishingEnabled=scannerFinishing
            model.scatterEnabled=scatter
            model.halationEnabled=halation
            model.spatialDIREnabled=dir
            model.spatialDIRSourceConvolutionEnabled=sourceConvolution
            model.hanatosOriginalPrecisionEnabled=hanatosDouble
            model.originalScannerEnabled=sourceScanner
            model.originalPrintOpticsEnabled=printOptics
            model.scannerCAM16Enabled=cam16
            model.scannerBlackWhiteEnabled=blackWhite
            model.exposureReferenceEnabled=exposureReference
        }
    }

    /// Build122: numeric editing is transient UI state; the model receives
    /// a single validated Double on Confirm, not one optical render per key.
    private struct PrecisionRequest:Identifiable {
        let id=UUID()
        let title:String
        let current:Double
        let range:ClosedRange<Double>
        let increment:Double
        let resetTo:Double
        let unit:String
        let apply:(Double)->Void
    }

    private struct PrecisionEntrySheet:View {
        let request:PrecisionRequest
        @Environment(\.dismiss) private var dismiss
        @State private var input:String
        @State private var error:String?
        init(request:PrecisionRequest) {
            self.request=request
            _input=State(initialValue:String(request.current))
        }
        private var parsed:Double? {
            Double(input.trimmingCharacters(in:.whitespacesAndNewlines)
                .replacingOccurrences(of:"，",with:".")
                .replacingOccurrences(of:",",with:"."))
        }
        private var valid:Bool {
            guard let n=parsed else{return false}
            return n.isFinite && request.range.contains(n)
        }
        private func nudge(_ delta:Double) {
            let value=min(request.range.upperBound,
                max(request.range.lowerBound,
                    (parsed ?? request.current)+delta))
            input=String(value)
            error=nil
        }
        var body:some View {
            VStack(alignment:.leading,spacing:10) {
                Text(request.title).font(.headline)
                Text("允许范围：\(request.range.lowerBound) ～ \(request.range.upperBound) \(request.unit)。支持直接输入小数；只在确认后更新渲染。")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing:10) {
                    Button("−") {nudge(-request.increment)}
                        .font(.title2).frame(width:42,height:42)
                    TextField("输入数值",text:$input)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.center)
                        .font(.system(.body,design:.monospaced))
                        .accessibilityLabel("输入"+request.title+"的精确数值")
                    Button("+") {nudge(request.increment)}
                        .font(.title2).frame(width:42,height:42)
                }
                if let error {
                    Text(error).font(.caption).foregroundColor(.red)
                }
                HStack {
                    Button("恢复默认") {
                        input=String(request.resetTo)
                        error=nil
                    }
                    Spacer()
                    Button("取消") {dismiss()}
                    Button("确认") {
                        guard valid,let value=parsed else {
                            error="数值无效或超过参数范围；未修改照片"
                            return
                        }
                        request.apply(value)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid)
                }
            }
            .padding(18)
            .presentationDetents([.height(258)])
            .presentationDragIndicator(.visible)
        }
    }

    private func presentPrecision(
        title:String,value:Binding<Double>,range:ClosedRange<Double>,
        increment:Double,resetTo:Double,unit:String="",
        onCommit:@escaping()->Void
    ) {
        guard model.hasPhoto && !model.busy else{return}
        precisionEdit=PrecisionRequest(
            title:title,current:value.wrappedValue,range:range,
            increment:increment,resetTo:resetTo,unit:unit,
            apply:{ exact in
                guard model.hasPhoto && !model.busy else {return}
                value.wrappedValue=exact
                onCommit()
            }
        )
    }

    private struct SwitchExplanation:Identifiable {
        let id=UUID()
        let title:String
        let summary:String
        let details:String
    }

    private struct SwitchGuidance {
        let summary:String
        let details:String
    }

    /// Human readable reasons for EXACT existing lock conditions. The
    /// renderer, resetToggle .disabled guard and mode confirmation stay
    /// unchanged. This mapping must never write model properties.
    private func lockedSwitchReason(_ title:String)->String {
        if !model.hasPhoto {
            return "尚未导入照片。先从相册或文件打开一张图片。"
        }
        if model.busy {
            return "正在计算或导出照片。处理结束后即可再次操作。"
        }
        switch title {
        case "胶片层间扩散", "DIR 原版 FIR/YVV":
            if directPixelMode {
                return "原版像素直连依赖 DIR，不能单独关闭。先在「工艺」退出像素直连或精细冲印。"
            }
        case "背反射光晕":
            if directPixelMode && !fullPhysicalMode {
                return "8-bit 原版 DIR 像素直连不支持旧版背反射光晕。切回快速冲印，或进入精细冲印使用原版散射。"
            }
        case "胶片颗粒", "快速胶片颗粒", "颗粒":
            if directPixelMode {
                return "原版像素路径不运行旧版快速随机颗粒。请在「工艺 → 胶片」开启「原版三亚层颗粒」，或退出原版像素路径。"
            }
        case "摄影柔化":
            if !fullPhysicalMode {
                return "摄影柔化仅属于精细冲印。先在「工艺」选择精细冲印。"
            }
            if !model.sourceCameraPreFilmEnabled {
                return "需要先在「工艺 → 拍摄」开启「测光与镜头处理」，才能开启摄影柔化。"
            }
        case "相纸显影曲线 s023":
            if fullPhysicalMode || directPixelMode {
                return "当前原版像素路线不允许独立切换旧版 s023 开关。退出精细冲印并切回快速冲印后可调整。"
            }
        case "光学放大机":
            if fullPhysicalMode {
                return "彩色负片的精细冲印依赖原版放大机，当前已开启且锁定。先退出精细冲印才能关闭。"
            }
        case "光谱扫描":
            if fullPhysicalMode {
                return "精细冲印依赖原版光谱扫描，当前已开启且锁定。先退出精细冲印才能关闭。"
            }
        case "扫描锐化":
            if directPixelMode {
                return "原版像素处理不支持旧版快速扫描锐化。可进入「工艺 → 扫描」开启「扫描镜头与锐化」。"
            }
        case "64位":
            if fullPhysicalMode {
                return "精细冲印强制要求 Hanatos Float64，不能单独降为快速精度。"
            }
        case "Poisson":
            if model.grainOriginalMetalEnabled {
                return "当前启用了原版 Metal 颗粒分支，Poisson 开关由该路线控制。请先在「工艺 → 胶片」切换颗粒路线。"
            }
        case "胶片层间扩散／原版 FIR/YVV":
            if directPixelMode {
                return "原版像素处理必须保留 DIR / FIR-YVV。先退出原版像素处理。"
            }
        default:
            break
        }
        return "当前模式或前置条件不允许单独调整。检查「工艺」对应阶段已启用的模块，或切换到支持该功能的处理路线。"
    }

    private func availableSwitchInfo(_ title:String)->String {
        switch title {
        case "原版三亚层颗粒":
            return "「工艺 → 胶片」原版三亚层颗粒。关闭时不产生该层颗粒；开启后可展开染料云、微结构及 SciPy／Numba 参数。"
        case "乳剂散射与背反射联动":
            return "「工艺 → 胶片」的原版光子域乳剂散射与背反射；仅在精细冲印中可独立使用。"
        case "扫描镜头与锐化":
            return "「工艺 → 扫描」的原版扫描光学模糊及 Unsharp，独立于快速模式的 RGB 后期锐化。"
        case "光谱扫描":
            return "「工艺 → 扫描」的原版光谱扫描。精细冲印将其作为必需模块。"
        case "摄影柔化":
            return "「工艺 → 拍摄」先启用测光与镜头处理，再调节原版摄影 PSF。"
        case "背反射光晕":
            return "「工艺 → 胶片」的背反射光晕。是否使用快速版本或原版光学版本由当前冲印模式决定。"
        case "胶片颗粒", "快速胶片颗粒":
            return "这是快速颗粒路线，不是精细冲印的三亚层 Float64 颗粒。需要原版颗粒请进入「工艺 → 胶片」。"
        case "胶片层间扩散":
            return "「工艺 → 胶片」的 DIR 层间扩散；原版像素直连需要 FIR/YVV 依赖。"
        case "相纸显影曲线 s023":
            return "「工艺 → 相纸」的独立曲线开关，仅适用于支持该开关的负片快速处理路线。"
        default:
            return "该功能当前已满足前置条件，可以直接点击右侧开关开启。双击左侧名称恢复该模块默认状态。"
        }
    }

    /// Only CLOSED or LOCKED switches have an inline explanatory sentence
    /// and a tappable exclamation icon. An enabled switch that is ON
    /// remains compact to preserve the iOS16.5.1 floating editor viewport.
    private func switchGuidance(
        _ title:String,isOn:Bool,enabled:Bool,
        explicitReason:String?=nil
    )->SwitchGuidance? {
        guard !enabled || !isOn else {return nil}
        if !enabled {
            let reason=explicitReason ?? lockedSwitchReason(title)
            let state=isOn ? "已开启并锁定" : "当前不可操作"
            let explanation="当前状态：\(state)。\n原因及操作条件：\(reason)\n\n此说明不会自动改变任何冲印参数或依赖。"
            return SwitchGuidance(
                summary:state+" · "+reason,details:explanation
            )
        }
        let explanation="当前状态：可用，尚未开启。\n\(availableSwitchInfo(title))\n\n点击开关只执行原有操作，不会暗中修改其他处理模式。"
        return SwitchGuidance(
            summary:"当前关闭 · 点击开关即可开启",details:explanation
        )
    }

    private func switchInfoButton(
        _ title:String,guidance:SwitchGuidance
    )->some View {
        Button {
            switchExplanation=SwitchExplanation(
                title:title,summary:guidance.summary,
                details:guidance.details
            )
        } label: {
            Image(systemName:"exclamationmark.circle")
                .font(.system(size:16,weight:.medium))
                .foregroundColor(.secondary)
                .frame(width:30,height:32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看"+title+"的关闭或锁定原因")
        .accessibilityHint("只显示条件说明，不会自动切换开关")
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
            if savedFastSettings != nil {
                changes.append("退出原版像素处理，并恢复进入前的快速冲印设置")
            } else if model.sourcePhysicalDirectEnabled {
                changes.append("退出原版像素处理，同时关闭原版散射／光晕，避免静默改用近似算法")
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
        if mode == .physical {
            if !model.spatialDIREnabled { changes.append("启用胶片层间扩散") }
            if !model.spatialDIRSourceConvolutionEnabled {
                changes.append("启用原版空间扩散计算")
            }
            if !model.sourcePixelIOEnabled {
                changes.append("启用原版像素通道")
            }
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
            if model.scannerCAM16Enabled { changes.append("关闭旧版扫描 CAM16 LUT（精细 CAM16-UCS 独立配置）") }
            if model.scannerBlackWhiteEnabled { changes.append("关闭黑白场校准") }
            if model.exposureReferenceEnabled { changes.append("关闭曝光参考") }
        }
        return changes
    }

    private func requestSourceMode(_ mode: SourceModeChange) {
        guard model.hasPhoto && !model.busy else { return }
        if (mode == .pixel || mode == .physical) &&
            !model.photoDirectInputReady {
            sourceInputCompatibilityAlert=true
            return
        }
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
        // Compatibility mode retains existing strict dependencies; full
        // physical mode may prepare prerequisites only after confirmation.
        // A source-exact pixel path requires original photo bytes. Decoded
        // Apple/LibRaw CI images cannot be relabeled as Python Float64.
        guard model.lut != nil, model.originalPixelInputAvailable else { return }
        if mode == .pixel &&
            (!model.spatialDIREnabled ||
             !model.spatialDIRSourceConvolutionEnabled) { return }
        if requiredChanges(for: mode).isEmpty {
            commitSourceMode(mode)
        } else {
            pendingSourceMode = mode
        }
    }

    private func commitSourceMode(_ mode: SourceModeChange) {
        // Called only after confirmation of the affected settings.
        if mode == .disablePixel {
            if model.sourcePhysicalDirectEnabled {
                // Prevent silent reassignment of source photon optics to
                // legacy CI effects when leaving full original mode.
                model.scatterEnabled = false
                model.halationEnabled = false
            }
            model.sourcePixelIOEnabled = false
            model.sourcePhysicalDirectEnabled = false
            if let savedFastSettings {
                savedFastSettings.restore(model)
                self.savedFastSettings=nil
            }
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
        if !model.sourcePixelIOEnabled && savedFastSettings == nil {
            savedFastSettings=FastSettingsSnapshot(model)
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
            model.spatialDIREnabled = true
            model.spatialDIRSourceConvolutionEnabled = true
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
            model.lut != nil && model.originalPixelInputAvailable &&
            (mode == .pixel || model.sourcePixelIOEnabled)
        let blocked = model.busy || (!isOn && (!model.hasPhoto ||
            model.lut == nil || !model.spatialDIREnabled ||
            !model.spatialDIRSourceConvolutionEnabled ||
            (mode == .physical && !model.sourcePixelIOEnabled)))
        let reason:String? = {
            if !model.hasPhoto { return "先从相册或文件打开照片。" }
            if model.busy { return "正在处理照片，完成后即可操作。" }
            if model.lut == nil { return "请先选择可用的胶片／相纸材料并生成 LUT。" }
            if !model.spatialDIREnabled {
                return "请先在「工艺 → 胶片」开启「胶片层间扩散」。"
            }
            if !model.spatialDIRSourceConvolutionEnabled {
                return "请先在「工艺 → 胶片 → 层间扩散」开启原版 FIR/YVV。"
            }
            if !model.originalPixelInputAvailable || !model.photoDirectInputReady {
                return "原图没有可直连的已认证像素输入；查看图像输入检测或明确进行 P3 → sRGB 副本转换。"
            }
            if mode == .physical && !model.sourcePixelIOEnabled {
                return "请先启用 8-bit DIR 原版像素通道；精细冲印模式切换仍需确认依赖。"
            }
            return nil
        }()
        let note=switchGuidance(
            title,isOn:isOn,enabled:!blocked && reason==nil,
            explicitReason:reason
        )
        return VStack(alignment:.leading,spacing:2) {
            HStack(spacing:7) {
                Text(title)
                    .font(.caption2)
                    .frame(maxWidth:.infinity,alignment:.leading)
                Button {
                    if !isOn && !model.photoDirectInputReady {
                        sourceInputCompatibilityAlert=true
                    } else {
                        requestSourceMode(mode)
                    }
                } label: {
                    miniatureSwitch(isOn:isOn)
                        .frame(width:MiniSwitchMetrics.tapWidth,
                               height:MiniSwitchMetrics.tapHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(blocked)
                .accessibilityLabel(title+(isOn ? "，关闭" : "，开启"))
                .accessibilityHint("原版算法依赖先确认，再切换")
                if let note {
                    switchInfoButton(title,guidance:note)
                }
            }
            if let note {
                Text(note.summary)
                    .font(.system(size:10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
                    .accessibilityLabel(note.summary)
            }
        }
        .opacity(!isOn && !prerequisite ? 0.8 : 1)
    }

    /// Change top titles in the ONE lower sheet; the inactive adjustment
    /// controls stay unmounted. Defer the heavy detail tree across turns,
    /// preserving the existing iOS16.5.1 AttributeGraph crash protection.
    private func selectEditorPage(_ page: EditorPage) {
        guard unifiedEditorExpanded else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedEditorPage = page
            adjustmentRowsReady = false
            adjustmentDetailReady = false
        }
        guard page != .film else { return }
        DispatchQueue.main.async {
            guard unifiedEditorExpanded && selectedEditorPage == page else { return }
            adjustmentRowsReady = true
            DispatchQueue.main.async {
                guard unifiedEditorExpanded && selectedEditorPage == page &&
                      adjustmentRowsReady else { return }
                adjustmentDetailReady = true
            }
        }
    }

    private func openUnifiedEditor() {
        guard model.hasPhoto else { return }
        if unifiedEditorExpanded {
            closeUnifiedEditor()
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            controlsVisible = true
            unifiedEditorExpanded = true
            selectedEditorPage = .adjustment
            adjustmentRowsReady = false
            adjustmentDetailReady = false
        }
        // Bottom "调整" opens the adjustment page directly. Preserve the
        // iOS16-safe two-turn mounting that also runs on title switching.
        DispatchQueue.main.async {
            guard unifiedEditorExpanded && selectedEditorPage == .adjustment else { return }
            adjustmentRowsReady = true
            DispatchQueue.main.async {
                guard unifiedEditorExpanded && selectedEditorPage == .adjustment &&
                      adjustmentRowsReady else { return }
                adjustmentDetailReady = true
            }
        }
    }

    private func closeUnifiedEditor() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            adjustmentDetailReady = false
            adjustmentRowsReady = false
            unifiedEditorExpanded = false
        }
    }

    // Show the full source catalog, not only currently renderable IDs.
    // Non-renderable stock cards are visible but cannot change the selection.
    private var films: [MeasuredStock] {
        GeneratedMeasuredProfiles.entries.filter {
            $0.medium == "film" && $0.stage == "filming"
        }
    }
    private var media: [MeasuredStock] {
        GeneratedMeasuredProfiles.entries.filter { $0.stage == "printing" }
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
             ZStack {
                Color.black
                // The image area has a constant layout rectangle.
                // BOTH notifications are overlays on top of the photo.
                // Never place variable-height text above GeometryReader:
                // status transitions must not shift the image or zoom.
                VStack(spacing: 4) {
                    GeometryReader { previewSlot in
                        previewArea(size: previewSlot.size)
                            .frame(width: previewSlot.size.width,
                                   height: previewSlot.size.height,
                                   alignment: .top)
                            .clipped()
                            .overlay(alignment:.top) {
                                if model.hasPhoto {
                                    photoFloatingNotices
                                        .padding(.horizontal,9)
                                        .padding(.top,5)
                                }
                            }
                    }
                    bottomToolbar
                        .padding(.horizontal, 8)
                        .padding(.bottom, 7)
                }
                .frame(width: available.width, height: available.height)
            }
            // Single lower menu; NO left/right edge tabs or snapped
            // drawers. The bottom "调整" button is the only entry.
            .overlay(alignment: .bottom) {
                if unifiedEditorExpanded && model.hasPhoto {
                    let panelHeight = min(392, max(286, available.height * 0.50))
                    unifiedEditorDock(width: max(260, available.width - 16),
                                      maxHeight: panelHeight - 44)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 63)
                        .alert(item:$switchExplanation) { notice in
                            Alert(
                                title:Text(notice.title),
                                message:Text(notice.details),
                                dismissButton:.default(Text("知道了"))
                            )
                        }
                }
            }
            .sheet(item:$precisionEdit) { request in
                PrecisionEntrySheet(request:request)
            }
            .sheet(isPresented: $statusReportPresented,
                   onDismiss: onDiagnosticSheetDismissed) {
                statusReportSheet
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: model.photoSessionRevision) { _ in
                // A new photo of identical dimensions is a new session.
                savedFastSettings=nil
                originalHeld=false
                comparisonEnabled=false
                photoScale=1
                compareFraction=0.5
                pendingSourceMode=nil
            }
            .confirmationDialog("原版像素输入检测",isPresented:$sourceInputCompatibilityAlert,
                                titleVisibility:.visible) {
                if model.rawFastModeActive && model.capturedRAWURL != nil && !model.busy {
                    Button("生成 RAW 的 8-bit sRGB 副本（保留 DNG）") {
                        model.convertActiveRAWTo8BitSRGBCopy()
                    }
                }
                if model.photoP3ConversionPossible && !model.busy {
                    Button("转换 P3 为 sRGB 副本") {
                        do {
                            try model.convertCurrentP3ToSRGB()
                        } catch {
                            model.status="Build111 色彩转换失败："+error.localizedDescription
                        }
                    }
                }
                Button("关闭",role:.cancel) {}
            } message: {
                Text(model.photoInputSummary+"。"+model.photoInputExplanation)
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

    private func togglePhotoZoom() {
        guard model.hasPhoto else { return }
        withAnimation(.easeInOut(duration:0.2)) {
            photoScale=CGFloat(Build99InteractionRules.nextPhotoScale(
                Double(photoScale)
            ))
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
                    originalHeld ? model.originalPreview :
                        (model.processedPreview ?? model.originalPreview),
                    size: size
                )
                if model.hasPhoto && controlsVisible {
                    Text(originalHeld ? "原图" :
                         (model.simulationAwaitingCurrentSettings ||
                          model.processedPreview == nil
                            ? "当前效果正在更新 · 暂时显示原图"
                            : "按住看原图 · 双击放大"))
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
                togglePhotoZoom()
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
        // A zero-distance drag swallowed split-view double-tap zoom.
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { gesture in
                    compareFraction=Build99InteractionRules.compareDivider(
                        x:Double(gesture.location.x), width:Double(size.width)
                    )
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { togglePhotoZoom() }
        )
    }

    private var bottomToolbar: some View {
        HStack(spacing: 7) {
            toolButton("camera.fill", name: "NextLevel 专业拍照并直接冲印", action: onOpenCamera)
                .disabled(model.busy)
            if model.capturedRAWURL != nil {
                toolButton("doc", name: "分享保留的原始 RAW 文件", action: onShareRaw)
                    .disabled(model.busy)
            }
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo")
            }
            .accessibilityLabel("从相册导入照片")
            .disabled(model.busy)

            toolButton("folder", name: "从文件导入照片", action: onOpenPhotoFile)
                .disabled(model.busy)
            toolButton("cube", name: "导入 .cube LUT", action: onOpenLUT)
            // Keep both original buttons in place. Each opens a size menu:
            // original unchanged; smart up to 1300MB with live headroom and 12MP; economy 30% up to 7.2MP.
            // Do not silently shrink after a failed original-size render.
            Menu {
                Button("原始分辨率（不缩小）") {
                    onSaveToPhotos(.original)
                }
                Button("智能安全分辨率（最高 1200 万像素 · 预算最多 1300 MB）") {
                    onSaveToPhotos(.safe)
                }
                Button("省内存分辨率（最高 720 万像素）") {
                    onSaveToPhotos(.economy)
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 33, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("保存相册：选择原始、智能安全或省内存分辨率")
            .disabled(!model.hasPhoto || model.busy ||
                      model.simulationAwaitingCurrentSettings)
            Menu {
                Button("原始分辨率（不缩小）") {
                    onExport(.original)
                }
                Button("智能安全分辨率（最高 1200 万像素 · 预算最多 1300 MB）") {
                    onExport(.safe)
                }
                Button("省内存分辨率（最高 720 万像素）") {
                    onExport(.economy)
                }
                Divider()
                Button("TIFF 16-bit · 原始分辨率（需内存预检）") {
                    onExportTIFF16(.original)
                }
                Button("TIFF 16-bit · 智能安全分辨率") {
                    onExportTIFF16(.safe)
                }
                Button("TIFF 16-bit · 省内存分辨率") {
                    onExportTIFF16(.economy)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 33, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("分享存储：JPEG 或 TIFF 16-bit，三种明确分辨率选择")
            .disabled(!model.hasPhoto || model.busy ||
                      model.simulationAwaitingCurrentSettings)

            Spacer(minLength: 2)

            toolButton(comparisonEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                       name: "左右滑动对比", action: {
                comparisonEnabled.toggle()
                originalHeld = false
                compareFraction = 0.5
            })
            .disabled(!model.hasPhoto)

            Button(action: openUnifiedEditor) {
                VStack(spacing: 1) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .medium))
                    Text("调整")
                        .font(.system(size: 10, weight: .semibold))
                }
                .frame(width: 43, height: 40)
                .contentShape(Rectangle())
            }
            .disabled(!model.hasPhoto)
            .accessibilityLabel(unifiedEditorExpanded
                                ? "收起调整菜单" : "从下方打开调整菜单")
            .accessibilityHint("上方胶卷与调整名称切换；胶卷和相纸可左右滑动")
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
    /// Fixed compact overlay: status remains one line regardless of whether
    /// it says "busy", "PASS" or a long source error. Open diagnostics for
    /// the full untruncated message; source photography does not jump.
    private var photoFloatingNotices:some View {
        VStack(spacing:4) {
            if controlsVisible {
                Button {
                    statusReportPresented=true
                } label: {
                    statusChip
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看完整状态及 Metal 数值诊断报告")
            }
            inputCompatibilityBanner
        }
        .frame(maxWidth:.infinity,alignment:.top)
        .fixedSize(horizontal:false,vertical:true)
    }

    private var statusChip: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.busy ? "正在生成胶片预览…" : model.status)
                .font(.caption2)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height:32)
        .background(
            Color(uiColor: .secondarySystemBackground).opacity(0.93),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Always visible for capture / Photos / Files, even with controls hidden.
    /// Small diagnostic row; never move/resize image inside its own preview.
    private var inputCompatibilityBanner:some View {
        Button {
            sourceInputCompatibilityAlert=true
        } label: {
            HStack(alignment:.center,spacing:7) {
                Image(systemName:model.photoDirectInputReady
                      ? "checkmark.shield" : "info.circle")
                    .font(.caption2)
                VStack(alignment:.leading,spacing:2) {
                    Text(model.photoInputSummary)
                        .font(.system(size:10,weight:.medium))
                        .lineLimit(1)
                    Text(model.photoDirectInputReady
                         ? "原版像素输入预检通过"
                         : (model.rawFastModeActive
                            ? "胶片效果正常；8-bit 原版直连需生成明确副本"
                            : (model.photoP3ConversionPossible
                                ? "P3 需明确转换为 sRGB；点此转换"
                                : "原版像素输入不可用；点此查看原因")))
                        .font(.system(size:10))
                        .lineLimit(1)
                }
                Spacer(minLength:0)
                Image(systemName:"chevron.right")
                    .font(.caption2)
            }
            .foregroundColor(.primary)
            .padding(.horizontal,9)
            .frame(height:42)
            .background(Color(uiColor:.secondarySystemBackground)
                        .opacity(0.94),in:RoundedRectangle(cornerRadius:9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("当前照片：\(model.photoInputSummary)。\(model.photoInputExplanation)")
    }

    private var statusReportSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Build100｜功能验收状态")
                        .font(.headline)
                    Text("当前处理：" +
                        (fullPhysicalMode ? "原版 Float64 光学（受控 PASS，整图未认证）" :
                         directPixelMode ? "8-bit 原版 DIR 直连（范围有限）" :
                         "移动快速兼容处理"))
                        .font(.subheadline)
                    Text("源码阶段参考与自动测试 ≠ 真机整图等价认证。当前版本尚未获得完整 Python 原版数值认证。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if model.simulationAwaitingCurrentSettings {
                        Text("当前胶片/相纸 LUT 待更新或失败：预览／导出尚未就绪。")
                            .font(.caption)
                    }
                    Button {
                        statusReportPresented = false
                        onShareBuild100Readiness()
                    } label: {
                        Label("导出设备验收清单 JSON（12 项）",
                              systemImage:"square.and.arrow.up.on.square")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
                    Text("记录 App 版本、iOS 版本和当前处理状态。所有尚未实际执行的真机、Python 整图和随机统计测试均明确写为 not_run；此文件不是合格证书。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild101DeviceParity()
                    } label: {
                        Label("执行原版 Python → 本机 Swift 阶段数值对照",
                              systemImage:"checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("使用已打包的 Build92 Python 原版参考图，让当前设备实际运行 Swift 冲印处理链并比较。PASS 仅代表受控样本，不代表完整原版、默认随机数、RAW 或高位深全链认证。无论通过或失败都生成本机 JSON 证据。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild103Metrics()
                    } label: {
                        Label("Build103：28 阶段误差、受控颗粒与实际内存报告",
                              systemImage:"chart.xyaxis.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("重新执行 4 组原版 Python 图的 28 个核心 Float64 阶段，保存每阶段 MAE／RMSE／最大误差与首错；另测固定种子单线程 Numba 统计和 8 MiB 实际触页。未验证多线程默认 RNG、13MP 整图、RAW／ICC。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild104Grain()
                    } label: {
                        Label("Build104：原版 20 颗粒阶段数值与两种随机分支报告",
                              systemImage:"circle.hexagongrid")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("读取随 App 打包的 Python 原版 5 组颗粒整图参考，逐阶段对照 Swift Float64，测试无微结构种子分支与单层 SciPy 标志；导出绑定本机版本及提交 SHA 的真实结果 JSON。不是全分辨率/多线程 RNG 认证。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild107CombinedFeedback()
                    } label: {
                        Label("Build106 + 107：一键生成真机反馈 LOG + JSON",
                              systemImage:"doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("一次运行 Build103 28 阶段、Build104 20 阶段、Build106 六档×四种内存预算和 Build107 实际 16MiB 触页/进程 RSS。自动生成同编号 .log 与 .json 并一起分享。13MP 全图/Jetsam 仍未认证。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild108FullFrameFeedback()
                    } label: {
                        Label("Build108：真实 100/200 万像素光学与 106–108 综合 LOG",
                              systemImage:"waveform.path.ecg")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("执行原版 Float64 100 万像素（含九层颗粒）＋200 万像素（不含颗粒）真实逐像素显影／印相／扫描；25ms 采样 RSS。保留 Build103/104 的 48 阶段与 Build106/107 报告，一次分享 .log＋.json。测试可能耗时较长；不宣称 1300 万像素或默认并行 RNG。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild110GamutEvidence()
                    } label: {
                        Label("Build110：Oklch／CAM16 四模式真机＋综合报告",
                              systemImage:"checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("一次生成 LOG＋JSON：先记录当前原版像素／全光学／Hanatos 与两个开关，"
                         + "再真实执行默认、仅 Oklch、仅 CAM16、两项同时开启四组 512×512 "
                         + "Float64 显影/印相/扫描。记录逐模式耗时、RSS、输出指纹、"
                         + "与默认值的差异；内含原 Build106–108 全部诊断。"
                         + "本测试不是对已导入照片的逐像素 Python 原版认证。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild114FourGates()
                    } label: {
                        Label("Build114：13MP 真机压力测试＋四项认证边界报告",
                              systemImage:"memorychip")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("显式运行 5000×2600 基础 Float64 全光学，采样 RSS，写入 LOG＋JSON；高风险内存测试可能遭遇 Jetsam。只认证实测范围。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild115ParallelGrain()
                    } label: {
                        Label("Build115：默认 Numba 多线程颗粒真机统计＋生产整合",
                              systemImage:"cpu")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("实测 4 工作线程 Poisson/Binomial 和 lognormal 统计；执行两条真实三亚层颗粒路线（SciPy 与可选 fast_stats），导出 SHA 绑定的 LOG＋JSON。仅统计等价，不冒充随机像素逐位一致。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=false
                        onRunBuild116GrainMemory()
                    } label: {
                        Label("Build116：一次测试 1–13MP 全尺寸 × 双颗粒路线",
                              systemImage:"memorychip")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("一次完成 1／2／3／4／6／8／10／13MP × SciPy／Numba 4 线程（共 16 项）。每项先过生产内存预检：可运行则实测 RSS／耗时；不允许则明确记录拒绝。结果统一导出 LOG＋JSON；高内存测试仍有系统终止风险。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("Build119：大图独立测试，每次只运行一个尺寸")
                        .font(.subheadline)
                    ForEach([8,10,13],id:\.self) { mp in
                        Button {
                            statusReportPresented=false
                            onRunBuild118LargeMemory(mp)
                        } label: {
                            Label("Build119：单独测试 \(mp)MP · SciPy＋Numba",
                                  systemImage:"memorychip")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                    }
                    Text("8／10／13MP 三个独立按钮。每次只测选中的一个尺寸，两条原版三亚层颗粒路线，分别导出 LOG＋JSON；保留独立闪退检查点。阶段 RSS 与耗时仅代表实测，仍可能遭遇 Jetsam。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Divider()
                    if model.hardwareDiagnosticReport != nil {
                        Label("本次运行的诊断日志可查看；不等于正式认证",
                              systemImage: "doc.text.magnifyingglass")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Button {
                        statusReportPresented = false
                        onCaptureBuild77Evidence()
                    } label: {
                        Label("一次采集完整负片／正片／扩散阶段证据",systemImage:"square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
                    Text("仅导出真实 iPhone Float64 阶段数据；本操作不声明 Python 数值等价。结果保存在「文件」App 的本机应用目录。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Divider()
                    Text("开发者诊断 · 不影响当前冲印结果")
                        .font(.subheadline).fontWeight(.semibold)
                    Button("Build81 原版裁切/预览数值测试（限 2MP sRGB）") {
                        model.probeBuild81OriginalGeometry()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.busy || !model.originalPixelInputAvailable)
                    if model.capturedRAWURL != nil {
                        Button("检查 Apple RAW 实际解码器") {
                            model.probePreservedRAWBackend()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.busy)
                        Menu("Apple RAW 白平衡 / EV / 镜头专项诊断") {
                            Button("相机原片白平衡 / EV 0") {
                                model.probePreservedRAWDevelopment(.asShot)
                            }
                            Button("日光 6504K / Tint 0") {
                                model.probePreservedRAWDevelopment(.daylightDiagnostic)
                            }
                            Button("钨灯 2850K / Tint 0") {
                                model.probePreservedRAWDevelopment(.tungstenDiagnostic)
                            }
                            Button("日光 +1EV 与镜头修正") {
                                model.probePreservedRAWDevelopment(.init(
                                    whiteBalance:.appleTemperature(
                                        kelvin:6504,tintOffset:0
                                    ),
                                    exposureEV:1,
                                    appleLensCorrection:true
                                ))
                            }
                        }
                        .disabled(model.busy)
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
            .navigationTitle("验证状态与诊断")
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

    /// One full-width bottom editor: titles switch content, not separate
    /// drawers. Keep the existing AnyView-based detail tree intact.
    private func unifiedEditorDock(width: CGFloat, maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                editorTab(.film)
                editorTab(.adjustment)
                editorTab(.workflow)
                // Build120: Advanced is now ONLY verification/diagnostics.
                // Actual image-affecting controls live in the process stages.
                // Keep the lazily mounted lab overview for iOS16.5.1 safety.
                Menu {
                    Button("验证状态与诊断") {
                        statusReportPresented=true
                    }
                    Button("验证概况") {
                        selectEditorPage(.laboratory)
                    }
                } label: {
                    Text("高级")
                        .font(.system(size:12,weight:.semibold))
                        .foregroundColor(selectedEditorPage == .laboratory
                                         ? .accentColor : .primary)
                        .frame(height:34)
                        .padding(.horizontal,7)
                        .background(Color.primary.opacity(0.06),
                                    in:Capsule())
                }
                .accessibilityLabel("高级菜单：仅验证状态与开发者诊断")
"                Spacer(minLength: 0)
                if selectedEditorPage == .adjustment {
                    Button {
                        model.applyMeasuredSimulation()
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.caption)
                            .frame(width: 33, height: 34)
                    }
                    .disabled(!model.hasPhoto || model.busy)
                    .accessibilityLabel("应用模拟")
                }
                Button(action: closeUnifiedEditor) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .frame(width: 33, height: 34)
                }
                .accessibilityLabel("关闭下方调整菜单")
            }
            .buttonStyle(.plain)
            .frame(height: 44)
            .padding(.horizontal, 10)

            Divider()
            editorPageContent
                .frame(height: maxHeight, alignment: .top)
        }
        .frame(width: width, height: maxHeight + 44, alignment: .top)
        .foregroundColor(.primary)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.94),
                    in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.18), radius: 9, y: 3)
    }

    private func editorTab(_ page: EditorPage) -> some View {
        Button { selectEditorPage(page) } label: {
            Text(page.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .foregroundColor(selectedEditorPage == page
                                 ? .accentColor : .primary)
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(selectedEditorPage == page
                            ? Color.accentColor.opacity(0.15)
                            : Color.primary.opacity(0.06), in: Capsule())
        }
        .accessibilityLabel(page.rawValue + "，切换编辑页")
    }

    // iOS16.5.1 safety: dismount inactive complex view trees and stage the
    // active detail after two turns to prevent generic metadata stack crash.
    private var editorPageContent: AnyView {
        if selectedEditorPage == .film {
            return AnyView(filmSelectionContent)
        }
        guard adjustmentRowsReady else {
            return AnyView(Color.clear.accessibilityHidden(true))
        }
        switch selectedEditorPage {
        case .film: return AnyView(filmSelectionContent)
        case .adjustment: return AnyView(dailyAdjustmentControls)
        case .workflow: return AnyView(processControls)
        case .laboratory: return AnyView(advancedControls)
        }
    }

    // Build127: the horizontal gestures BROWSE. Only tapping a validated
    // card changes an active film/paper, so no speculative render per swipe.
    private var favoriteFilmIDs:[String] {
        favoriteFilmIDsStored.split(separator:"|").map(String.init)
    }
    private var recentFilmIDs:[String] {
        recentFilmIDsStored.split(separator:"|").map(String.init)
    }
    private func isFavoriteFilm(_ id:String)->Bool {
        favoriteFilmIDs.contains(id)
    }
    private func toggleFavoriteFilm(_ id:String) {
        var ids=favoriteFilmIDs
        if ids.contains(id) {
            ids.removeAll(where:{$0==id})
        } else {
            ids.insert(id,at:0)
        }
        favoriteFilmIDsStored=ids.prefix(20).joined(separator:"|")
    }
    private func recordRecentFilm(_ id:String) {
        guard films.contains(where:{$0.id==id}) else{return}
        let updated=[id]+recentFilmIDs.filter{$0 != id}
        let saved=updated.prefix(5).joined(separator:"|")
        if saved != recentFilmIDsStored {recentFilmIDsStored=saved}
    }
    private var quickFilmStocks:[MeasuredStock] {
        let ids=favoriteFilmIDs+recentFilmIDs
        var unique:Set<String>=[]
        return ids.compactMap { id -> MeasuredStock? in
            guard !unique.contains(id),
                  SpectralPhysics.supportedFilmIDs.contains(id),
                  let stock=films.first(where:{$0.id==id}) else{return nil}
            unique.insert(id)
            return stock
        }.prefix(5).map{$0}
    }
    private var quickSavedRecipes:[Build126Recipe] {
        Array(model.savedRecipes.sorted {
            if $0.favorite != $1.favorite {return $0.favorite}
            return $0.modifiedAt > $1.modifiedAt
        }.prefix(2))
    }

    private func selectRecipeFromShelf(_ recipe:Build126Recipe) {
        do {
            // Build126 preflights input/RAW8/DIR before mutating any setting.
            // The successful call owns the ONE optical render and rollback.
            try model.applySavedRecipe(recipe)
            selectedFilmID=recipe.filmID
            selectedPaperID=recipe.paperID
        } catch {
            recipeApplyError=error.localizedDescription +
                "\n配方未应用；保留原照片、参数与预览。"
        }
    }

    private var filmSelectionContent:AnyView {
        AnyView(
            ScrollView(.vertical) {
                VStack(alignment:.leading,spacing:9) {
                    materialCardRow("胶片 · FILM",
                                    items:films,selection:$selectedFilmID,
                                    film:true)
                    if isReversal {
                        HStack(spacing:6) {
                            Image(systemName:"film")
                            Text("反转片：原版直扫，不使用相纸")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal,5)
                        .frame(minHeight:31)
                    } else {
                        materialCardRow("相纸 · PAPER",
                                        items:media,selection:$selectedPaperID,
                                        film:false)
                    }
                    HStack(spacing:5) {
                        Text("常用胶片")
                            .font(.caption2).fontWeight(.semibold)
                        Spacer()
                        Text("收藏优先 · 最近使用")
                            .font(.system(size:10)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal,4)
                    if quickFilmStocks.isEmpty {
                        Text("点胶片卡片右上角 ☆ 收藏，选择过的胶片也会显示在这里。")
                            .font(.system(size:10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal,4)
                    } else {
                        ScrollView(.horizontal,showsIndicators:false) {
                            LazyHStack(spacing:6) {
                                ForEach(quickFilmStocks) { stock in
                                    Button {
                                        guard !model.busy else {return}
                                        recordRecentFilm(stock.id)
                                        if selectedFilmID != stock.id {
                                            selectedFilmID=stock.id
                                        }
                                    } label: {
                                        Text(stock.name)
                                            .font(.system(size:11,weight:.medium))
                                            .fixedSize(horizontal:false,vertical:true)
                                            .padding(.horizontal,10)
                                            .frame(minHeight:30)
                                            .background(selectedFilmID==stock.id
                                                ? Color.accentColor.opacity(0.16)
                                                : Color.primary.opacity(0.06),
                                                in:RoundedRectangle(cornerRadius:8))
                                    }
                                    .disabled(model.busy)
                                    .accessibilityLabel("选择常用胶片 " + stock.name)
                                }
                            }
                        }
                    }
                    Divider()
                    HStack(spacing:5) {
                        Text("我的冲印配方")
                            .font(.caption2).fontWeight(.semibold)
                        Spacer()
                        Button("查看全部／保存") {onOpenRecipes()}
                            .font(.system(size:11,weight:.semibold))
                            .accessibilityLabel("打开所有自定义冲印配方及保存当前效果")
                    }
                    .padding(.horizontal,4)
                    if quickSavedRecipes.isEmpty {
                        Text("调出满意照片后，可在这里保存完整冲印参数。")
                            .font(.system(size:10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal,4)
                    } else {
                        ForEach(quickSavedRecipes) { recipe in
                            Button {selectRecipeFromShelf(recipe)} label: {
                                HStack(spacing:7) {
                                    if let data=recipe.coverJPEG,
                                       let preview=UIImage(data:data) {
                                        Image(uiImage:preview)
                                            .resizable().scaledToFill()
                                            .frame(width:33,height:33)
                                            .clipped()
                                            .cornerRadius(5)
                                    } else {
                                        Image(systemName:"camera.filters")
                                            .frame(width:33,height:33)
                                    }
                                    Text(recipe.name)
                                        .font(.system(size:11,weight:.medium))
                                        .fixedSize(horizontal:false,vertical:true)
                                        .frame(maxWidth:.infinity,alignment:.leading)
                                    if recipe.favorite {
                                        Image(systemName:"star.fill")
                                            .font(.caption2)
                                    }
                                    Text("应用")
                                        .font(.caption2).fontWeight(.semibold)
                                }
                                .padding(6)
                                .background(Color.primary.opacity(0.06),
                                            in:RoundedRectangle(cornerRadius:8))
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.hasPhoto || model.busy ||
                                      model.isRecipeApplying ||
                                      model.simulationAwaitingCurrentSettings)
                            .accessibilityLabel("应用保存的冲印配方 " + recipe.name)
                        }
                    }
                    Button(action:onOpenCatalog) {
                        HStack {
                            Image(systemName:"list.bullet.rectangle")
                            Text("查看全部 28 款原版材料及参数")
                        }
                        .font(.caption2)
                        .frame(maxWidth:.infinity,minHeight:27)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal,9)
                .padding(.top,8)
                .padding(.bottom,14)
            }
            .frame(maxHeight:.infinity)
            .onAppear {recordRecentFilm(selectedFilmID)}
            .onChange(of:selectedFilmID) { id in recordRecentFilm(id) }
            .alert("配置不兼容",isPresented:Binding(
                get:{recipeApplyError != nil},
                set:{if !$0 {recipeApplyError=nil}}
            )) {
                Button("关闭",role:.cancel){recipeApplyError=nil}
            } message: {
                Text(recipeApplyError ?? "")
            }
        )
    }

    private func materialCardRow(
        _ title:String,items:[MeasuredStock],
        selection:Binding<String>,film:Bool
    )->some View {
        VStack(alignment:.leading,spacing:4) {
            HStack {
                Text(title)
                    .font(.caption2).fontWeight(.semibold)
                Spacer()
                Text("左右滑动浏览 · 点卡片选择")
                    .font(.system(size:10)).foregroundColor(.secondary)
            }
            .padding(.horizontal,4)
            ScrollViewReader { scroll in
                ScrollView(.horizontal,showsIndicators:false) {
                    LazyHStack(spacing:8) {
                        ForEach(items) { stock in
                            materialCard(
                                stock,film:film,
                                selected:selection.wrappedValue==stock.id,
                                supported:film
                                    ? SpectralPhysics.supportedFilmIDs.contains(stock.id)
                                    : SpectralPhysics.supportedPaperIDs.contains(stock.id)
                            ) {
                                guard !model.busy else{return}
                                if film {recordRecentFilm(stock.id)}
                                if selection.wrappedValue != stock.id {
                                    selection.wrappedValue=stock.id
                                }
                            }
                            .id(stock.id)
                        }
                    }
                    .padding(.vertical,3)
                }
                .onAppear {
                    scroll.scrollTo(selection.wrappedValue,anchor:.center)
                }
                .onChange(of:selection.wrappedValue) { newID in
                    withAnimation(.easeInOut(duration:0.15)) {
                        scroll.scrollTo(newID,anchor:.center)
                    }
                }
            }
        }
    }

    private func materialCard(
        _ stock:MeasuredStock,film:Bool,selected:Bool,
        supported:Bool,onSelect:@escaping ()->Void
    )->some View {
        ZStack(alignment:.topTrailing) {
            Button(action:onSelect) {
                VStack(alignment:.leading,spacing:3) {
                    Text(stock.name)
                        .font(.system(size:12,weight:.semibold))
                        .foregroundColor(supported ? .primary : .secondary)
                        .fixedSize(horizontal:false,vertical:true)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .padding(.trailing,film ? 20 : 0)
                    Spacer(minLength:0)
                    Text(supported
                         ? (selected ? "✓ 当前使用" : "点击选择 · 可模拟")
                         : "仅目录数据 · 暂不可用")
                        .font(.system(size:10))
                        .foregroundColor(supported ? .secondary : .secondary)
                }
                .padding(.horizontal,10)
                .padding(.vertical,8)
                .frame(width:206,height:91,alignment:.topLeading)
                .background(selected
                    ? Color.accentColor.opacity(0.20)
                    : Color.primary.opacity(supported ? 0.07 : 0.035),
                    in:RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10)
                    .stroke(selected ? Color.accentColor
                           : Color.primary.opacity(0.07),lineWidth:1))
            }
            .buttonStyle(.plain)
            .disabled(!supported || model.busy)
            .accessibilityLabel(
                (film ? "胶片 " : "相纸 ") + stock.name +
                (supported ? (selected ? "，当前选择" : "，点击选择")
                           : "，仅目录数据，不可模拟")
            )
            if film {
                Button {
                    toggleFavoriteFilm(stock.id)
                } label: {
                    Image(systemName:isFavoriteFilm(stock.id)
                          ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundColor(isFavoriteFilm(stock.id)
                                         ? .accentColor : .secondary)
                        .frame(width:29,height:29)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    (isFavoriteFilm(stock.id) ? "取消收藏胶片 " : "收藏胶片 ")
                    + stock.name
                )
            }
        }
    }

    // C workflow: visually meaningful daily adjustments, literal process
    // stages, plus the existing untouched algorithm laboratory. These views
    // bind existing production state; no synthetic 'warmth' sliders or
    // approximate algorithms are introduced by the redesign.
    private var currentMaterialSummary: some View {
        let filmName=films.first(where: {$0.id == selectedFilmID})
            .map { shortName($0) } ?? selectedFilmID
        let paperName=media.first(where: {$0.id == selectedPaperID})
            .map { shortName($0) } ?? selectedPaperID
        let processing=fullPhysicalMode
            ? "精细冲印 · 受控验证"
            : (directPixelMode ? "原版 DIR 直连" : "快速冲印")
        return HStack(spacing: 4) {
            Text(filmName)
            if !isReversal {
                Text("·")
                Text(paperName)
            }
            Text("·")
            Text(processing)
        }
        .font(.system(size: 10,weight:.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.76)
        .foregroundColor(.secondary)
        .padding(.horizontal, 11)
        .padding(.top, 4)
        .accessibilityLabel("当前材料与处理路线："
                            + filmName + "，" + processing)
    }

    private func dailyCategoryTab(_ category: DailyCategory) -> some View {
        Button { selectedDailyCategory = category } label: {
            Text(category.rawValue)
                .font(.system(size: 12,weight:.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 31)
                .foregroundColor(selectedDailyCategory == category
                                 ? .accentColor : .primary)
                .background(selectedDailyCategory == category
                            ? Color.accentColor.opacity(0.15)
                            : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.rawValue + "调整")
    }

    private var dailyAdjustmentControls: AnyView {
        AnyView(
            VStack(alignment:.leading,spacing:5) {
                currentMaterialSummary
                HStack(spacing: 5) {
                    ForEach(DailyCategory.allCases,id:\.self) { category in
                        dailyCategoryTab(category)
                    }
                }
                .padding(.horizontal, 8)
                Divider().padding(.horizontal, 8)
                if adjustmentDetailReady {
                    ScrollView(.vertical) {
                        dailySettings
                            .padding(.horizontal, 11)
                            .padding(.bottom, 8)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }
                    .frame(maxHeight:.infinity)
                }
            }
        )
    }

    private var dailySettings: AnyView {
        switch selectedDailyCategory {
        case .light: return AnyView(exposureSettings)
        case .color: return AnyView(dailyColorSettings)
        case .texture: return AnyView(dailyTextureSettings)
        case .detail: return AnyView(dailyDetailSettings)
        }
    }

    private var dailyColorSettings: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("冲印色调")
                .font(.caption).fontWeight(.semibold)
            if isReversal {
                Text("反转片直接扫描，不经过相纸滤色。色域路线与光学参数请在「工艺」调整。")
                    .font(.caption2).foregroundColor(.secondary)
            } else if model.originalPrintOpticsEnabled {
                Text("在相纸曝光阶段调节滤色，不是简单的 RGB 颜色叠加。")
                    .font(.caption2).foregroundColor(.secondary)
                morphSlider("青色滤光",value:$model.printCyanShift,range:-40...40)
                morphSlider("洋红滤光",value:$model.printMagentaShift,range:-40...40)
                morphSlider("黄色滤光",value:$model.printYellowShift,range:-40...40)
            } else {
                Text("当前路线未启用光学放大机。前往「工艺 → 相纸」启用后可调整真实冲印滤色。")
                    .font(.caption2).foregroundColor(.secondary)
                Button("前往相纸设置") {
                    selectedProcessStage = .paper
                    selectEditorPage(.workflow)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var dailyTextureSettings: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("胶片质感")
                .font(.caption).fontWeight(.semibold)
            if fullPhysicalMode {
                // Same original source binding as 工艺 → 胶片.
                // Never expose the unrelated legacy fast-grain switch as
                // an apparently broken toggle in the precise workflow.
                resetToggle("原版三亚层颗粒",
                            value:$model.sourcePhysicalGrainEnabled,
                            enabled:model.hasPhoto && !model.busy,
                            resetTo:false)
                    .onChange(of:model.sourcePhysicalGrainEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                if model.sourcePhysicalGrainEnabled {
                    Text("原版颗粒路线已开启；SciPy／Numba、染料云和微结构请在「工艺 → 胶片」调整。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            } else {
                resetToggle("胶片颗粒",value:$model.grainEnabled,
                            enabled:model.hasPhoto && !model.busy && !directPixelMode,
                            resetTo:false)
                    .onChange(of:model.grainEnabled) { _ in onRefresh() }
                if model.grainEnabled && !directPixelMode {
                    strengthControl("颗粒强度",value:$model.grainAmount,
                                    range:0...2,suffix:"×",resetTo:1)
                }
            }
            resetToggle("背反射光晕",value:$model.halationEnabled,
                        enabled:model.hasPhoto && !model.busy &&
                                (!directPixelMode || fullPhysicalMode),resetTo:false)
                .onChange(of:model.halationEnabled) { _ in onRefresh() }
            if model.halationEnabled {
                strengthControl("光晕强度",value:$model.halationAmount,
                                range:0...3,suffix:"×",resetTo:1)
            }
            if fullPhysicalMode {
                resetToggle("摄影柔化",value:$model.sourceCameraDiffusionEnabled,
                            enabled:model.hasPhoto && !model.busy &&
                                    model.sourceCameraPreFilmEnabled,resetTo:false)
                    .onChange(of:model.sourceCameraDiffusionEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                Text("柔化需先在「工艺 → 拍摄」启用镜头处理；三亚层颗粒参数在「工艺 → 胶片」展开。")
                    .font(.caption2).foregroundColor(.secondary)
            } else if directPixelMode {
                Text("兼容处理不支持旧版随机颗粒；请在工艺中选择可用模式。")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("当前使用快速质感效果。精细光子扩散请切换至精细冲印。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var dailyDetailSettings: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("清晰度")
                .font(.caption).fontWeight(.semibold)
            if fullPhysicalMode {
                Text("精细冲印的锐化发生在扫描阶段，保持原版计算顺序。")
                    .font(.caption2).foregroundColor(.secondary)
                Button("前往扫描设置") {
                    selectedProcessStage = .scanner
                    selectEditorPage(.workflow)
                }
                .buttonStyle(.bordered)
            } else {
                resetToggle("扫描锐化",value:$model.scannerFinishingEnabled,
                            enabled:model.hasPhoto && !model.busy && !directPixelMode,
                            resetTo:false)
                    .onChange(of:model.scannerFinishingEnabled) { _ in onRefresh() }
                if model.scannerFinishingEnabled && !directPixelMode {
                    strengthControl("锐化强度",value:$model.scannerSharpenAmount,
                                    range:0...1.5,suffix:"×",resetTo:0.7)
                }
                if directPixelMode {
                    Text("兼容处理不支持旧版扫描锐化；可在工艺中选择精细冲印。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    private var processingModeBar: some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:6) {
                Button {
                    if directPixelMode { requestSourceMode(.disablePixel) }
                } label: {
                    Text("快速冲印")
                        .font(.system(size:12,weight:.semibold))
                        .frame(maxWidth:.infinity,minHeight:30)
                        .foregroundColor(!directPixelMode ? .accentColor : .primary)
                        .background(!directPixelMode
                            ? Color.accentColor.opacity(0.15)
                            : Color.primary.opacity(0.06),
                            in:RoundedRectangle(cornerRadius:8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快速冲印；沿用当前已验证的移动处理通道")
                Button {
                    if !fullPhysicalMode { requestSourceMode(.physical) }
                } label: {
                    Text("精细冲印")
                        .font(.system(size:12,weight:.semibold))
                        .frame(maxWidth:.infinity,minHeight:30)
                        .foregroundColor(fullPhysicalMode ? .accentColor : .primary)
                        .background(fullPhysicalMode
                            ? Color.accentColor.opacity(0.15)
                            : Color.primary.opacity(0.06),
                            in:RoundedRectangle(cornerRadius:8))
                }
                .buttonStyle(.plain)
                .disabled(!model.hasPhoto || model.busy ||
                          model.lut == nil || !model.originalPixelInputAvailable)
                .accessibilityHint("需要已认证原始照片字节、胶片/相纸与完整 DIR。RAW 兼容图不能进入原版精确模式；变更前确认")
            }
            if !model.originalPixelInputAvailable && model.hasPhoto {
                Text("当前输入无原版像素直连数据；继续使用快速冲印，不会假装为 Float64 精确路径。")
                    .font(.caption2).foregroundColor(.secondary)
            } else if directPixelMode && !fullPhysicalMode {
                Text("当前为 8-bit DIR 像素处理；精细冲印需要另外确认原版全光学依赖。")
                    .font(.caption2).foregroundColor(.secondary)
            } else if fullPhysicalMode {
                Text("13MP 基础三亚层双路线已真机渲染；完整 RAW／ICC 和 Python 原版整图仍未认证。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // Build112: four visible source routes map 1:1 to the same two
    // proven Build110 Oklch/CAM16 fields. No preset persistence.
    private var currentSourceColorRoute:SourceColorRoute {
        switch (model.sourcePhysicalInputOklchEnabled,
                model.sourcePhysicalCAM16DefaultGamutEnabled) {
        case (false,false): return .classic
        case (true,false): return .oklch
        case (false,true): return .cam16
        case (true,true): return .both
        }
    }

    private func selectSourceColorRoute(_ route:SourceColorRoute) {
        guard fullPhysicalMode && model.hasPhoto && !model.busy &&
              model.hanatosOriginalPrecisionEnabled &&
              model.originalScannerEnabled else {return}
        // Oklch operates only on the Hanatos TC rebuild. A Mallett
        // camera method is NOT silently replaced on button tap.
        guard !route.usesOklch ||
              model.sourceCameraRawMethod == .hanatos2025 else {return}
        guard currentSourceColorRoute != route else {return}
        model.sourcePhysicalInputOklchEnabled=route.usesOklch
        model.sourcePhysicalCAM16DefaultGamutEnabled=route.usesCAM16
        model.queueSpectralPreview()
    }

    private func sourceColorRouteButton(_ route:SourceColorRoute) -> some View {
        let selected=currentSourceColorRoute == route
        let permitted=fullPhysicalMode && model.hasPhoto && !model.busy &&
            model.originalScannerEnabled && model.hanatosOriginalPrecisionEnabled &&
            (!route.usesOklch ||
             model.sourceCameraRawMethod == .hanatos2025)
        return Button {selectSourceColorRoute(route)} label: {
            Text(route.label)
                .font(.system(size:11,weight:.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth:.infinity,minHeight:30)
                .foregroundColor(selected ? .accentColor : .primary)
                .background(selected ? Color.accentColor.opacity(0.15)
                           :Color.primary.opacity(0.06),
                            in:RoundedRectangle(cornerRadius:8))
        }
        .buttonStyle(.plain)
        .disabled(!permitted)
        .opacity(permitted ? 1 : 0.45)
        .accessibilityLabel(route.label +
            (selected ? "，已选择" : "，切换处理路线"))
        .accessibilityHint(route.usesOklch
            ? "需要精细冲印和 Hanatos2025；原版算法保持不变"
            : "受控真机验证通过；全尺寸原版 Python 整图仍未认证")
    }

    private var sourceColorRouteControls:AnyView {
        AnyView(
            VStack(alignment:.leading,spacing:4) {
                Text("原版色域路线 · 受控真机 4/4 PASS")
                    .font(.system(size:10,weight:.medium))
                    .foregroundColor(.secondary)
                HStack(spacing:5) {
                    sourceColorRouteButton(.classic)
                    sourceColorRouteButton(.oklch)
                }
                HStack(spacing:5) {
                    sourceColorRouteButton(.cam16)
                    sourceColorRouteButton(.both)
                }
                Text(model.sourceCameraRawMethod == .hanatos2025
                     ? "实际调用原版 Float64；完整照片 Python 对照未认证"
                     : "当前为 Mallett：Oklch 需要在拍摄阶段切换 Hanatos2025")
                    .font(.system(size:10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundColor(.secondary)
            }
        )
    }

    private func processTab(_ stage: ProcessStage) -> some View {
        let active=(selectedProcessStage == stage) ||
                   (isReversal && selectedProcessStage == .paper &&
                    stage == .scanner)
        return Button { selectedProcessStage = stage } label: {
            Text(stage.rawValue)
                .font(.system(size:12,weight:.semibold))
                .frame(maxWidth:.infinity,minHeight:30)
                .foregroundColor(active ? .accentColor : .primary)
                .background(active ? Color.accentColor.opacity(0.15)
                                   : Color.primary.opacity(0.06),
                            in:RoundedRectangle(cornerRadius:8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stage.rawValue + "处理阶段")
    }

    private var processControls: AnyView {
        AnyView(
            VStack(alignment:.leading,spacing:5) {
                currentMaterialSummary
                processingModeBar.padding(.horizontal,10)
                if !fullPhysicalMode {
                    // Keep the old 8-bit DIR path available independent of
                    // the Float64 physical button. Same confirm-first gate.
                    sourceModeControl("8-bit 原版 DIR 像素直连（实验）",mode:.pixel)
                        .padding(.horizontal,10)
                }
                // The four source gamut buttons are now an on-demand
                // section of 拍摄, never a permanently tall global header.
                HStack(spacing:5) {
                    processTab(.camera)
                    processTab(.film)
                    if !isReversal { processTab(.paper) }
                    processTab(.scanner)
                }
                .padding(.horizontal,8)
                Divider().padding(.horizontal,8)
                if adjustmentDetailReady {
                    ScrollView(.vertical) {
                        processSettings
                            .padding(.horizontal,11)
                            .padding(.bottom,13)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }
                    .frame(maxHeight:.infinity)
                }
            }
        )
    }

    private var processSettings: AnyView {
        if isReversal && selectedProcessStage == .paper {
            return AnyView(processScannerSettings)
        }
        switch selectedProcessStage {
        case .camera: return AnyView(processCameraSettings)
        case .film: return AnyView(processFilmSettings)
        case .paper: return AnyView(processPaperSettings)
        case .scanner: return AnyView(processScannerSettings)
        }
    }

    private var processCameraSettings: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("拍摄阶段 · 光线进入胶片之前")
                .font(.caption).fontWeight(.semibold)
            if fullPhysicalMode {
                Picker("原版光谱重建",selection:$model.sourceCameraRawMethod) {
                    Text("Hanatos 2025 · 光谱 TC")
                        .tag(SpectralPhysics.CameraRawMethod.hanatos2025)
                    Text("Mallett 2019 · 81 波长")
                        .tag(SpectralPhysics.CameraRawMethod.mallett2019)
                }
                .pickerStyle(.menu)
                .onChange(of:model.sourceCameraRawMethod) { _ in
                    model.queueSpectralPreview()
                }
                Text("输入色域：" + (model.sourcePhysicalInputOklchEnabled
                    ? "Oklch Float64" : "经典 xy Float64"))
                    .font(.caption2).foregroundColor(.secondary)
                DisclosureGroup("原版色域路线 · Oklch / CAM16-UCS") {
                    sourceColorRouteControls
                }
                .font(.caption)
                resetToggle("测光与镜头处理",value:$model.sourceCameraPreFilmEnabled,
                            enabled:model.hasPhoto && !model.busy,resetTo:false)
                    .onChange(of:model.sourceCameraPreFilmEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                if model.sourceCameraPreFilmEnabled {
                    Picker("自动测光",selection:$model.sourceCameraMeteringMethod) {
                        ForEach(OriginalSourceCameraOptics.Metering.allCases,
                                id:\.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of:model.sourceCameraMeteringMethod) { _ in
                        model.queueSpectralPreview()
                    }
                    morphSlider("高光恢复 EV",value:$model.sourceCameraHighlightBoostEV,
                                range:0...5)
                    resetToggle("摄影柔化",value:$model.sourceCameraDiffusionEnabled,
                                enabled:model.hasPhoto && !model.busy,resetTo:false)
                        .onChange(of:model.sourceCameraDiffusionEnabled) { _ in
                            model.queueSpectralPreview()
                        }
                }
            } else {
                Text("快速冲印保留现有的相机曝光与色彩预处理，不会自动启用实验光谱算法。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if fullPhysicalMode {
                DisclosureGroup("光谱重建 · UV / IR 参数") {
                    sourceCameraSpectralSettings
                }
                .font(.caption)
                if model.sourceCameraPreFilmEnabled {
                    DisclosureGroup("高光恢复与摄影镜头参数") {
                        sourceCameraOpticsDetailSettings
                    }
                    .font(.caption)
                    if model.sourceCameraDiffusionEnabled {
                        DisclosureGroup("摄影扩散 · 原版 PSF 参数") {
                            sourceCameraDiffusionSettings
                        }
                        .font(.caption)
                    }
                }
            } else {
                simpleToggle("64位",value:$model.hanatosOriginalPrecisionEnabled) {
                    model.queueSpectralPreview()
                }
            }
            Text("参数直接控制当前拍摄处理阶段；原版精确与快速模式严格区分。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    private var processFilmSettings: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("胶片显影 · 乳剂密度与空间作用")
                .font(.caption).fontWeight(.semibold)
            resetToggle("胶片层间扩散",value:$model.spatialDIREnabled,
                        enabled:model.hasPhoto && !model.busy && !directPixelMode,
                        resetTo:true)
                .onChange(of:model.spatialDIREnabled) { _ in
                    model.queueSpectralPreview()
                }
            resetToggle("背反射光晕",value:$model.halationEnabled,
                        enabled:model.hasPhoto && !model.busy &&
                                (!directPixelMode || fullPhysicalMode),resetTo:false)
                .onChange(of:model.halationEnabled) { _ in onRefresh() }
            if !fullPhysicalMode && !directPixelMode {
                resetToggle("快速胶片散射",value:$model.scatterEnabled,
                            enabled:model.hasPhoto && !model.busy,resetTo:false)
                    .onChange(of:model.scatterEnabled) { _ in onRefresh() }
                resetToggle("快速胶片颗粒",value:$model.grainEnabled,
                            enabled:model.hasPhoto && !model.busy,resetTo:false)
                    .onChange(of:model.grainEnabled) { _ in
                        if model.grainEnabled {model.queueSpectralPreview()}
                        else {onRefresh()}
                    }
                if model.grainEnabled {
                    strengthControl("颗粒强度",value:$model.grainAmount,
                                    range:0...2,suffix:"×",resetTo:1)
                }
            }
            if fullPhysicalMode {
                resetToggle("原版三亚层颗粒",
                            value:$model.sourcePhysicalGrainEnabled,
                            enabled:model.hasPhoto && !model.busy,
                            resetTo:false)
                    .onChange(of:model.sourcePhysicalGrainEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                if model.sourcePhysicalGrainEnabled {
                    resetToggle("Numba 默认多线程 · 无固定种子",
                                value:$model.sourceGrainUseUnseededParallel,
                                enabled:model.hasPhoto && !model.busy,
                                resetTo:false)
                        .onChange(of:model.sourceGrainUseUnseededParallel) { _ in
                            model.queueSpectralPreview()
                        }
                    resetToggle("Numba fast_stats 粒子（原版可选）",
                                value:$model.sourceGrainFastStatsEnabled,
                                enabled:model.hasPhoto && !model.busy,
                                resetTo:false)
                        .onChange(of:model.sourceGrainFastStatsEnabled) { _ in
                            model.queueSpectralPreview()
                        }
                    Text(model.sourceGrainUseUnseededParallel
                         ? "实际多线程 RNG：OS 独立初态；每次冲印颗粒不同。原版随机分布测试中，不是 Python 无种子逐位重放。"
                         : "固定 seed=8888：原版单线程受控数值已通过；适合复现/逐像素对照。")
                        .font(.caption2).foregroundColor(.secondary)
                }
                resetToggle("乳剂散射与背反射联动",
                            value:$model.sourceFilmHalationEnabled,
                            enabled:model.hasPhoto && !model.busy,resetTo:false)
                    .onChange(of:model.sourceFilmHalationEnabled) { _ in
                        model.queueSpectralPreview()
                    }
            }
            if model.spatialDIREnabled {
                DisclosureGroup("层间扩散 · 原版 FIR/YVV 参数") {
                    processDIRDetailSettings
                }
                .font(.caption)
            }
            if model.halationEnabled {
                DisclosureGroup("背反射光晕 · 强度参数") {
                    halationSettings
                }
                .font(.caption)
            }
            if fullPhysicalMode {
                if model.sourceFilmHalationEnabled {
                    DisclosureGroup("乳剂散射＋背反射 · 专业参数") {
                        sourceFilmHalationDetailSettings
                    }
                    .font(.caption)
                }
                if model.sourcePhysicalGrainEnabled {
                    DisclosureGroup("三亚层颗粒 · 染料云与微结构参数") {
                        sourcePhysicalGrainSettings
                    }
                    .font(.caption)
                }
            } else if model.grainEnabled {
                DisclosureGroup("快速颗粒 · 专业参数") {
                    grainSettings
                    if model.grainSublayersEnabled {
                        if model.grainOriginalMetalEnabled {
                            simpleToggle("SciPy",
                                         value:$model.grainOriginalSciPyEnabled) {
                                onRefresh()
                            }
                        }
                        simpleToggle("Poisson",
                                     value:$model.grainDiscreteParticlesEnabled,
                                     allowed:!model.grainOriginalMetalEnabled) {
                            onRefresh()
                        }
                    }
                }
                .font(.caption)
            }
            Text("快速颗粒／原版固定种子／原版无种子多线程三条路线保持独立。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    private var processPaperSettings: some View {
        VStack(alignment:.leading,spacing:4) {
            Text("相纸印相 · 仅适用于彩色负片")
                .font(.caption).fontWeight(.semibold)
            if !isReversal {
                resetToggle("相纸显影曲线 s023",value:$model.printMorphEnabled,
                            enabled:model.hasPhoto && !model.busy && !fullPhysicalMode && !directPixelMode,
                            resetTo:false)
                    .onChange(of:model.printMorphEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                resetToggle("光学放大机",value:$model.originalPrintOpticsEnabled,
                            enabled:model.hasPhoto && !model.busy &&
                                    !fullPhysicalMode,resetTo:false)
                    .onChange(of:model.originalPrintOpticsEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                if model.originalPrintOpticsEnabled {
                    if !fullPhysicalMode && !directPixelMode {
                        resetToggle("印相曝光归一化",value:$model.normalizePrintExposure,
                                    enabled:model.hasPhoto && !model.busy,resetTo:true)
                            .onChange(of:model.normalizePrintExposure) { _ in model.queueSpectralPreview() }
                        resetToggle("印相曝光补偿",value:$model.printExposureCompensation,
                                    enabled:model.hasPhoto && !model.busy,resetTo:true)
                            .onChange(of:model.printExposureCompensation) { _ in model.queueSpectralPreview() }
                    }
                    DisclosureGroup("滤色片 · C / M / Y") {
                        VStack(alignment:.leading,spacing:4) {
                            morphSlider("青色 C / CC",value:$model.printCyanShift,
                                        range:-40...40)
                            morphSlider("洋红 M / CC",value:$model.printMagentaShift,
                                        range:-40...40)
                            morphSlider("黄色 Y / CC",value:$model.printYellowShift,
                                        range:-40...40)
                        }
                        .padding(.top,4)
                    }
                    .font(.caption)
                    exposureControl("相纸曝光",value:$model.printExposureEV,
                                    enabled:model.hasPhoto && !model.busy,
                                    onCommit:{model.queueSpectralPreview()})
                    resetToggle("预闪光",value:$model.preflashEnabled,
                                enabled:model.hasPhoto && !model.busy,resetTo:false)
                        .onChange(of:model.preflashEnabled) { _ in
                            model.queueSpectralPreview()
                        }
                    if model.preflashEnabled {
                        morphSlider("预闪强度",value:$model.preflashExposure,
                                    range:0...0.2)
                    }
                    if fullPhysicalMode {
                        resetToggle("印相柔化",value:$model.printSourceDiffusionEnabled,
                                    enabled:model.hasPhoto && !model.busy,
                                    resetTo:false)
                            .onChange(of:model.printSourceDiffusionEnabled) { _ in
                                model.queueSpectralPreview()
                            }
                    }
                }
                if model.printMorphEnabled {
                    DisclosureGroup("相纸 s023 · 显影曲线参数") {
                        morphologySettings
                    }
                    .font(.caption)
                }
                if model.originalPrintOpticsEnabled {
                    DisclosureGroup("放大机 · 光源与滤色数据库") {
                        enlargerSettings
                    }
                    .font(.caption)
                    if model.preflashEnabled {
                        DisclosureGroup("预闪光 · 曝光与 M / Y 滤色") {
                            preflashSettings
                        }
                        .font(.caption)
                    }
                    if fullPhysicalMode && model.printSourceDiffusionEnabled {
                        DisclosureGroup("印相扩散 · 原版 PSF 参数") {
                            sourcePrintDiffusionSettings
                        }
                        .font(.caption)
                    }
                }
                Text("CMY、放大机、预闪、乳剂曲线和印相扩散都在相纸阶段。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var processScannerSettings: some View {
        VStack(alignment:.leading,spacing:4) {
            Text(isReversal ? "反转片 → 直接扫描" : "相纸显影 → 扫描输出")
                .font(.caption).fontWeight(.semibold)
            resetToggle("光谱扫描",value:$model.originalScannerEnabled,
                        enabled:model.hasPhoto && !model.busy && !fullPhysicalMode,
                        resetTo:false)
                .onChange(of:model.originalScannerEnabled) { _ in
                    model.queueSpectralPreview()
                }
            if fullPhysicalMode {
                if !isReversal {
                    resetToggle("扫描眩光 · 受控单线程",
                                value:$model.sourceScannerGlareEnabled,
                                enabled:model.hasPhoto && !model.busy,
                                resetTo:false)
                        .onChange(of:model.sourceScannerGlareEnabled) { _ in
                            model.queueSpectralPreview()
                        }
                    if model.sourceScannerGlareEnabled {
                        Text("固定 seed=8888 · 单线程受控；无固定种子多线程仍未认证")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                Text("输出色域：" +
                     (model.sourcePhysicalCAM16DefaultGamutEnabled
                      ? "CAM16-UCS · 原版 Float64"
                      : "经典原版输出（非 CAM16 LUT）"))
                    .font(.caption2).foregroundColor(.secondary)
                resetToggle("扫描镜头与锐化",
                            value:$model.sourceScannerOpticalEnabled,
                            enabled:model.hasPhoto && !model.busy,resetTo:false)
                    .onChange(of:model.sourceScannerOpticalEnabled) { _ in
                        model.queueSpectralPreview()
                    }
                if model.sourceScannerOpticalEnabled {
                    morphSlider("扫描锐化强度",
                                value:$model.sourceScannerUnsharpAmount,
                                range:0...2,resetTo:0.7)
                }
            } else if !directPixelMode {
                if model.originalScannerEnabled {
                    resetToggle("黑白场校准",value:$model.scannerBlackWhiteEnabled,
                                enabled:model.hasPhoto && !model.busy,
                                resetTo:false)
                        .onChange(of:model.scannerBlackWhiteEnabled) { _ in model.queueSpectralPreview() }
                    if model.scannerBlackWhiteEnabled && !isReversal {
                        resetToggle("扫描曝光参考",value:$model.exposureReferenceEnabled,
                                    enabled:model.hasPhoto && !model.busy,resetTo:false)
                            .onChange(of:model.exposureReferenceEnabled) { _ in model.queueSpectralPreview() }
                    }
                    resetToggle("快速 CAM16 LUT（旧版扫描器）",
                                value:$model.scannerCAM16Enabled,
                                enabled:model.hasPhoto && !model.busy,
                                resetTo:false)
                        .onChange(of:model.scannerCAM16Enabled) { _ in
                            model.queueSpectralPreview()
                        }
                }
                resetToggle("扫描锐化",value:$model.scannerFinishingEnabled,
                            enabled:model.hasPhoto && !model.busy,resetTo:false)
                    .onChange(of:model.scannerFinishingEnabled) { _ in
                        onRefresh()
                    }
                if model.scannerFinishingEnabled {
                    strengthControl("锐化强度",value:$model.scannerSharpenAmount,
                                    range:0...1.5,suffix:"×",resetTo:0.7)
                }
            }
            if fullPhysicalMode {
                if model.sourceScannerGlareEnabled && !isReversal {
                    DisclosureGroup("原版扫描 XYZ 眩光参数") {
                        sourceScannerGlareSettings
                    }
                    .font(.caption)
                }
                if model.sourceScannerOpticalEnabled {
                    DisclosureGroup("原版扫描镜头与 Unsharp 参数") {
                        sourceScannerOpticalDetailSettings
                    }
                    .font(.caption)
                }
            }
            Text("精细 CAM16-UCS 请在「工艺 → 拍摄 → 原版色域路线」选择；扫描校准与光学参数在此管理。")
                .font(.caption2).foregroundColor(.secondary)
        }
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
                featureToggle("摄影扩散", feature: .cameraDiffusion,
                              value: $model.sourceCameraDiffusionEnabled,
                              allowed: fullPhysicalMode &&
                                       model.sourceCameraPreFilmEnabled) {
                    model.queueSpectralPreview()
                }
                featureToggle("印相扩散", feature: .printDiffusion,
                              value: $model.printSourceDiffusionEnabled,
                              allowed: fullPhysicalMode && !isReversal &&
                                       model.originalPrintOpticsEnabled) {
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
                if model.originalScannerEnabled && model.scannerBlackWhiteEnabled &&
                   !isReversal {
                    simpleToggle("曝光参考", value: $model.exposureReferenceEnabled) {
                        model.queueSpectralPreview()
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

    // Shared visible switch geometry across first, second and third menu
    // levels. Only the surrounding tap area differs by placement.
    // The native SwiftUI Toggle was taller and inconsistent on iOS 16.5.
    private enum MiniSwitchMetrics {
        static let trackWidth: CGFloat = 28
        static let trackHeight: CGFloat = 16
        static let thumbSize: CGFloat = 12
        static let thumbOffset: CGFloat = 6
        static let tapWidth: CGFloat = 42
        static let tapHeight: CGFloat = 32
    }

    private func miniatureSwitch(isOn: Bool) -> some View {
        ZStack {
            Capsule()
                .fill(isOn ? Color.accentColor : Color.gray.opacity(0.46))
                .frame(width: MiniSwitchMetrics.trackWidth,
                       height: MiniSwitchMetrics.trackHeight)
            Circle()
                .fill(.white)
                .frame(width: MiniSwitchMetrics.thumbSize,
                       height: MiniSwitchMetrics.thumbSize)
                .offset(x: isOn ? MiniSwitchMetrics.thumbOffset
                         : -MiniSwitchMetrics.thumbOffset)
        }
    }

    private func simpleToggle(_ title:String,value:Binding<Bool>,
                              allowed:Bool=true,resetTo:Bool=false,
                              changed:@escaping ()->Void)->some View {
        let confirmedLock=confirmedSimpleLock(title)
        let ready=model.hasPhoto && !model.busy && allowed &&
            confirmedLock == nil
        let reason=confirmedLock ?? (!allowed
            ? "当前颗粒模式的前置条件不支持独立开启此选项。请先在「工艺 → 胶片」调整颗粒路线。"
            : nil)
        let note=switchGuidance(
            title,isOn:value.wrappedValue,enabled:ready,
            explicitReason:reason
        )
        return VStack(alignment:.leading,spacing:2) {
            HStack(spacing:3) {
                Button {
                    guard ready else{return}
                    value.wrappedValue.toggle()
                    changed()
                } label: {
                    HStack(spacing:4) {
                        Text(title)
                            .font(.system(size:10,weight:.semibold))
                        miniatureSwitch(isOn:value.wrappedValue)
                    }
                    .padding(.horizontal,7)
                    .padding(.vertical,5)
                    .background(Color.primary.opacity(0.07),in:Capsule())
                }
                .buttonStyle(.plain)
                .onTapGesture(count: 2) {
                    guard ready else{return}
                    value.wrappedValue=resetTo
                    changed()
                }
                .disabled(!ready)
                .accessibilityLabel(title+(value.wrappedValue ? "，已开启" : "，已关闭"))
                if let note {
                    switchInfoButton(title,guidance:note)
                }
            }
            if let note {
                Text(note.summary)
                    .font(.system(size:10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
        }
    }

    // Top feature row and pure-switch second row. The parameter
    // region below exists only for an enabled selected feature.
    // Incident CF7DCF7C-9351-46BA-8B3D-8A712A99DC15, iOS 16.5.1:
    // The .ips traces 40+ recursive Swift generic metadata demangle frames
    // to adjustmentControls.getter, followed by STACK GUARD SIGSEGV.
    // Avoid a giant nested SwiftUI opaque type; each child is explicitly
    // type-erased BEFORE composing it with parent views.
    /// Build120: Advanced no longer hosts *any* image-changing switches.
    /// The old disconnected feature functions remain source-defined only
    /// as compatibility helpers; all visible controls are in 工艺 stages.
    private var advancedControls: AnyView {
        AnyView(
            ScrollView(.vertical) {
                VStack(alignment:.leading,spacing:12) {
                    Text("高级 · 验证与诊断")
                        .font(.headline)
                    Text("Build119：13MP 基础三亚层 SciPy／Numba 双路线真机实渲染已通过；RAW、ICC、其他全光学组合与 Python 整图数值仍待认证。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        statusReportPresented=true
                    } label: {
                        Label("查看验证状态与诊断报告",
                              systemImage:"checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                    Text("这里不改变任何拍摄、显影、印相或扫描参数。完整处理参数请到「工艺」的对应阶段展开。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal,11)
                .padding(.vertical,13)
                .frame(maxWidth:.infinity,alignment:.leading)
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
        case .cameraDiffusion:
            return model.sourceCameraDiffusionEnabled &&
                   fullPhysicalMode && model.sourceCameraPreFilmEnabled
                ? AnyView(sourceCameraDiffusionSettings)
                : AnyView(EmptyView())
        case .printDiffusion:
            return model.printSourceDiffusionEnabled &&
                   fullPhysicalMode && !isReversal &&
                   model.originalPrintOpticsEnabled
                ? AnyView(sourcePrintDiffusionSettings)
                : AnyView(EmptyView())
        case .grain:
            return model.grainEnabled
                ? AnyView(grainSettings) : AnyView(EmptyView())
        }
    }

    private var exposureSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.hanatosOriginalPrecisionEnabled
                 ? "原版双精度光谱响应 · 未近似存储"
                 : "移动快速 Float16 光谱响应 · 已量化")
                .font(.caption2).foregroundColor(.secondary)
            exposureControl("胶片曝光", value: $model.filmExposureEV, enabled: model.hasPhoto,
                            onCommit: { model.queueSpectralPreview() })
            if !isReversal {
                exposureControl("相纸曝光",
                                value:$model.printExposureEV,
                                enabled:model.hasPhoto && !model.busy,
                                onCommit:{model.queueSpectralPreview()})
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("效果强度").font(.caption)
                        .onTapGesture(count: 2) {
                            model.strength = 1.0
                            onRefresh()
                        }
                    Spacer(minLength: 0)
                    Button {
                        guard model.hasPhoto && model.lut != nil &&
                            !model.busy && !directPixelMode else {return}
                        // Show percent to the user while preserving the
                        // underlying exact normalized 0...1 Double.
                        presentPrecision(
                            title:"效果强度",value:Binding(
                                get:{model.strength*100},
                                set:{model.strength=$0/100}
                            ),range:0...100,increment:1,
                            resetTo:100,unit:"%",onCommit:onRefresh
                        )
                    } label: {
                        Text(String(format:"%.1f%%",model.strength*100))
                            .font(.caption2).monospacedDigit()
                            .frame(minWidth:49,minHeight:25,alignment:.trailing)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.hasPhoto || model.lut == nil ||
                              model.busy || directPixelMode)
                    .accessibilityLabel("效果强度，点击输入精确百分比")
                }
                CompactOpticalSlider(value:$model.strength,range:0...1,
                                     onCommit:onRefresh)
                    .frame(height:24)
                    .disabled(!model.hasPhoto || model.lut == nil ||
                              model.busy || directPixelMode)
                if directPixelMode {
                    Text("原版像素通道固定 100% 强度；不允许混合近似 LUT。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Divider()
            Text("点右侧数值精确输入 · 双击左侧名称复原")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
    }

    private var scannerSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.originalScannerEnabled {
                Text(model.scannerCAM16Enabled
                     ? "快速 CAM16 LUT · 查表插值"
                     : "快速 ACES RGC · 非原版 Float64 CAM16-UCS")
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
        VStack(alignment: .leading, spacing: 4) {
            if model.scannerFinishingEnabled {
                strengthControl("锐化强度",
                                value: $model.scannerSharpenAmount,
                                range: 0...1.5, suffix: "×", resetTo: 0.7)
            }
        }
    }

    private var enlargerSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.originalPrintOpticsEnabled && !isReversal {
                Picker("放大机原版光源", selection: $model.printIlluminant) {
                    Text("TH-KG3（默认）")
                        .tag(OriginalPrintOptics.Illuminant.thKG3)
                    Text("TH-KG3-L（原版镜头透射谱）")
                        .tag(OriginalPrintOptics.Illuminant.thKG3L)
                }
                .pickerStyle(.menu)
                .onChange(of: model.printIlluminant) { _ in
                    model.queueSpectralPreview()
                }
                simpleToggle(
                    "原版中性滤镜数据库（关＝原版默认 C0/M65/Y55）",
                    value:$model.neutralPrintFiltersFromDatabase,
                    resetTo:true
                ) {
                    model.queueSpectralPreview()
                }
                Text("胶片 → 二色滤色光谱 → 相纸曝光")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("C / M / Y 滤色片：工艺 → 相纸；此处保留光源与原版数据库参数。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var preflashSettings: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        VStack(alignment: .leading, spacing: 4) {
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
        VStack(alignment: .leading, spacing: 4) {
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
        VStack(alignment: .leading, spacing: 4) {
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
                                     "UV/IR 和摄影扩散已提供独立原版入口；" +
                                     "光晕在下方原版模块。")
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
                            // Separate type-erased view: full physical
                            // source XYZ random glare is controlled only;
                            // never activate unseeded production prange.
                            sourceScannerGlareSettings
                            Text("原版输入 Oklch / CAM16-UCS 已统一移至「工艺 → 原版色域路线」。" +
                                 "当前：" + currentSourceColorRoute.label +
                                 "；仅原版 Float64 受控真机通过，Python 整图未认证。")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            sourcePhysicalGrainSettings
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
                             "原版光学源上限 1300 万像素；实际是否允许导出，" +
                             "按这台手机当前物理内存和 App 可用余量逐次检查。" +
                             "整图 Double FIR/YVV 与相纸显影均保留，不缩图；" +
                             "需开启原版 ACES 扫描、Hanatos Float64、" +
                             "负片原版放大机，关闭 CAM16/黑白参考。" +
                             "三亚层有固定种子单线程和无固定种子多线程两条独立路径；" +
                             "后者需 Build115 真机统计，RAW 全链仍未认证。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text(model.sourcePhysicalDirectEnabled
                         ? "逐像素全光学支持上方原版 Double 乳剂散射／光晕。" +
                           "原版三亚层受控颗粒独立可选，旧版 CI 扫描后处理不支持；不静默降级。"
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
    /// Dedicated erased source-physical camera diffusion editor.
    /// All original parameters are adjustable; no CI bloom surrogate.
    /// Parent controls require explicit source camera and full physical mode.
    /// Strict source-only enlarger diffusion editor, not an RGB
    /// postprocessing bloom. AnyView prevents recurrence of iOS 16.5.1
    /// generic metadata stack overflow seen in v1.8.36.
    /// Python source glare.py: original lognormal + 2D reflect FIR/YVV
    /// is applied to real paper XYZ before RGB/ACES. This is a seeded
    /// one-worker experiment, not default unseeded Numba equivalence.
    /// Keep a separate erased view to avoid iOS 16.5.1 generic stacks.
    /// Batch v1.8.48: 3 measured emulsion sublayers × CMY in ORIGINAL
    /// film optical density before enlarger/scanner, not mobile post-RGB.
    /// Separate AnyView keeps the iOS16 adjustment tree compact.
    /// Build120: owned only by the matching "工艺" stage. These
    /// parameter views reuse the same model bindings/defaults; no engine
    /// changes and no duplicate user-facing owner in Advanced.
    private var sourceCameraOpticsDetailSettings: AnyView {
        AnyView(VStack(alignment:.leading,spacing:4) {
            if model.sourceCameraPreFilmEnabled && fullPhysicalMode {
                morphSlider("高光恢复范围",
                            value:$model.sourceCameraHighlightBoostRange,
                            range:0...1,resetTo:0.3)
                morphSlider("高光保护 EV",
                            value:$model.sourceCameraHighlightProtectEV,
                            range:0...8,resetTo:4)
                morphSlider("原版摄影镜头模糊 μm",
                            value:$model.sourceCameraLensBlurUM,
                            range:0...80,resetTo:0)
            }
        })
    }

    private var processDIRDetailSettings: AnyView {
        AnyView(VStack(alignment:.leading,spacing:4) {
            resetToggle("DIR 原版 FIR/YVV",
                        value:$model.spatialDIRSourceConvolutionEnabled,
                        enabled:model.hasPhoto && !model.busy && !directPixelMode,
                        resetTo:true)
                .onChange(of:model.spatialDIRSourceConvolutionEnabled) { _ in
                    model.queueSpectralPreview()
                }
            strengthControl("抑制剂扩散范围",
                            value:$model.spatialDIRRadiusScale,
                            range:0.25...3.0,suffix:"×",resetTo:1.0)
            Text("层间扩散使用原版 reflect FIR/YVV；快速模式保留独立 CI 路线。")
                .font(.caption2).foregroundColor(.secondary)
        })
    }

    private var sourceFilmHalationDetailSettings: AnyView {
        AnyView(VStack(alignment:.leading,spacing:4) {
            if fullPhysicalMode && model.sourceFilmHalationEnabled {
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
            }
        })
    }

    private var sourceScannerOpticalDetailSettings: AnyView {
        AnyView(VStack(alignment:.leading,spacing:4) {
            if fullPhysicalMode && model.sourceScannerOpticalEnabled {
                morphSlider("源扫描镜头模糊 σ / px",
                            value:$model.sourceScannerLensBlurSigma,
                            range:0...8,resetTo:0)
                morphSlider("源扫描 Unsharp σ / px",
                            value:$model.sourceScannerUnsharpSigma,
                            range:0...8,resetTo:1)
                morphSlider("源扫描 Unsharp 强度",
                            value:$model.sourceScannerUnsharpAmount,
                            range:0...2,resetTo:0.7)
            }
        })
    }

    private var sourcePhysicalGrainSettings: AnyView {
        AnyView(
            VStack(alignment:.leading,spacing:4) {
                Text("三亚层颗粒 · 以下为原版染料云及微结构参数，保持原始值范围与默认值。")
                    .font(.caption2).foregroundColor(.secondary)
                if model.sourcePhysicalGrainEnabled {
                    morphSlider("原版末端颗粒模糊 σ / px",
                                value:$model.sourcePhysicalGrainBlur,
                                range:0...3,resetTo:0.65)
                    morphSlider("原版染料云模糊（源码原样参数）",
                                value:$model.sourcePhysicalGrainDyeCloudBlur,
                                range:0...3,resetTo:1)
                    morphSlider("微结构团簇模糊 μm",
                                value:$model.sourcePhysicalGrainMicroUM,
                                range:0...2,resetTo:0.2)
                    morphSlider("微结构波动 nm",
                                value:$model.sourcePhysicalGrainMicroNM,
                                range:0...150,resetTo:30)
                }
                Text("原版 grain.py：实测 3×3 CMY 亚层→逐层完整图 SciPy" +
                     " Poisson→Binomial 固定种子(ch+sl×10)→染料云 reflect" +
                     " FIR/YVV→Numba 单线程微结构→末端 Double FIR/YVV。" +
                     "真实胶片密度阶段接入，随后才印相或扫描。" +
                     " microstructure 固定 seed=8888；多线程 prange" +
                     " 未认证，旧版 Metal 近似颗粒仍为独立模式。" +
                     "全分辨率严格检查额外内存，失败不会缩图或使用 RGB 噪声。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        )
    }

    private var sourceScannerGlareSettings: AnyView {
        AnyView(
            VStack(alignment:.leading,spacing:4) {
                Text("扫描 XYZ 眩光 · 参数直接作用于原版扫描阶段，非快速模式 RGB 后期。")
                    .font(.caption2).foregroundColor(.secondary)
                if model.sourceScannerGlareEnabled {
                    morphSlider("原版扫描眩光百分比 %",
                                value:$model.sourceScannerGlarePercent,
                                range:0...0.3,resetTo:0.03)
                    morphSlider("原版眩光 roughness",
                                value:$model.sourceScannerGlareRoughness,
                                range:0...3,resetTo:0.7)
                    morphSlider("原版眩光模糊 σ / px",
                                value:$model.sourceScannerGlareBlur,
                                range:0...8,resetTo:0.5)
                }
                Text("原版扫描眩光严格在相纸光谱 XYZ 后、" +
                     "XYZ→RGB/ACES 前叠加；随后才执行原版扫描镜头和 sRGB。" +
                     "仅负片、原版逐像素全光学可用。显式固定单线程" +
                     " seed=8888，关闭时保持原图。尚未认证原版无固定" +
                     "种子的 Numba prange 多线程 RNG；不能冒充完整精确模式。" +
                     "独立计算并检查 Float64 内存，不经旧版 CI 哈希眩光。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        )
    }

    private var sourcePrintDiffusionSettings: AnyView {
        AnyView(
            VStack(alignment:.leading,spacing:4) {
                Text("原版印相扩散｜相纸曝光光子域 Double")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Picker("印相扩散滤镜族",selection:$model.printSourceDiffusionFamily) {
                    Text("Glimmerglass")
                        .tag(OriginalSourceDiffusion.Family.glimmerglass)
                    Text("Black Pro-Mist")
                        .tag(OriginalSourceDiffusion.Family.blackProMist)
                    Text("Pro-Mist")
                        .tag(OriginalSourceDiffusion.Family.proMist)
                    Text("CineBloom")
                        .tag(OriginalSourceDiffusion.Family.cinebloom)
                }
                .pickerStyle(.menu)
                .onChange(of:model.printSourceDiffusionFamily) { _ in
                    model.queueSpectralPreview()
                }
                morphSlider("印相扩散强度",
                            value:$model.printSourceDiffusionStrength,
                            range:0...2,resetTo:0.5)
                morphSlider("印相扩散空间倍率",
                            value:$model.printSourceDiffusionSpatialScale,
                            range:0...3,resetTo:1)
                morphSlider("印相外圈色晕暖度",
                            value:$model.printSourceDiffusionWarmth,
                            range:-1.5...1.5,resetTo:0)
                Text("六个 PSF 权重/尺寸倍率均使用 Python 原版默认 1。")
                    .font(.caption2).foregroundColor(.secondary)
                morphSlider("中心权重",
                            value:$model.printSourceDiffusionCoreIntensity,
                            range:0...4,resetTo:1)
                morphSlider("中心尺寸",
                            value:$model.printSourceDiffusionCoreSize,
                            range:0.1...4,resetTo:1)
                morphSlider("晕光权重",
                            value:$model.printSourceDiffusionHaloIntensity,
                            range:0...4,resetTo:1)
                morphSlider("晕光尺寸",
                            value:$model.printSourceDiffusionHaloSize,
                            range:0.1...4,resetTo:1)
                morphSlider("Bloom 权重",
                            value:$model.printSourceDiffusionBloomIntensity,
                            range:0...4,resetTo:1)
                morphSlider("Bloom 尺寸",
                            value:$model.printSourceDiffusionBloomSize,
                            range:0.1...4,resetTo:1)
                Text("源顺序：负片密度→相纸原版光谱 RAW + 预闪光/" +
                     "放大机曝光→整图 Double 反射边界 FFT PSF →" +
                     "log10 相纸曝光→拟合 H-D→原版 XYZ/ACES 扫描。" +
                     "不足内存时报错，不允许改用扫描后 Core Image 柔焦。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(.vertical,4)
        )
    }

    private var sourceCameraDiffusionSettings: AnyView {
        AnyView(
            VStack(alignment:.leading,spacing:4) {
                Text("摄影扩散原版 Double｜PSF + reflect FFT")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Picker("原版滤镜族",selection:$model.sourceCameraDiffusionFamily) {
                    Text("Glimmerglass").tag(OriginalSourceDiffusion.Family.glimmerglass)
                    Text("Black Pro-Mist").tag(OriginalSourceDiffusion.Family.blackProMist)
                    Text("Pro-Mist").tag(OriginalSourceDiffusion.Family.proMist)
                    Text("CineBloom").tag(OriginalSourceDiffusion.Family.cinebloom)
                }
                .pickerStyle(.menu)
                .onChange(of:model.sourceCameraDiffusionFamily) { _ in
                    model.queueSpectralPreview()
                }
                morphSlider("扩散强度（滤镜档位）",
                            value:$model.sourceCameraDiffusionStrength,
                            range:0...2,resetTo:0.5)
                morphSlider("光学空间倍率",
                            value:$model.sourceCameraDiffusionSpatialScale,
                            range:0...3,resetTo:1)
                morphSlider("外圈色晕暖度",
                            value:$model.sourceCameraDiffusionWarmth,
                            range:-1.5...1.5,resetTo:0)
                Text("以下六项为原版每组 PSF 权重和尺寸倍率（默认均为 1）。")
                    .font(.caption2).foregroundColor(.secondary)
                morphSlider("中心权重",
                            value:$model.sourceCameraDiffusionCoreIntensity,
                            range:0...4,resetTo:1)
                morphSlider("中心尺寸",
                            value:$model.sourceCameraDiffusionCoreSize,
                            range:0.1...4,resetTo:1)
                morphSlider("晕光权重",
                            value:$model.sourceCameraDiffusionHaloIntensity,
                            range:0...4,resetTo:1)
                morphSlider("晕光尺寸",
                            value:$model.sourceCameraDiffusionHaloSize,
                            range:0.1...4,resetTo:1)
                morphSlider("Bloom 权重",
                            value:$model.sourceCameraDiffusionBloomIntensity,
                            range:0...4,resetTo:1)
                morphSlider("Bloom 尺寸",
                            value:$model.sourceCameraDiffusionBloomSize,
                            range:0.1...4,resetTo:1)
                Text("Python 顺序：光谱 RAW→高光恢复→摄影 PSF 扩散→" +
                     "镜头 FIR/YVV→乳剂散射与光晕→胶片 H-D。" +
                     "大尺寸需要整图 Float64 FFT 内存；不足时明确报错，" +
                     "不会截断原版 PSF 或静默换成 Core Image。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(.vertical,4)
        )
    }

    private var sourceCameraSpectralSettings: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 4) {
                Text("光谱重建在「工艺 → 拍摄」上方选择；此面板直接调整 UV／IR 与 Hanatos 源码参数。")
                    .font(.caption2).foregroundColor(.secondary)
                Text("Hanatos 原版 81 波长 TC 光谱重算支持 UV/IR；" +
                     "滤镜变更立即重算，并同时应用原版感光度窗口、" +
                     "四阶表面校正和输入 xy 色域压缩；不可读取原 LUT 代替。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if model.sourceCameraRawMethod == .hanatos2025 {
                    resetToggle("原版 Hanatos 适应曲面与 TC 全重算",
                                value: $model.sourceHanatosFullRecompute,
                                enabled: model.hasPhoto && !model.busy,
                                resetTo: false)
                        .onChange(of: model.sourceHanatosFullRecompute) { _ in
                            model.queueSpectralPreview()
                        }
                }
                if model.sourceCameraRawMethod == .mallett2019 ||
                   model.sourceCameraRawMethod == .hanatos2025 {
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
        VStack(alignment: .leading, spacing: 4) {
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

    // Third-level switches share the second-level 28×16 visible track.
    // Preserve one-tap switch change and double-tap LABEL reset (never
    // attach competing gestures to the actual switch on iOS 16.5.1).
    private func resetToggle(_ title: String, value: Binding<Bool>,
                             enabled: Bool, resetTo: Bool = false) -> some View {
        let note=switchGuidance(title,isOn:value.wrappedValue,enabled:enabled)
        return VStack(alignment:.leading,spacing:2) {
            HStack(spacing:5) {
                Text(title)
                    .font(.caption2)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard enabled else{return}
                        value.wrappedValue=resetTo
                    }
                    .accessibilityHint("双击标签恢复该模块默认状态")
                Button {
                    guard enabled else{return}
                    value.wrappedValue.toggle()
                } label: {
                    miniatureSwitch(isOn:value.wrappedValue)
                        .frame(width:MiniSwitchMetrics.tapWidth,
                               height:MiniSwitchMetrics.tapHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(title+(value.wrappedValue ? "，已开启" : "，已关闭"))
                .accessibilityHint("单击切换；双击左侧名称恢复默认")
                if let note {
                    switchInfoButton(title,guidance:note)
                }
            }
            if let note {
                Text(note.summary)
                    .font(.system(size:10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal:false,vertical:true)
                    .accessibilityLabel(note.summary)
            }
        }
    }

    private func exposureControl(_ title:String,value:Binding<Double>,
                                 enabled:Bool,
                                 onCommit:@escaping()->Void)->some View {
        VStack(alignment:.leading,spacing:1) {
            HStack(spacing:4) {
                Text(title).font(.caption2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard enabled && !model.busy else{return}
                        value.wrappedValue=0
                        onCommit()
                    }
                Spacer(minLength:0)
                Button {
                    guard enabled && !model.busy else{return}
                    presentPrecision(
                        title:title,value:value,range:-2...2,
                        increment:0.01,resetTo:0,unit:"EV",
                        onCommit:onCommit
                    )
                } label: {
                    Text(String(format:"%+.2f EV",value.wrappedValue))
                        .font(.caption2).monospacedDigit()
                        .frame(minWidth:66,minHeight:25,alignment:.trailing)
                }
                .buttonStyle(.plain)
                .disabled(!enabled || model.busy)
                .accessibilityLabel(title+"，点击输入精确曝光 EV")
            }
            CompactOpticalSlider(value:value,range:-2...2,onCommit:onCommit)
                .frame(height:24)
                .disabled(!enabled || model.busy)
        }
    }

    private func morphSlider(_ title:String,value:Binding<Double>,
                             range:ClosedRange<Double>,
                             resetTo:Double=0)->some View {
        let increment:Double = (range.upperBound-range.lowerBound)>100
            ? 0.1 : 0.01
        return VStack(alignment:.leading,spacing:1) {
            HStack(spacing:4) {
                Text(title).font(.caption2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard model.hasPhoto && !model.busy else{return}
                        value.wrappedValue=resetTo
                        model.queueSpectralPreview()
                    }
                Spacer(minLength:0)
                Button {
                    presentPrecision(
                        title:title,value:value,range:range,
                        increment:increment,resetTo:resetTo,
                        onCommit:{model.queueSpectralPreview()}
                    )
                } label: {
                    Text(String(format:"%.4f",value.wrappedValue))
                        .font(.caption2).monospacedDigit()
                        .frame(minWidth:61,minHeight:25,alignment:.trailing)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasPhoto || model.busy)
                .accessibilityLabel(title+"，点击可输入精确小数")
            }
            CompactOpticalSlider(value:value,range:range,
                onCommit:{model.queueSpectralPreview()})
                .frame(height:24)
                .disabled(!model.hasPhoto || model.busy)
        }
    }

    private func strengthControl(_ title:String,value:Binding<Double>,
                                 range:ClosedRange<Double>,suffix:String,
                                 resetTo:Double)->some View {
        VStack(alignment:.leading,spacing:1) {
            HStack(spacing:4) {
                Text(title).font(.caption2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard model.hasPhoto && !model.busy else{return}
                        value.wrappedValue=resetTo
                        onRefresh()
                    }
                Spacer(minLength:0)
                Button {
                    presentPrecision(
                        title:title,value:value,range:range,
                        increment:0.01,resetTo:resetTo,unit:suffix,
                        onCommit:onRefresh
                    )
                } label: {
                    Text(String(format:"%.3f",value.wrappedValue)+suffix)
                        .font(.caption2).monospacedDigit()
                        .frame(minWidth:61,minHeight:25,alignment:.trailing)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasPhoto || model.busy)
                .accessibilityLabel(title+"，点击输入精确小数")
            }
            CompactOpticalSlider(value:value,range:range,onCommit:onRefresh)
                .frame(height:24)
                .disabled(!model.hasPhoto || model.busy)
        }
    }

}


/// Build122: compact native slider, 12-point knob and 3-point visual rail.
/// Enlarged transparent hit testing remains independent from the tiny thumb.
/// All render callbacks occur once on release; direct numeric entry stores
/// the Double untouched by UISlider's display-only Float precision.
private final class CompactOpticalUISlider:UISlider {
    override func point(inside point:CGPoint,with event:UIEvent?)->Bool {
        bounds.insetBy(dx:-8,dy:-10).contains(point)
    }
}
private struct CompactOpticalSlider:UIViewRepresentable {
    @Binding var value:Double
    let range:ClosedRange<Double>
    let onCommit:()->Void
    private static let smallThumb:UIImage = {
        let render=UIGraphicsImageRenderer(size:CGSize(width:12,height:12))
        return render.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.cgContext.fillEllipse(in:CGRect(x:0.5,y:0.5,width:11,height:11))
        }
    }()
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeUIView(context:Context)->CompactOpticalUISlider {
        let slider=CompactOpticalUISlider()
        slider.minimumTrackTintColor = .systemBlue
        slider.maximumTrackTintColor = .tertiaryLabel
        slider.setThumbImage(Self.smallThumb,for:.normal)
        slider.setThumbImage(Self.smallThumb,for:.highlighted)
        slider.isContinuous=true
        slider.addTarget(context.coordinator,
                         action:#selector(Coordinator.moved(_:)),for:.valueChanged)
        slider.addTarget(context.coordinator,
                         action:#selector(Coordinator.finished(_:)),
                         for:[.touchUpInside,.touchUpOutside,.touchCancel])
        return slider
    }
    func updateUIView(_ uiView:CompactOpticalUISlider,context:Context) {
        context.coordinator.parent=self
        uiView.minimumValue=Float(range.lowerBound)
        uiView.maximumValue=Float(range.upperBound)
        let clamped=Float(min(range.upperBound,max(range.lowerBound,value)))
        if !uiView.isTracking || abs(uiView.value-clamped)>0.00001 {
            uiView.value=clamped
        }
    }
    final class Coordinator:NSObject {
        var parent:CompactOpticalSlider
        init(_ parent:CompactOpticalSlider) {self.parent=parent}
        @objc func moved(_ slider:UISlider) {
            parent.value=Double(slider.value)
        }
        @objc func finished(_ slider:UISlider) {
            parent.onCommit()
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
