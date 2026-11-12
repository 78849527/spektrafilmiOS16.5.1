import Foundation
import Photos

/// iOS 16.5+ add-only Photos access; no read/write library permission.
/// Saves the exact exported JPEG file without re-encoding a UIImage.
/// Requests access only after the user explicitly taps Save to Photos.
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case notAuthorized
        case failed

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "没有获得相册添加权限，请到系统设置中允许本 App 添加照片。"
            case .failed:
                return "写入系统相册失败，请检查照片权限和剩余储存空间。"
            }
        }
    }

    static func saveJPEG(at url: URL) async throws {
        let authorization = await withCheckedContinuation {
            (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        guard authorization == .authorized || authorization == .limited else {
            throw SaveError.notAuthorized
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromImage(
                    atFileURL: url
                )
            }, completionHandler: { saved, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if saved {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: SaveError.failed)
                }
            })
        }
    }
}
