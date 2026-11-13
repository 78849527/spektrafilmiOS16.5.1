import AVFoundation
import ImageIO
import NextLevel
import SwiftUI
import UIKit

/// A source JPEG/HEIC companion and an optional sensor Bayer DNG are NEVER
/// merged or confused. The current optical processor receives only processed
/// input; RAW file bytes remain unmodified for later source RAW development.
struct NextLevelCapturedPhoto {
    let processed: Data
    let rawDNG: Data?
    let format: String
}

private enum CaptureFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case heic = "HEIC"
    case raw = "RAW DNG + JPEG"
    var id: String { rawValue }
}

private enum CaptureLens: String, CaseIterable, Identifiable {
    case ultra = "0.5× 超广角"
    case wide = "1× 主摄"
    case tele = "长焦"
    case front = "前置"
    var id: String { rawValue }
    var deviceType: NextLevelDeviceType {
        switch self {
        case .ultra: return .ultraWideAngleCamera
        case .wide, .front: return .wideAngleCamera
        case .tele: return .telephotoCamera
        }
    }
    var position: AVCaptureDevice.Position { self == .front ? .front : .back }
}

struct NextLevelCameraScreen: View {
    let onCancel: () -> Void
    let onCapture: (NextLevelCapturedPhoto) -> Void
    @StateObject private var camera = NextLevelCameraController()
    @State private var showPro = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NextLevelCameraPreview(onFocus: { point in
                camera.focus(at: point)
            })
            .ignoresSafeArea()

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .frame(width: 42, height: 42)
                    }
                    Spacer()
                    Text("SpektraFilm · NextLevel")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        camera.cycleFlash()
                    } label: {
                        Image(systemName: camera.flashMode == 0
                            ? "bolt.slash" : camera.flashMode == 1
                            ? "bolt.fill" : "bolt.badge.a")
                            .frame(width: 42, height: 42)
                    }
                    .disabled(!camera.ready || !camera.flashAvailable)
                    .accessibilityLabel("闪光灯：关闭／开启／自动")
                }
                .padding(.horizontal, 12)
                .background(.black.opacity(0.35))

                HStack(spacing: 10) {
                    Menu {
                        ForEach(CaptureFormat.allCases) { f in
                            Button(f.rawValue) { camera.setFormat(f) }
                                .disabled(camera.capturing || (f == .raw && !camera.rawAvailable))
                        }
                    } label: {
                        Text(camera.captureFormat.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                    .accessibilityLabel("拍摄格式")

                    Menu {
                        ForEach(CaptureLens.allCases) { lens in
                            Button(lens.rawValue) { camera.selectLens(lens) }
                                .disabled(!camera.availableLenses.contains(lens) || camera.capturing)
                        }
                    } label: {
                        Text(camera.selectedLens.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                    .accessibilityLabel("选择摄像头镜头")
                    Spacer()
                    Button { showPro.toggle() } label: {
                        Text(showPro ? "收起参数" : "专业参数")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(8)
                            .background(.black.opacity(0.65), in: Capsule())
                    }
                    .disabled(!camera.ready)
                }
                .padding(.horizontal, 12)

                Spacer()

                if showPro {
                    proPanel
                        .padding(.horizontal, 12)
                }

                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text(String(format: "%.1f×", camera.zoom))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 40)
                        Slider(value: $camera.zoom, in: camera.zoomRange)
                            .onChange(of: camera.zoom) { new in
                                camera.setZoom(new)
                            }
                            .disabled(!camera.ready || camera.capturing)
                    }
                    Text(camera.ready
                        ? "拍照后直接冲印 · RAW 原片另存 DNG"
                        : "正在启动相机…")
                        .font(.caption2)
                        .lineLimit(2)
                    HStack(alignment: .center) {
                        Text(camera.rawAvailable ? "RAW 可用" : "此镜头无 RAW")
                            .font(.caption2)
                            .frame(width: 80)
                        Spacer()
                        Button { camera.capture() } label: {
                            Circle()
                                .strokeBorder(.white, lineWidth: 5)
                                .background(Circle().fill(camera.capturing
                                    ? Color.gray : Color.white).padding(7))
                                .frame(width: 74, height: 74)
                        }
                        .disabled(!camera.ready || camera.capturing)
                        .accessibilityLabel("拍照并冲印")
                        Spacer()
                        Button {
                            camera.selectLens(camera.selectedLens == .front
                                ? .wide : .front)
                        } label: {
                            Image(systemName: "camera.rotate")
                                .font(.system(size: 23))
                                .frame(width: 80, height: 55)
                        }
                        .disabled(!camera.ready || camera.capturing)
                        .accessibilityLabel("前后摄像头切换")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 17)
                .background(.black.opacity(0.5))
            }
            .foregroundColor(.white)
        }
        .onAppear {
            camera.onCapture = onCapture
            camera.start()
        }
        .onDisappear { camera.stop() }
        .alert("相机提示", isPresented: Binding(
            get: { camera.errorMessage != nil },
            set: { if !$0 { camera.errorMessage = nil } }
        )) {
            Button("确定", role: .cancel) { camera.errorMessage = nil }
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }

    private var proPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("专业拍摄").font(.caption.weight(.bold))
                Spacer()
                Toggle("手动曝光", isOn: $camera.manualExposure)
                    .labelsHidden()
                    .onChange(of: camera.manualExposure) { camera.changeExposureMode($0) }
                Text("M").font(.caption)
            }
            if camera.manualExposure {
                HStack {
                    Text("ISO \(Int(camera.iso))")
                        .frame(width: 78, alignment: .leading)
                    Slider(value: $camera.iso, in: camera.isoRange)
                        .onChange(of: camera.iso) { _ in camera.updateManualExposure() }
                }
                HStack {
                    Text(String(format: "快门 1/%.0f", 1.0 / pow(2.0, camera.shutterLog2)))
                        .frame(width: 100, alignment: .leading)
                    Slider(value: $camera.shutterLog2, in: camera.shutterRange)
                        .onChange(of: camera.shutterLog2) { _ in camera.updateManualExposure() }
                }
            } else {
                HStack {
                    Text(String(format: "曝光 %+.1f EV", camera.exposureBias))
                        .frame(width: 105, alignment: .leading)
                    Slider(value: $camera.exposureBias, in: camera.exposureBiasRange)
                        .onChange(of: camera.exposureBias) { camera.setExposureBias($0) }
                }
            }
            HStack {
                Toggle("手动对焦", isOn: $camera.manualFocus)
                    .onChange(of: camera.manualFocus) { camera.changeFocusMode($0) }
                    .font(.caption)
                if camera.manualFocus {
                    Slider(value: $camera.focusPosition, in: 0...1)
                        .onChange(of: camera.focusPosition) {
                            camera.updateManualFocus($0)
                        }
                }
            }
            HStack {
                Toggle("手动白平衡", isOn: $camera.manualWhiteBalance)
                    .onChange(of: camera.manualWhiteBalance) {
                        camera.changeWhiteBalanceMode($0)
                    }
                    .font(.caption)
                if camera.manualWhiteBalance {
                    Text("\(Int(camera.temperature)) K").font(.caption)
                }
            }
            if camera.manualWhiteBalance {
                Slider(value: $camera.temperature, in: 2500...10000)
                    .onChange(of: camera.temperature) { _ in camera.updateWhiteBalance() }
                HStack {
                    Text(String(format: "色调 %+.0f", camera.tint)).font(.caption)
                    Slider(value: $camera.tint, in: -150...150)
                        .onChange(of: camera.tint) { _ in camera.updateWhiteBalance() }
                }
            }
            Text("点按画面自动对焦/测光；手动模式下不自动覆盖参数。")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.78))
        }
        .font(.system(size: 12))
        .padding(10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .disabled(camera.capturing || !camera.ready)
    }
}

/// Touchable preview layer with capture-device coordinate mapping.
private final class NextLevelPreviewSurface: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        NextLevel.shared.previewLayer.frame = bounds
    }
}
private struct NextLevelCameraPreview: UIViewRepresentable {
    var onFocus: (CGPoint) -> Void
    final class Coordinator: NSObject {
        var onFocus: (CGPoint) -> Void
        init(_ onFocus: @escaping (CGPoint) -> Void) { self.onFocus = onFocus }
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            let cameraPoint = NextLevel.shared.previewLayer
                .captureDevicePointConverted(fromLayerPoint: point)
            onFocus(cameraPoint)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onFocus) }
    func makeUIView(context: Context) -> NextLevelPreviewSurface {
        let v = NextLevelPreviewSurface()
        v.backgroundColor = .black
        let preview = NextLevel.shared.previewLayer
        preview.videoGravity = .resizeAspectFill
        preview.removeFromSuperlayer()
        v.layer.addSublayer(preview)
        v.addGestureRecognizer(UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.tapped(_:))
        ))
        return v
    }
    func updateUIView(_ v: NextLevelPreviewSurface, context: Context) {
        context.coordinator.onFocus = onFocus
        v.setNeedsLayout()
    }
    static func dismantleUIView(_ v: NextLevelPreviewSurface, coordinator: Coordinator) {
        if NextLevel.shared.previewLayer.superlayer === v.layer {
            NextLevel.shared.previewLayer.removeFromSuperlayer()
        }
    }
}

private final class NextLevelCameraController: NSObject,
    ObservableObject, NextLevelDelegate, NextLevelPhotoDelegate {
    @Published private(set) var ready = false
    @Published private(set) var capturing = false
    @Published private(set) var rawAvailable = false
    @Published private(set) var flashAvailable = false
    @Published private(set) var flashMode = 0
    @Published private(set) var captureFormat: CaptureFormat = .jpeg
    @Published private(set) var selectedLens: CaptureLens = .wide
    @Published private(set) var availableLenses: Set<CaptureLens> = [.wide, .front]
    @Published var zoom = 1.0
    @Published var zoomRange: ClosedRange<Double> = 1...8
    @Published var iso = 100.0
    @Published var isoRange: ClosedRange<Double> = 25...800
    @Published var shutterLog2 = -7.0
    @Published var shutterRange: ClosedRange<Double> = -12...0
    @Published var exposureBias = 0.0
    @Published var exposureBiasRange: ClosedRange<Double> = -2...2
    @Published var focusPosition = 0.5
    @Published var temperature = 5500.0
    @Published var tint = 0.0
    @Published var manualExposure = false
    @Published var manualFocus = false
    @Published var manualWhiteBalance = false
    @Published var errorMessage: String?

    var onCapture: ((NextLevelCapturedPhoto) -> Void)?
    private let engine = NextLevel.shared
    private var active = false
    private var pendingProcessed: Data?
    private var pendingRAW: Data?
    private var captureExpectedRAW = false
    private var captureFormatLabel = "JPEG"

    func start() {
        guard !active else { return }
        active = true
        availableLenses = Set(CaptureLens.allCases.filter { lens in
            AVCaptureDevice.default(lens.deviceType, for: .video,
                                    position: lens.position) != nil
        })
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self, self.active else { return }
                    if granted { self.configure() }
                    else { self.errorMessage = "未获得相机权限，请在系统设置中授权。" }
                }
            }
        case .denied, .restricted:
            errorMessage = "相机访问受限，请检查 iOS 设置中的相机权限。"
        @unknown default:
            errorMessage = "无法读取当前相机权限。"
        }
    }

    private func configure() {
        guard active else { return }
        engine.delegate = self
        engine.photoDelegate = self
        engine.photoCaptureFailureHandler = { [weak self] reason in
            DispatchQueue.main.async {
                self?.capturing = false
                self?.errorMessage = reason
            }
        }
        engine.automaticallyConfiguresApplicationAudioSession = false
        engine.captureMode = .photo
        engine.devicePosition = .back
        engine.deviceOrientation = .portrait
        engine.photoConfiguration.preset = .photo
        engine.photoConfiguration.codec = .jpeg
        engine.photoConfiguration.isHighResolutionEnabled = true
        engine.photoConfiguration.photoQualityPrioritization = .quality
        engine.photoConfiguration.generateThumbnail = false
        engine.photoConfiguration.isRawCaptureEnabled = false
        do { try engine.start() }
        catch { errorMessage = "相机启动失败：" + error.localizedDescription }
    }

    func stop() {
        active = false
        ready = false
        capturing = false
        if engine.delegate === self { engine.delegate = nil }
        if engine.photoDelegate === self { engine.photoDelegate = nil }
        engine.photoCaptureFailureHandler = nil
        engine.stop()
        onCapture = nil
        pendingRAW = nil
        pendingProcessed = nil
    }

    private func updateCapabilities() {
        guard let device = engine.proCaptureDevice else { return }
        rawAvailable = engine.proRAWAvailable
        flashAvailable = engine.isFlashAvailable
        zoomRange = Double(device.minAvailableVideoZoomFactor) ...
            max(Double(device.minAvailableVideoZoomFactor),
                min(12.0, Double(device.activeFormat.videoMaxZoomFactor)))
        zoom = min(max(Double(device.videoZoomFactor),zoomRange.lowerBound),zoomRange.upperBound)
        isoRange = Double(device.activeFormat.minISO) ... Double(device.activeFormat.maxISO)
        iso = min(max(Double(device.iso),isoRange.lowerBound),isoRange.upperBound)
        let minDuration = max(0.00001,
            CMTimeGetSeconds(device.activeFormat.minExposureDuration))
        let maxDuration = max(minDuration,
            CMTimeGetSeconds(device.activeFormat.maxExposureDuration))
        shutterRange = log2(minDuration) ... log2(maxDuration)
        shutterLog2 = min(max(log2(max(minDuration,CMTimeGetSeconds(device.exposureDuration))),
            shutterRange.lowerBound),shutterRange.upperBound)
        exposureBiasRange = Double(device.minExposureTargetBias) ...
            Double(device.maxExposureTargetBias)
        exposureBias = min(max(Double(device.exposureTargetBias),
            exposureBiasRange.lowerBound),exposureBiasRange.upperBound)
        focusPosition = Double(device.lensPosition)
        temperature = Double(engine.whiteBalanceTemperature)
        tint = Double(engine.whiteBalanceTint)
    }

    func setFormat(_ format: CaptureFormat) {
        guard !capturing else { return }
        if format == .raw && !rawAvailable {
            errorMessage = "当前镜头不支持原生 Bayer RAW DNG，未自动回退 JPEG。"
            return
        }
        captureFormat = format
    }

    func selectLens(_ lens: CaptureLens) {
        guard active && ready && !capturing && availableLenses.contains(lens) else { return }
        if lens.position != engine.devicePosition {
            engine.flashMode = .off
            engine.devicePosition = lens.position
        }
        do {
            try engine.changeCaptureDeviceIfAvailable(captureDevice:lens.deviceType)
            selectedLens = lens
            flashMode = 0
            // Device reconfiguration runs on NextLevel's session queue.
            // Never advertise DNG support from the old camera.
            ready = false
            rawAvailable = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self = self, self.active else { return }
                self.updateCapabilities()
                self.ready = self.engine.isRunning
            }
        } catch {
            errorMessage = "该镜头不可用：" + error.localizedDescription
        }
    }

    func cycleFlash() {
        guard ready && flashAvailable else { return }
        flashMode = (flashMode + 1) % 3
        engine.flashMode = flashMode == 1 ? .on : flashMode == 2 ? .auto : .off
    }

    func focus(at point: CGPoint) {
        guard active && ready && !capturing else { return }
        if !manualFocus && !manualExposure && !manualWhiteBalance {
            engine.focusExposeAndAdjustWhiteBalance(atAdjustedPoint: point)
        } else if !manualFocus {
            engine.focusAtAdjustedPointOfInterest(adjustedPoint: point)
        }
    }

    func setZoom(_ value: Double) {
        guard ready && !capturing else { return }
        do { try engine.proSetZoom(CGFloat(value)) }
        catch { errorMessage = error.localizedDescription }
    }

    func changeExposureMode(_ manual: Bool) {
        guard ready else { return }
        do {
            if manual { try engine.proSetManualExposure(
                iso: Float(iso), shutterSeconds: pow(2.0,shutterLog2)
            ) } else {
                try engine.proReturnToAutoExposure()
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func updateManualExposure() {
        if manualExposure && ready && !capturing {
            changeExposureMode(true)
        }
    }
    func setExposureBias(_ value: Double) {
        guard !manualExposure && ready && !capturing else { return }
        do { try engine.proSetExposureBias(Float(value)) }
        catch { errorMessage = error.localizedDescription }
    }
    func changeFocusMode(_ manual: Bool) {
        guard ready else { return }
        do {
            if manual { try engine.proSetManualFocus(position:Float(focusPosition)) }
            else { try engine.proReturnToAutoFocus() }
        } catch { errorMessage = error.localizedDescription }
    }
    func updateManualFocus(_ value: Double) {
        guard manualFocus && ready && !capturing else { return }
        do { try engine.proSetManualFocus(position:Float(value)) }
        catch { errorMessage = error.localizedDescription }
    }
    func changeWhiteBalanceMode(_ manual: Bool) {
        guard ready else { return }
        do {
            if manual { try engine.proSetWhiteBalance(
                temperature:Float(temperature),tint:Float(tint)) }
            else { try engine.proReturnToAutoWhiteBalance() }
        } catch { errorMessage = error.localizedDescription }
    }
    func updateWhiteBalance() {
        if manualWhiteBalance && ready && !capturing {
            changeWhiteBalanceMode(true)
        }
    }

    func capture() {
        guard active && ready && !capturing && engine.canCapturePhoto else {
            errorMessage = "相机未准备好，或设备剩余空间不足。"
            return
        }
        if captureFormat == .raw && !engine.proRAWAvailable {
            errorMessage = "原生 RAW DNG 不受当前镜头支持；拒绝静默拍成 JPEG。"
            return
        }
        pendingRAW = nil
        pendingProcessed = nil
        captureExpectedRAW = captureFormat == .raw
        captureFormatLabel = captureFormat.rawValue
        engine.photoConfiguration.codec = captureFormat == .heic ? .hevc : .jpeg
        engine.photoConfiguration.isRawCaptureEnabled = captureExpectedRAW
        capturing = true
        engine.capturePhoto()
    }

    func nextLevel(_ n: NextLevel,
                   didUpdateVideoConfiguration c: NextLevelVideoConfiguration) {}
    func nextLevel(_ n: NextLevel,
                   didUpdateAudioConfiguration c: NextLevelAudioConfiguration) {}
    func nextLevelSessionWillStart(_ n: NextLevel) {}
    func nextLevelSessionDidStart(_ n: NextLevel) {
        guard active else { return }
        updateCapabilities()
        ready = true
    }
    func nextLevelSessionDidStop(_ n: NextLevel) { ready = false }
    func nextLevelSessionWasInterrupted(_ n: NextLevel) {
        ready = false
        capturing = false
        if active { errorMessage = "相机被系统中断，请重新打开相机。" }
    }
    func nextLevelSessionInterruptionEnded(_ n: NextLevel) {}
    func nextLevelCaptureModeWillChange(_ n: NextLevel) { ready = false }
    func nextLevelCaptureModeDidChange(_ n: NextLevel) {}

    func nextLevel(_ n: NextLevel, output: AVCapturePhotoOutput,
                   willBeginCaptureFor settings: AVCaptureResolvedPhotoSettings,
                   photoConfiguration: NextLevelPhotoConfiguration) {}
    func nextLevel(_ n: NextLevel, output: AVCapturePhotoOutput,
                   willCapturePhotoFor settings: AVCaptureResolvedPhotoSettings,
                   photoConfiguration: NextLevelPhotoConfiguration) {}
    func nextLevel(_ n: NextLevel, output: AVCapturePhotoOutput,
                   didCapturePhotoFor settings: AVCaptureResolvedPhotoSettings,
                   photoConfiguration: NextLevelPhotoConfiguration) {}
    func nextLevel(_ n: NextLevel, didFinishProcessingPhoto photo: AVCapturePhoto,
                   photoDict: [String: Any], photoConfiguration: NextLevelPhotoConfiguration) {
        guard active && capturing else { return }
        guard let data = (photoDict[NextLevelPhotoFileDataKey] as? Data)
            ?? photo.fileDataRepresentation(), !data.isEmpty else {
            errorMessage = "照片数据为空；已拒绝使用预览快照替代。"
            return
        }
        if photo.isRawPhoto {
            pendingRAW = data
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 {
            pendingProcessed = data
        } else {
            errorMessage = "相机未返回可解码的 JPEG/HEIC。"
        }
    }
    func nextLevelDidCompletePhotoCapture(_ n: NextLevel) {
        guard active && capturing else { return }
        capturing = false
        guard let companion = pendingProcessed else {
            errorMessage = "拍摄失败：没有收到 JPEG/HEIC 主图，未进入冲印。"
            return
        }
        if captureExpectedRAW && pendingRAW == nil {
            errorMessage = "RAW+DNG 拍摄失败：未收到原始 DNG，拒绝仅使用 JPEG。"
            return
        }
        let result = NextLevelCapturedPhoto(
            processed:companion,
            rawDNG:captureExpectedRAW ? pendingRAW : nil,
            format:captureFormatLabel
        )
        pendingRAW = nil
        pendingProcessed = nil
        let handoff = onCapture
        onCapture = nil
        handoff?(result)
    }
}
