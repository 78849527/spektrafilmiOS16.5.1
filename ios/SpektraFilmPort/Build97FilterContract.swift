import Foundation
import CoreImage

/// Build97 P0: one explicit failure contract shared by fast image-space
/// optical, scanner and LUT stages. Nil CI filters are NEVER interpreted as
/// a valid unprocessed export in a user-selected effect branch.
/// This does not change any physical formula or the precise Float64 engine.
enum Build97FilterContract {
    enum Failure: LocalizedError {
        case stage(String)
        var errorDescription: String? {
            if case let .stage(name) = self {
                return "图像处理失败：\(name) 没有生成有效图像，已停止预览/导出；未静默跳过效果"
            }
            return nil
        }
    }

    static func required(_ image: CIImage?, stage: String) throws -> CIImage {
        guard let image, !image.extent.isEmpty,
              image.extent.width.isFinite,
              image.extent.height.isFinite else {
            throw Failure.stage(stage)
        }
        return image
    }
}
