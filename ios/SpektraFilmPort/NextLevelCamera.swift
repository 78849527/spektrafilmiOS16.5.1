import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Build122 uses AVFoundation directly. Kept the existing photo contract
/// name to avoid touching the proven optical importer / RAW byte archiver.
struct NextLevelCapturedPhoto {
    let processed:Data
    let rawDNG:Data?
    let format:String
}

private enum NativePhotoFormat:String,CaseIterable,Identifiable {
    case jpeg="JPEG"
    case heic="HEIC"
    case raw="RAW DNG＋JPEG"
    var id:String {rawValue}
}
private enum NativeCameraLens:String,CaseIterable,Identifiable {
    case ultra="0.5×"
    case wide="1×"
    case tele="长焦"
    case front="前置"
    var id:String {rawValue}
    var position:AVCaptureDevice.Position { self == .front ? .front : .back }
    var deviceType:AVCaptureDevice.DeviceType {
        switch self {
        case .ultra:return .builtInUltraWideCamera
        case .wide,.front:return .builtInWideAngleCamera
        case .tele:return .builtInTelephotoCamera
        }
    }
}
private enum NativeCameraRatio:String,CaseIterable,Identifiable {
    case fourThree="4:3"
    case threeTwo="3:2"
    case sixteenNine="16:9"
    case square="1:1"
    var id:String {rawValue}
    var landscapeRatio:CGFloat {
        switch self {
        case .fourThree:return 4.0/3
        case .threeTwo:return 3.0/2
        case .sixteenNine:return 16.0/9
        case .square:return 1
        }
    }
    var portraitAspect:CGFloat {1/landscapeRatio}
}

/// One capture produces an unmodified Bayer DNG and a separately processed
/// companion photo; only the JPEG/HEIC companion receives framing crop.
/// A failure anywhere is reported, NOT replaced by a fake JPEG RAW.
private enum NativeCameraAspectCrop {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {if case .invalid(let x)=self{return x};return nil}
    }
    static func processed(_ data:Data,format:NativePhotoFormat,
                          ratio:NativeCameraRatio)throws->Data {
        if ratio == .fourThree {return data}
        guard let input=CIImage(data:data,options:[.applyOrientationProperty:true]) else {
            throw Failure.invalid("无法读取伴随照片；已保留 RAW 拍摄错误，不回退预览快照")
        }
        let bounds=input.extent
        guard bounds.width>0,bounds.height>0 else {
            throw Failure.invalid("相机照片无有效像素尺寸")
        }
        let required=bounds.height>bounds.width
            ? ratio.portraitAspect : ratio.landscapeRatio
        var crop=bounds
        if bounds.width/bounds.height>required {
            crop.size.width=floor(bounds.height*required)
            crop.origin.x=floor(bounds.midX-crop.width/2)
        } else {
            crop.size.height=floor(bounds.width/required)
            crop.origin.y=floor(bounds.midY-crop.height/2)
        }
        guard crop.width>0,crop.height>0 else {
            throw Failure.invalid("当前画幅裁切尺寸不合法")
        }
        let context=CIContext(options:[.cacheIntermediates:false])
        guard let srgb=CGColorSpace(name:CGColorSpace.sRGB),
              let cg=context.createCGImage(input.cropped(to:crop),
                                           from:crop,format:.RGBA8,
                                           colorSpace:srgb) else {
            throw Failure.invalid("无法生成实际画幅的完整像素照片")
        }
        let output=NSMutableData()
        let uti=(format == .heic ? UTType.heic : UTType.jpeg).identifier
        guard let destination=CGImageDestinationCreateWithData(
            output,uti as CFString,1,nil
        ) else {
            throw Failure.invalid("无法创建画幅照片编码器")
        }
        CGImageDestinationAddImage(
            destination,cg,
            [kCGImageDestinationLossyCompressionQuality:0.96] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.invalid("画幅照片编码失败")
        }
        return output as Data
    }
}

private final class NativePreviewSurface:UIView {
    override class var layerClass:AnyClass {AVCaptureVideoPreviewLayer.self}
    var previewLayer:AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
private struct NativeCameraPreview:UIViewRepresentable {
    let session:AVCaptureSession
    func makeUIView(context:Context)->NativePreviewSurface {
        let view=NativePreviewSurface()
        view.backgroundColor = .black
        view.previewLayer.session=session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.connection?.videoOrientation = .portrait
        return view
    }
    func updateUIView(_ view:NativePreviewSurface,context:Context) {
        if view.previewLayer.session !== session {view.previewLayer.session=session}
    }
}

/// The capture delegate lives until didFinishCaptureFor, not until the
/// first RAW/JPEG didFinishProcessing callback. No NextLevel singleton.

/// Build123: last completed RAW capture phase is persisted before calling
/// AVFoundation; if the process dies without a delegate error, the next
/// camera opening reports the last observed phase. The stage alone does
/// not prove a crash, and no DNG/private image bytes are logged.
private enum NativeRAWCaptureTrace {
    static let key="SF.Build123.NativeRAW.LastStage"
    static func mark(_ stage:String) {
        UserDefaults.standard.set(stage,forKey:key)
    }
    static func clear() {
        UserDefaults.standard.removeObject(forKey:key)
    }
    static func unresolved()->String? {
        UserDefaults.standard.string(forKey:key)
    }
}

private final class NativePhotoCaptureDelegate:NSObject,AVCapturePhotoCaptureDelegate {
    private let format:NativePhotoFormat
    private let ratio:NativeCameraRatio
    private let done:(Result<NextLevelCapturedPhoto,Error>)->Void
    private var companion:Data?
    private var dng:Data?
    private var firstError:Error?
    init(format:NativePhotoFormat,ratio:NativeCameraRatio,
         done:@escaping(Result<NextLevelCapturedPhoto,Error>)->Void) {
        self.format=format;self.ratio=ratio;self.done=done
    }
    private func fail(_ message:String)->Error {
        NativeCameraAspectCrop.Failure.invalid(message)
    }
    func photoOutput(_ output:AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo:AVCapturePhoto,
                     error:Error?) {
        if let error {firstError=error;return}
        guard let bytes=photo.fileDataRepresentation(),!bytes.isEmpty else {
            firstError=fail("相机照片回调没有返回完整文件数据")
            return
        }
        if photo.isRawPhoto {
            dng=bytes
            NativeRAWCaptureTrace.mark("DNG 数据回调完成")
        } else {
            companion=bytes
            if format == .raw {
                NativeRAWCaptureTrace.mark("JPEG 伴随片回调完成")
            }
        }
    }
    func photoOutput(_ output:AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings:AVCaptureResolvedPhotoSettings,
                     error:Error?) {
        if let error {firstError=error}
        if format == .raw {
            NativeRAWCaptureTrace.mark("拍摄完成回调已进入")
        }
        if let firstError {
            NativeRAWCaptureTrace.clear()
            DispatchQueue.main.async {self.done(.failure(firstError))}
            return
        }
        guard let companion else {
            NativeRAWCaptureTrace.clear()
            DispatchQueue.main.async {
                self.done(.failure(self.fail("相机未返回 JPEG/HEIC 主照片")))
            }
            return
        }
        if format == .raw && dng == nil {
            NativeRAWCaptureTrace.clear()
            DispatchQueue.main.async {
                self.done(.failure(self.fail("RAW 拍摄未返回 DNG；未静默回退 JPEG")))
            }
            return
        }
        let raw=dng
        let format=selectorName
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let processed=try NativeCameraAspectCrop.processed(
                    companion,format:self.format,ratio:self.ratio
                )
                let photo=NextLevelCapturedPhoto(
                    processed:processed,rawDNG:raw,format:format
                )
                if self.format == .raw {NativeRAWCaptureTrace.clear()}
                DispatchQueue.main.async {self.done(.success(photo))}
            } catch {
                NativeRAWCaptureTrace.clear()
                DispatchQueue.main.async {self.done(.failure(error))}
            }
        }
    }
    private var selectorName:String {
        format.rawValue+" · "+ratio.rawValue
    }
}

private final class NativeCameraController:NSObject,ObservableObject {
    @Published private(set) var ready=false
    @Published private(set) var capturing=false
    @Published private(set) var rawAvailable=false
    @Published private(set) var heicAvailable=false
    @Published private(set) var flashAvailable=false
    @Published private(set) var selectedLens:NativeCameraLens = .wide
    @Published private(set) var availableLenses:Set<NativeCameraLens> = [.wide]
    // Build127: default requests genuine Bayer DNG. Unsupported lenses
    // remain explicitly blocked; never silently switch to JPEG.
    @Published private(set) var format:NativePhotoFormat = .raw
    @Published private(set) var ratio:NativeCameraRatio = .fourThree
    @Published private(set) var flashEnabled=false
    @Published var errorMessage:String?
    var onCapture:((NextLevelCapturedPhoto)->Void)?
    let session=AVCaptureSession()
    private let sessionQueue=DispatchQueue(label:"sf.native.camera.capture-session")
    private let output=AVCapturePhotoOutput()
    private var videoInput:AVCaptureDeviceInput?
    private var captureDelegate:NativePhotoCaptureDelegate?
    private var active=false

    func start() {
        guard !active else {return}
        active=true
        if let prior=NativeRAWCaptureTrace.unresolved() {
            errorMessage="上次 RAW 拍摄未正常结束，最后阶段：「\(prior)」。这并不直接证明崩溃原因。如再次退出，请在 iOS「设置 → 隐私与安全性 → 分析与改进 → 分析数据」提供 SpektraFilm 的 .ips 崩溃报告。"
            NativeRAWCaptureTrace.clear()
        }
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized:configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for:.video) {[weak self] allowed in
                DispatchQueue.main.async {
                    guard let self,self.active else{return}
                    if allowed {self.configure()}
                    else {self.errorMessage="未获得摄像头权限，请在系统设置中授权"}
                }
            }
        case .restricted,.denied:
            errorMessage="相机访问受限。请检查 iOS 的相机授权。"
        @unknown default:errorMessage="无法读取相机权限状态"
        }
    }
    func stop() {
        active=false
        ready=false
        onCapture=nil
        // Do not erase a pending RAW breadcrumb on force-quit / crash.
        if !capturing {NativeRAWCaptureTrace.clear()}
        sessionQueue.async {[weak self] in
            guard let self else{return}
            if self.session.isRunning {self.session.stopRunning()}
            self.captureDelegate=nil
        }
    }
    private func report(_ message:String) {
        DispatchQueue.main.async {[weak self] in self?.errorMessage=message}
    }
    private func cameraDevice(_ lens:NativeCameraLens)->AVCaptureDevice? {
        AVCaptureDevice.default(lens.deviceType,for:.video,position:lens.position)
    }
    private func configure() {
        sessionQueue.async {[weak self] in
            guard let self else{return}
            guard let device=self.cameraDevice(.wide) ??
                self.cameraDevice(.front) else {
                self.report("当前设备没有可用摄像头")
                return
            }
            do {
                let input=try AVCaptureDeviceInput(device:device)
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                guard self.session.canAddInput(input),
                      self.session.canAddOutput(self.output) else {
                    self.session.commitConfiguration()
                    self.report("相机捕获会话不支持当前镜头和照片输出组合")
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(self.output)
                self.output.isHighResolutionCaptureEnabled=true
                // Must be decided BEFORE startRunning; toggling during
                // capture can cause an expensive session rebuild.
                self.output.maxPhotoQualityPrioritization = .balanced
                self.session.commitConfiguration()
                self.videoInput=input
                self.session.startRunning()
                self.refreshCapabilities(device:device)
            } catch {self.report("相机启动失败："+error.localizedDescription)}
        }
    }
    private func refreshCapabilities(device:AVCaptureDevice) {
        let lenses=Set(NativeCameraLens.allCases.filter{
            self.cameraDevice($0) != nil
        })
        let hasBayer=output.availableRawPhotoPixelFormatTypes.contains {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }
        let heic=output.availablePhotoCodecTypes.contains(.hevc)
        let flash=device.hasFlash
        DispatchQueue.main.async {[weak self] in
            guard let self,self.active else{return}
            self.selectedLens=NativeCameraLens.allCases.first(where:{
                $0.deviceType == device.deviceType && $0.position == device.position
            }) ?? .wide
            self.availableLenses=lenses
            self.rawAvailable=hasBayer
            self.heicAvailable=heic
            self.flashAvailable=flash
            self.ready=self.session.isRunning
        }
    }
    func selectLens(_ lens:NativeCameraLens) {
        guard !capturing,availableLenses.contains(lens) else{return}
        ready=false
        sessionQueue.async {[weak self] in
            guard let self, let device=self.cameraDevice(lens) else {
                self?.report("摄像头不可用")
                return
            }
            do {
                let next=try AVCaptureDeviceInput(device:device)
                self.session.beginConfiguration()
                if let old=self.videoInput {self.session.removeInput(old)}
                if self.session.canAddInput(next) {
                    self.session.addInput(next)
                    self.videoInput=next
                } else {
                    if let old=self.videoInput {self.session.addInput(old)}
                    self.session.commitConfiguration()
                    self.report("此镜头不能加入当前照片会话，原镜头已保留")
                    self.refreshCapabilities(device:self.videoInput?.device ?? device)
                    return
                }
                self.session.commitConfiguration()
                self.refreshCapabilities(device:device)
            } catch {self.report("镜头切换失败："+error.localizedDescription)}
        }
    }
    func selectRatio(_ value:NativeCameraRatio) {
        guard !capturing else {return}
        ratio=value
    }
    func selectFormat(_ value:NativePhotoFormat) {
        guard !capturing else{return}
        guard value != .raw || rawAvailable else {
            errorMessage="当前镜头不支持 Bayer RAW DNG，不会回退为 JPEG"
            return
        }
        guard value != .heic || heicAvailable else {
            errorMessage="当前镜头不支持 HEIC 格式"
            return
        }
        format=value
    }
    func toggleFlash() {
        guard !capturing,flashAvailable else{return}
        flashEnabled.toggle()
    }
    func capture() {
        guard active,ready,!capturing else {
            errorMessage="相机尚未准备好"
            return
        }
        capturing=true
        let wantedFormat=format,wantedRatio=ratio,flash=flashEnabled
        if wantedFormat == .raw {
            NativeRAWCaptureTrace.mark("RAW 快门按下，准备提交原生拍摄请求")
        }
        sessionQueue.async {[weak self] in
            guard let self else{return}
            let jpegAllowed=self.output.availablePhotoCodecTypes.contains(.jpeg)
            let heicAllowed=self.output.availablePhotoCodecTypes.contains(.hevc)
            let raw=self.output.availableRawPhotoPixelFormatTypes.first {
                AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
            }
            guard self.session.isRunning,
                  self.output.connection(with:.video)?.isEnabled == true,
                  self.videoInput != nil else {
                self.finishFailure("RAW/JPEG 前置检查失败：摄像头会话或照片输出连接未就绪")
                return
            }
            guard jpegAllowed && (wantedFormat != .heic || heicAllowed) else {
                self.finishFailure("当前照片输出不支持请求的 JPEG/HEIC 编码")
                return
            }
            if wantedFormat == .raw && raw == nil {
                self.finishFailure("当前镜头不支持 Bayer RAW；未静默拍成 JPEG")
                return
            }
            let codec:AVVideoCodecType=wantedFormat == .heic ? .hevc : .jpeg
            let dictionary:[String:Any]=[AVVideoCodecKey:codec]
            let settings:AVCapturePhotoSettings
            if wantedFormat == .raw,let raw {
                settings=AVCapturePhotoSettings(
                    rawPixelFormatType:raw,processedFormat:dictionary
                )
                // Bayer RAW requires disabled stabilization. The full
                // sensor DNG dimensions are unaffected by this processed
                // JPEG-only high-resolution request, so avoid the high-res
                // processed pipeline for RAW+JPEG on legacy iOS 16.5.1.
                settings.isAutoStillImageStabilizationEnabled=false
                settings.flashMode = .off
                settings.isHighResolutionPhotoEnabled=false
            } else {
                settings=AVCapturePhotoSettings(format:dictionary)
                if flash && self.videoInput?.device.hasFlash == true {
                    settings.flashMode = .on
                }
            }
            if wantedFormat != .raw {
                settings.isHighResolutionPhotoEnabled=true
            }
            // The output advertises balanced as maximum. RAW uses the
            // least complicated speed capture mode while preserving
            // unchanged Bayer sensor samples and a companion JPEG.
            settings.photoQualityPrioritization =
                wantedFormat == .raw ? .speed : .balanced
            let processor=NativePhotoCaptureDelegate(
                format:wantedFormat,ratio:wantedRatio
            ) {[weak self] outcome in
                guard let self else{return}
                self.capturing=false
                self.sessionQueue.async {[weak self] in
                    self?.captureDelegate=nil
                }
                switch outcome {
                case .success(let photo):self.onCapture?(photo)
                case .failure(let error):
                    self.errorMessage="原生拍摄失败："+error.localizedDescription
                }
            }
            self.captureDelegate=processor
            if wantedFormat == .raw {
                NativeRAWCaptureTrace.mark(
                    "RAW AVFoundation capturePhoto 请求即将提交（格式 \(raw ?? 0)）"
                )
            }
            // capturePhoto(with:delegate:) validates RAW settings by
            // Objective-C exceptions, not Swift throws. The ObjC barrier
            // prevents synchronous invalid-argument process termination.
            // Async capture and Jetsam failures still need physical logs.
            if let problem=SFNativeCaptureSafety.startPhotoOutput(
                self.output,settings:settings,delegate:processor
            ) {
                self.captureDelegate=nil
                self.finishFailure(problem)
            }
        }
    }
    private func finishFailure(_ message:String) {
        NativeRAWCaptureTrace.clear()
        DispatchQueue.main.async {[weak self] in
            self?.capturing=false
            self?.errorMessage=message
        }
    }
}

struct NativeCameraScreen:View {
    let onCancel:()->Void
    /// Return an error only when the RAW archive itself failed.
    /// Non-RAW photos continue to enter the editor immediately.
    let onCapture:(NextLevelCapturedPhoto)->String?
    @StateObject private var camera=NativeCameraController()
    @State private var savedRAWCount=0
    var body:some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing:8) {
                HStack {
                    Button(action:onCancel) {
                        Image(systemName:"xmark")
                            .frame(width:44,height:44)
                    }
                    .disabled(camera.capturing)
                    Spacer()
                    Text("SpektraFilm · 原生相机")
                        .font(.system(size:14,weight:.semibold))
                    Spacer()
                    Button {camera.toggleFlash()} label: {
                        Image(systemName:camera.flashEnabled
                            ? "bolt.fill" : "bolt.slash")
                            .frame(width:44,height:44)
                    }
                    .disabled(!camera.flashAvailable || camera.capturing ||
                              camera.format == .raw)
                }
                .padding(.horizontal,12)
                Spacer(minLength:0)
                NativeCameraPreview(session:camera.session)
                    .aspectRatio(camera.ratio.portraitAspect,contentMode:.fit)
                    .frame(maxWidth:.infinity)
                    .clipped()
                    .background(Color.black)
                Spacer(minLength:0)
                HStack(spacing:8) {
                    ForEach(NativeCameraRatio.allCases) { shape in
                        Button(shape.rawValue) {camera.selectRatio(shape)}
                            .font(.system(size:12,weight:.semibold))
                            .frame(maxWidth:.infinity,minHeight:36)
                            .background(camera.ratio == shape
                                ? Color.accentColor.opacity(0.5)
                                : Color.white.opacity(0.13),
                                        in:RoundedRectangle(cornerRadius:8))
                    }
                }
                .padding(.horizontal,16)
                HStack(spacing:8) {
                    ForEach(NativeCameraLens.allCases) { lens in
                        if camera.availableLenses.contains(lens) {
                            Button(lens.rawValue) {camera.selectLens(lens)}
                                .font(.system(size:12,weight:.semibold))
                                .frame(maxWidth:.infinity,minHeight:36)
                                .background(camera.selectedLens == lens
                                    ? Color.accentColor.opacity(0.5)
                                    : Color.white.opacity(0.13),
                                            in:RoundedRectangle(cornerRadius:8))
                                .disabled(!camera.ready || camera.capturing)
                        }
                    }
                }
                .padding(.horizontal,16)
                // Build127: format controls sit directly BELOW the
                // 0.5×/1×/tele/front lens row. Capture defaults to RAW.
                HStack(spacing:8) {
                    Text("格式")
                        .font(.system(size:11,weight:.semibold))
                        .foregroundColor(.secondary)
                        .frame(width:28,alignment:.leading)
                    Button("JPEG") {camera.selectFormat(.jpeg)}
                        .font(.system(size:12,weight:.semibold))
                        .frame(maxWidth:.infinity,minHeight:35)
                        .background(camera.format == .jpeg
                            ? Color.accentColor.opacity(0.5)
                            : Color.white.opacity(0.13),
                            in:RoundedRectangle(cornerRadius:8))
                        .disabled(camera.capturing)
                    Button("RAW DNG") {camera.selectFormat(.raw)}
                        .font(.system(size:12,weight:.semibold))
                        .frame(maxWidth:.infinity,minHeight:35)
                        .background(camera.format == .raw
                            ? Color.accentColor.opacity(0.5)
                            : Color.white.opacity(0.13),
                            in:RoundedRectangle(cornerRadius:8))
                        .disabled(camera.capturing || !camera.rawAvailable)
                        .opacity(camera.rawAvailable ? 1 : 0.5)
                    Menu {
                        Button("HEIC") {camera.selectFormat(.heic)}
                            .disabled(camera.capturing || !camera.heicAvailable)
                    } label: {
                        Text(camera.format == .heic ? "HEIC ✓" : "HEIC")
                            .font(.system(size:11,weight:.semibold))
                            .frame(minWidth:43,minHeight:35)
                            .background(camera.format == .heic
                                ? Color.accentColor.opacity(0.5)
                                : Color.white.opacity(0.13),
                                in:RoundedRectangle(cornerRadius:8))
                    }
                    .disabled(camera.capturing || !camera.heicAvailable)
                }
                .padding(.horizontal,16)
                HStack {
                    Spacer()
                    Button {camera.capture()} label: {
                        Circle().strokeBorder(.white,lineWidth:5)
                            .background(Circle().fill(camera.capturing
                                ? .gray : .white).padding(7))
                            .frame(width:74,height:74)
                    }
                    .disabled(!camera.ready || camera.capturing ||
                              (camera.format == .raw && !camera.rawAvailable))
                    .accessibilityLabel(camera.format == .raw
                                        ? "拍摄真实 Bayer RAW DNG" : "拍摄照片")
                    Spacer()
                }
                if camera.format == .raw {
                    Text(savedRAWCount == 0
                        ? "连续拍摄：每张完整 DNG 和缩略图会存入本机 RAW 素材库；拍摄结束点击左上角关闭。"
                        : "本次已保存 \(savedRAWCount) 张 RAW · 可继续拍摄，退出后从素材库选片冲印")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                Text(camera.capturing ? "正在写入照片…" :
                     (camera.ready && camera.format == .raw && !camera.rawAvailable)
                     ? "该镜头不支持 Bayer RAW；请换支持 RAW 的镜头，或主动选择 JPEG"
                     : camera.ready
                       ? (camera.format == .raw
                          ? "RAW 默认保存完整 DNG；画幅裁切仅作用于伴随 JPEG"
                          : "JPEG/HEIC 使用所选画幅输出")
                       : "正在启动相机…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .foregroundColor(.white)
            .padding(.vertical,12)
        }
        .onAppear {
            camera.onCapture={ photo in
                if let error=onCapture(photo) {
                    camera.errorMessage="照片归档失败："+error
                } else if photo.rawDNG != nil {
                    savedRAWCount+=1
                }
            }
            camera.start()
        }
        .onDisappear {camera.stop()}
        .alert("原生相机提示",isPresented:Binding(
            get:{camera.errorMessage != nil},
            set:{if !$0 {camera.errorMessage=nil}}
        )) {
            Button("确定",role:.cancel){camera.errorMessage=nil}
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }
}
