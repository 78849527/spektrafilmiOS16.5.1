import AVFoundation
import ImageIO
import NextLevel
import SwiftUI
import UIKit

/// A standalone capture surface. All photo processing belongs to PhotoEditorModel.
/// It receives the ORIGINAL full-size JPEG Data, not a camera preview snapshot.
struct NextLevelCameraScreen: View {
    let onCancel: () -> Void
    let onCapture: (Data) -> Void
    @StateObject private var camera = NextLevelCameraController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NextLevelCameraPreview()
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.38), in: Circle())
                    }
                    Spacer()
                    Text("NextLevel 拍照")
                        .font(.headline)
                    Spacer()
                    Button {
                        camera.toggleFlash()
                    } label: {
                        Image(systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 19))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.38), in: Circle())
                    }
                    .disabled(!camera.ready || camera.frontCamera)
                    .accessibilityLabel(camera.flashEnabled ? "关闭闪光灯" : "开启闪光灯")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                Text(camera.ready ? "拍照后自动进入当前胶片／相纸冲印" : "正在启动相机…")
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())

                HStack {
                    Button {
                        camera.flip()
                    } label: {
                        Image(systemName: "camera.rotate")
                            .font(.system(size: 25))
                            .frame(width: 60, height: 60)
                    }
                    .disabled(!camera.ready || camera.capturing)
                    .accessibilityLabel("切换前置或后置摄像头")

                    Spacer()

                    Button {
                        camera.capture()
                    } label: {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 5)
                            .background(Circle().fill(camera.capturing ? Color.gray : Color.white)
                                .padding(7))
                            .frame(width: 76, height: 76)
                    }
                    .disabled(!camera.ready || camera.capturing)
                    .accessibilityLabel("拍照并冲印")

                    Spacer()

                    Text("JPG")
                        .font(.caption.weight(.semibold))
                        .frame(width: 60, height: 60)
                        .accessibilityLabel("JPEG 拍摄，不是 RAW")
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 26)
            }
            .foregroundStyle(.white)
        }
        .onAppear {
            camera.onCapture = onCapture
            camera.start()
        }
        .onDisappear {
            camera.stop()
        }
        .alert("相机提示", isPresented: Binding(
            get: { camera.errorMessage != nil },
            set: { if !$0 { camera.errorMessage = nil } }
        )) {
            Button("关闭", role: .cancel) { camera.errorMessage = nil }
            Button("打开系统设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }
}

/// The preview layer belongs to NextLevel.shared and survives screen redraws.
private final class CameraPreviewSurface: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        NextLevel.shared.previewLayer.frame = bounds
    }
}

private struct NextLevelCameraPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> CameraPreviewSurface {
        let view = CameraPreviewSurface()
        view.backgroundColor = .black
        let layer = NextLevel.shared.previewLayer
        layer.videoGravity = .resizeAspectFill
        layer.removeFromSuperlayer()
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewSurface, context: Context) {
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(_ uiView: CameraPreviewSurface, coordinator: ()) {
        if NextLevel.shared.previewLayer.superlayer === uiView.layer {
            NextLevel.shared.previewLayer.removeFromSuperlayer()
        }
    }
}

/// Photo-only NextLevel session. No microphone permission; no RAW claim.
/// NextLevel 0.19.1 has an incomplete isRawCaptureEnabled branch.
private final class NextLevelCameraController: NSObject,
    ObservableObject, NextLevelDelegate, NextLevelPhotoDelegate {
    @Published private(set) var ready = false
    @Published private(set) var capturing = false
    @Published private(set) var frontCamera = false
    @Published private(set) var flashEnabled = false
    @Published var errorMessage: String?

    var onCapture: ((Data) -> Void)?
    private let engine = NextLevel.shared
    private var active = false

    func start() {
        guard !active else { return }
        active = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self, self.active else { return }
                    if granted {
                        self.configure()
                    } else {
                        self.errorMessage = "未获得相机权限。请在系统设置中开启相机访问。"
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = "相机访问被拒绝或受限。请检查系统设置。"
        @unknown default:
            errorMessage = "无法确认相机权限状态。"
        }
    }

    private func configure() {
        guard active else { return }
        engine.delegate = self
        engine.photoDelegate = self
        engine.automaticallyConfiguresApplicationAudioSession = false
        engine.captureMode = .photo
        engine.devicePosition = .back
        engine.photoConfiguration.preset = .photo
        engine.photoConfiguration.codec = .jpeg
        engine.photoConfiguration.isHighResolutionEnabled = true
        engine.photoConfiguration.photoQualityPrioritization = .quality
        engine.photoConfiguration.generateThumbnail = false
        engine.photoConfiguration.isRawCaptureEnabled = false
        do {
            try engine.start()
        } catch {
            errorMessage = "相机启动失败：" + error.localizedDescription
        }
    }

    func stop() {
        active = false
        ready = false
        capturing = false
        if engine.delegate === self { engine.delegate = nil }
        if engine.photoDelegate === self { engine.photoDelegate = nil }
        engine.stop()
        onCapture = nil
    }

    func capture() {
        guard active, ready, !capturing, engine.canCapturePhoto else {
            errorMessage = "相机尚未准备好拍照，请检查摄像头或剩余存储空间。"
            return
        }
        capturing = true
        engine.capturePhoto()
    }

    func flip() {
        guard active, ready, !capturing else { return }
        engine.flipCaptureDevicePosition()
        frontCamera.toggle()
        flashEnabled = false
    }

    func toggleFlash() {
        guard active, ready, !frontCamera else { return }
        flashEnabled.toggle()
        engine.flashMode = flashEnabled ? .on : .off
    }

    func nextLevel(_ nextLevel: NextLevel,
                   didUpdateVideoConfiguration videoConfiguration: NextLevelVideoConfiguration) {}
    func nextLevel(_ nextLevel: NextLevel,
                   didUpdateAudioConfiguration audioConfiguration: NextLevelAudioConfiguration) {}
    func nextLevelSessionWillStart(_ nextLevel: NextLevel) {}
    func nextLevelSessionDidStart(_ nextLevel: NextLevel) {
        if active { ready = true }
    }
    func nextLevelSessionDidStop(_ nextLevel: NextLevel) { ready = false }
    func nextLevelSessionWasInterrupted(_ nextLevel: NextLevel) {
        ready = false
        capturing = false
        if active { errorMessage = "相机被系统中断，请重新打开拍照界面。" }
    }
    func nextLevelSessionInterruptionEnded(_ nextLevel: NextLevel) {}
    func nextLevelCaptureModeWillChange(_ nextLevel: NextLevel) { ready = false }
    func nextLevelCaptureModeDidChange(_ nextLevel: NextLevel) {}

    func nextLevel(_ nextLevel: NextLevel, output: AVCapturePhotoOutput,
                   willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                   photoConfiguration: NextLevelPhotoConfiguration) {}
    func nextLevel(_ nextLevel: NextLevel, output: AVCapturePhotoOutput,
                   willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                   photoConfiguration: NextLevelPhotoConfiguration) {}
    func nextLevel(_ nextLevel: NextLevel, output: AVCapturePhotoOutput,
                   didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                   photoConfiguration: NextLevelPhotoConfiguration) {}
    func nextLevel(_ nextLevel: NextLevel, didFinishProcessingPhoto photo: AVCapturePhoto,
                   photoDict: [String: Any], photoConfiguration: NextLevelPhotoConfiguration) {
        guard active else { return }
        let bytes = (photoDict[NextLevelPhotoJPEGKey] as? Data)
            ?? (photoDict[NextLevelPhotoFileDataKey] as? Data)
            ?? photo.fileDataRepresentation()
        guard let data = bytes, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            capturing = false
            errorMessage = "相机没有返回可解码的 JPEG 照片。"
            return
        }
        capturing = false
        let handoff = onCapture
        onCapture = nil
        handoff?(data)
    }
    func nextLevelDidCompletePhotoCapture(_ nextLevel: NextLevel) {
        if active && capturing {
            capturing = false
            errorMessage = "拍摄已结束，但没有收到照片数据。"
        }
    }
}
