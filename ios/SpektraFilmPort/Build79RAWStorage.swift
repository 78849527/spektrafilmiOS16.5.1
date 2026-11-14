import Foundation
import CryptoKit

/// Preserve camera RAW files byte-for-byte for a later actual camera-RAW
/// developer. NEVER call CIImage(data:) on these files: that can return
/// an embedded JPEG instead of sensor samples and would fake RAW support.
enum Build79RAWStorage {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let reason)=self { return reason }
            return nil
        }
    }

    struct Preserved {
        let url:URL
        let format:Build79RAWSignature.Kind
        let sha256:String
        let bytes:Int64
    }

    private static func digest(_ url:URL) throws -> (hash:String,size:Int64) {
        let file=try FileHandle(forReadingFrom:url)
        defer { try? file.close() }
        var hasher=SHA256()
        var byteCount:Int64=0
        while true {
            let next=try file.read(upToCount:1024*1024) ?? Data()
            if next.isEmpty { break }
            hasher.update(data:next)
            byteCount+=Int64(next.count)
        }
        return (hasher.finalize().map {
            String(format:"%02x",$0)
        }.joined(),byteCount)
    }

    static func preserve(_ original:URL,
                         kind:Build79RAWSignature.Kind) throws -> Preserved {
        guard try Build79RAWSignature.probeFile(original)==kind else {
            throw Failure.invalid("RAW 原片文件名和签名不一致，拒绝导入伪 RAW")
        }
        let source=try digest(original)
        guard source.size>32 else {
            throw Failure.invalid("RAW 原片无有效数据")
        }
        guard let docs=FileManager.default.urls(
            for:.documentDirectory,in:.userDomainMask
        ).first else {
            throw Failure.invalid("RAW 无法获得「文件」应用中的存储目录")
        }
        let folder=docs.appendingPathComponent(
            "SpektraFilm RAW Imports",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true,attributes:nil
        )
        let dst=folder.appendingPathComponent(
            UUID().uuidString+"."+kind.rawValue
        )
        try FileManager.default.copyItem(at:original,to:dst)
        do {
            let copied=try digest(dst)
            guard copied.size==source.size,copied.hash==source.hash else {
                throw Failure.invalid(
                    "RAW 无损保存 SHA256 与来源不一致，禁止继续"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at:dst)
            throw error
        }
        return Preserved(url:dst,format:kind,
                         sha256:source.hash,bytes:source.size)
    }
}
