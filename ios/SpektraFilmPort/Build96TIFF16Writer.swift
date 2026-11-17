import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Build96: real 16-bit TIFF from the EXISTING CI film/paper processing
/// output. This is a separate, opt-in compatibility export path, NOT the
/// original Python Float64 / Build90 exact-source-ICC writer.
enum Build96TIFF16Writer {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    static let estimatedBytesPerPixel: UInt64 = 136
    static let fixedOverheadBytes: UInt64 = 96_000_000

    /// Pure planning logic. Numbers are conservative admission estimates,
    /// never a guarantee that iOS jetsam cannot occur.
    static func estimate(width: Int, height: Int) throws -> UInt64 {
        guard width > 0, height > 0,
              width <= 10000, height <= 10000,
              width <= 45_000_000 / height else {
            throw Failure.invalid("TIFF16 输出尺寸无效或超过 4500 万像素")
        }
        return UInt64(width) * UInt64(height) *
            estimatedBytesPerPixel + fixedOverheadBytes
    }

    static func validateBudget(width: Int, height: Int) throws {
        let bytes = try estimate(width: width, height: height)
        let headroom = SafeExportResolution.currentProcessHeadroom()
            ?? ProcessInfo.processInfo.physicalMemory / 3
        guard headroom > 0,bytes <= headroom / 100 * 70 else {
            throw Failure.invalid(
                "TIFF16 预计使用 " + String(bytes/1_000_000) +
                " MB，当前可分配 " + String(headroom/1_000_000) +
                " MB；需要 30% 安全余量，禁止自动缩图或降位深"
            )
        }
    }

    /// Minimal TIFF IFD validation without decompressing tens of megapixels
    /// a second time. Ensures the real file contains 16-bit per sample.
    private static func readU16(_ d: Data, _ n: Int, _ little: Bool) -> UInt16 {
        if little {
            return UInt16(d[n]) | (UInt16(d[n + 1]) << 8)
        }
        return (UInt16(d[n]) << 8) | UInt16(d[n + 1])
    }
    private static func readU32(_ d: Data, _ n: Int, _ little: Bool) -> UInt32 {
        if little {
            return UInt32(readU16(d,n,true)) |
                (UInt32(readU16(d,n + 2,true)) << 16)
        }
        return (UInt32(readU16(d,n,false)) << 16) |
            UInt32(readU16(d,n + 2,false))
    }
    private static func readAt(_ f: FileHandle, offset: UInt64,
                               count: Int, fileSize: UInt64) throws -> Data {
        guard count > 0, offset <= fileSize,
              UInt64(count) <= fileSize - offset else {
            throw Failure.invalid("TIFF16 IFD 指针越界")
        }
        try f.seek(toOffset: offset)
        guard let d = try f.read(upToCount: count), d.count == count else {
            throw Failure.invalid("TIFF16 文件 IFD 数据不足")
        }
        return d
    }

    static func verifyFile(_ url: URL,
                           width: Int, height: Int) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src),
              UTType(type as String)?.conforms(to: .tiff) == true,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int,
              w == width, h == height else {
            throw Failure.invalid("TIFF16 文件真实格式或 ImageIO 像素尺寸不符")
        }
        let f = try FileHandle(forReadingFrom: url)
        defer { try? f.close() }
        let fileSize = try f.seekToEnd()
        let header = try readAt(f, offset: 0, count: 8, fileSize: fileSize)
        let little: Bool
        if header[0] == 73 && header[1] == 73 { little = true }
        else if header[0] == 77 && header[1] == 77 { little = false }
        else { throw Failure.invalid("TIFF16 文件字节序非法") }
        guard readU16(header,2,little) == 42 else {
            throw Failure.invalid("TIFF16 必须是真实标准 TIFF，不接受改名或未验证 BigTIFF")
        }
        let ifdOffset = UInt64(readU32(header,4,little))
        let countData = try readAt(f,offset:ifdOffset,count:2,fileSize:fileSize)
        let entryCount = Int(readU16(countData,0,little))
        guard entryCount > 0 && entryCount < 4096 else {
            throw Failure.invalid("TIFF16 IFD 条目数量不合法")
        }
        let entries = try readAt(
            f,offset:ifdOffset + 2,count:entryCount * 12,fileSize:fileSize
        )
        var verifiedBits = false
        for i in 0..<entryCount {
            let offset = i * 12
            guard readU16(entries,offset,little) == 258 else { continue }
            let type = readU16(entries,offset + 2,little)
            let channels = Int(readU32(entries,offset + 4,little))
            guard type == 3, channels == 3 || channels == 4 else {
                throw Failure.invalid("TIFF16 BitsPerSample 必须是 RGB/RGBA UInt16")
            }
            let dataOffset = UInt64(readU32(entries,offset + 8,little))
            let bits = try readAt(f,offset:dataOffset,
                                  count:channels * 2,fileSize:fileSize)
            verifiedBits = (0..<channels).allSatisfy {
                readU16(bits,$0 * 2,little) == 16
            }
            break
        }
        guard verifiedBits else {
            throw Failure.invalid("TIFF16 文件 IFD 未证明真实 16-bit 像素通道")
        }
    }

    static func write(_ processed: CIImage) throws -> URL {
        let extent = processed.extent.integral
        guard !extent.isEmpty, extent.width.isFinite,
              extent.height.isFinite else {
            throw Failure.invalid("TIFF16 无效的渲染图像范围")
        }
        let w = Int(extent.width), h = Int(extent.height)
        try validateBudget(width:w,height:h)
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.invalid("TIFF16 运行时没有标准 sRGB 色彩空间")
        }
        let context = CIContext(options: [
            .cacheIntermediates: false
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraFilm-RGB16-" + UUID().uuidString)
            .appendingPathExtension("tiff")
        do {
            // CIFormat.RGBA16 is normalized UInt16, NOT half float and NOT
            // RGBA8. ImageIO must preserve TIFF BitsPerSample=16.
            try context.writeTIFFRepresentation(
                of: processed, to: url, format: .RGBA16,
                colorSpace: sRGB, options: [:]
            )
            try verifyFile(url, width:w,height:h)
            return url
        } catch {
            try? FileManager.default.removeItem(at:url)
            throw error
        }
    }
}
