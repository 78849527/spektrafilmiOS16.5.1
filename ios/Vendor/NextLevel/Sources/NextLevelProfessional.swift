import AVFoundation
import Foundation

/// SpektraFilm add-on to the exact upstream NextLevel 0.18.0 source.
/// Device capabilities are read from the real selected AVCaptureDevice,
/// not fabricated fixed ISO/RAW values.
public enum NextLevelProError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let text) = self { return text }
        return nil
    }
}

extension NextLevel {
    public var proCaptureDevice: AVCaptureDevice? { _currentDevice }

    public var proAvailableRAWTypes: [OSType] {
        _photoOutput?.availableRawPhotoPixelFormatTypes ?? []
    }

    public var proRAWAvailable: Bool { !proAvailableRAWTypes.isEmpty }

    /// Independent manual ISO and shutter in the SAME AVFoundation transaction.
    /// No implicit clamp: the UI must request a value actually supported by
    /// the selected lens, or this call throws with an actionable explanation.
    public func proSetManualExposure(iso: Float, shutterSeconds: Double) throws {
        guard let d = _currentDevice, d.isExposureModeSupported(.custom) else {
            throw NextLevelProError.invalid("当前镜头不支持手动 ISO / 快门")
        }
        let minTime = CMTimeGetSeconds(d.activeFormat.minExposureDuration)
        let maxTime = CMTimeGetSeconds(d.activeFormat.maxExposureDuration)
        guard iso.isFinite, iso >= d.activeFormat.minISO,
              iso <= d.activeFormat.maxISO,
              shutterSeconds.isFinite, shutterSeconds >= minTime,
              shutterSeconds <= maxTime else {
            throw NextLevelProError.invalid(
                "超出当前镜头范围：ISO \(d.activeFormat.minISO)–\(d.activeFormat.maxISO)，" +
                "快门 \(minTime)–\(maxTime) 秒"
            )
        }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        d.setExposureModeCustom(
            duration: CMTimeMakeWithSeconds(shutterSeconds, preferredTimescale: 1_000_000_000),
            iso: iso, completionHandler: nil
        )
    }

    public func proReturnToAutoExposure() throws {
        guard let d = _currentDevice,
              d.isExposureModeSupported(.continuousAutoExposure) else {
            throw NextLevelProError.invalid("当前镜头不支持自动曝光")
        }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        d.exposureMode = .continuousAutoExposure
    }

    public func proSetManualFocus(position: Float) throws {
        guard let d = _currentDevice,
              d.isFocusModeSupported(.locked),
              position.isFinite, (0...1).contains(position) else {
            throw NextLevelProError.invalid("当前镜头不支持该手动对焦位置")
        }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        d.setFocusModeLocked(lensPosition: position, completionHandler: nil)
    }

    public func proReturnToAutoFocus() throws {
        guard let d = _currentDevice,
              d.isFocusModeSupported(.continuousAutoFocus) else {
            throw NextLevelProError.invalid("当前镜头不支持连续自动对焦")
        }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        d.focusMode = .continuousAutoFocus
    }

    public func proSetWhiteBalance(temperature: Float, tint: Float) throws {
        guard let d = _currentDevice,
              d.isWhiteBalanceModeSupported(.locked),
              temperature.isFinite && (2500...10000).contains(temperature),
              tint.isFinite && (-150...150).contains(tint) else {
            throw NextLevelProError.invalid("当前镜头不支持此白平衡色温/色调")
        }
        let setting = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: temperature, tint: tint
        )
        let gains = d.deviceWhiteBalanceGains(for: setting).normalize(d)
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
    }

    public func proReturnToAutoWhiteBalance() throws {
        guard let d = _currentDevice,
              d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else {
            throw NextLevelProError.invalid("当前镜头不支持自动白平衡")
        }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        d.whiteBalanceMode = .continuousAutoWhiteBalance
    }

    public func proSetZoom(_ value: CGFloat) throws {
        guard let d = _currentDevice,
              value.isFinite,
              value >= d.minAvailableVideoZoomFactor,
              value <= min(12, d.activeFormat.videoMaxZoomFactor) else {
            throw NextLevelProError.invalid("当前镜头不支持该变焦倍率")
        }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        d.videoZoomFactor = value
    }

    public func proSetExposureBias(_ ev: Float) throws {
        guard let d = _currentDevice,
              ev.isFinite,
              ev >= d.minExposureTargetBias,
              ev <= d.maxExposureTargetBias else {
            throw NextLevelProError.invalid("当前镜头不支持该曝光补偿")
        }
        try d.lockForConfiguration()
        defer { d.unlockForConfiguration() }
        d.setExposureTargetBias(ev, completionHandler: nil)
    }
}
