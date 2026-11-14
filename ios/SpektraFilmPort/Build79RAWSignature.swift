import Foundation

/// Build79/09 source RAW FILE identification ONLY.
/// This is not a demosaic, colour transform, rawpy replacement,
/// or a claim that the operating system supports decoding that camera.
/// Reject extension/spoofed-header mismatches before CIImage/thumbnail
/// can quietly turn a RAW file into an unrelated embedded JPEG preview.
enum Build79RAWSignature {
    enum Kind:String,CaseIterable {
        case dng,raf,cr3,nef,cr2,arw
    }

    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let reason)=self { return reason }
            return nil
        }
    }

    private static let possiblyRAW:Set<String> = [
        "dng","raf","cr3","nef","cr2","arw","rw2","orf",
        "pef","srw","raw","rwl","3fr","iiq","k25","erf"
    ]
    private static func require(_ condition:Bool,_ reason:String) throws {
        guard condition else { throw Failure.invalid(reason) }
    }
    private static func u16(_ p:Data,_ off:Int,_ little:Bool) -> Int? {
        guard off>=0,off<=p.count-2 else { return nil }
        let a=Int(p[off]),b=Int(p[off+1])
        return little ? a|(b<<8) : (a<<8)|b
    }
    private static func u32(_ p:Data,_ off:Int,_ little:Bool) -> Int? {
        guard off>=0,off<=p.count-4 else { return nil }
        let a=Int(p[off]),b=Int(p[off+1]),
            c=Int(p[off+2]),d=Int(p[off+3])
        return little ? a|(b<<8)|(c<<16)|(d<<24) :
            (a<<24)|(b<<16)|(c<<8)|d
    }

    /// Inspect TIFF IFD0 without running embedded JPEG/RAW decoding. The
    /// bounded 512-KiB header may not contain every real camera IFD;
    /// such files explicitly remain unsupported, not misidentified.
    private static func tiffIFD(_ header:Data) throws -> [(tag:Int,type:Int,count:Int,value:Int,little:Bool)] {
        guard header.count>=10 else {
            throw Failure.invalid("RAW TIFF 文件头不足")
        }
        let marker=Array(header.prefix(4))
        let little:Bool
        if marker == [0x49,0x49,0x2a,0x00] { little=true }
        else if marker == [0x4d,0x4d,0x00,0x2a] { little=false }
        else {
            throw Failure.invalid("RAW 扩展名与 TIFF 文件签名不一致")
        }
        guard let ifd=u32(header,4,little),ifd>=8,
              ifd<=header.count-2,
              let count=u16(header,ifd,little),
              count>=1,count<=4096,
              count<=(header.count-ifd-2)/12 else {
            throw Failure.invalid(
                "RAW TIFF IFD 超出可验证的文件头范围，不能用内嵌 JPEG 替代"
            )
        }
        var tags=[(tag:Int,type:Int,count:Int,value:Int,little:Bool)]()
        for i in 0..<count {
            let off=ifd+2+12*i
            guard let tag=u16(header,off,little),
                  let type=u16(header,off+2,little),
                  let length=u32(header,off+4,little),
                  let value=u32(header,off+8,little)
            else { throw Failure.invalid("RAW TIFF IFD 条目损坏") }
            tags.append((tag,type,length,value,little))
        }
        return tags
    }


    /// Read a TIFF ASCII Make tag; 1–4 bytes are stored inline, longer
    /// strings use an offset. Do not interpret a header offset as text.
    private static func cameraMake(
        _ header:Data,
        _ entry:(tag:Int,type:Int,count:Int,value:Int,little:Bool)
    ) -> String? {
        guard entry.type==2, entry.count>=4,entry.count<=256 else {
            return nil
        }
        let bytes:[UInt8]
        if entry.count<=4 {
            if entry.little {
                bytes=(0..<entry.count).map {
                    UInt8(truncatingIfNeeded: entry.value >> (8*$0))
                }
            } else {
                bytes=(0..<entry.count).map {
                    UInt8(truncatingIfNeeded:
                        entry.value >> (8*(3-$0)))
                }
            }
        } else {
            guard entry.value>=0,
                  entry.value<=header.count-entry.count else {
                return nil
            }
            bytes=Array(
                header[entry.value..<(entry.value+entry.count)]
            )
        }
        guard let ascii=String(bytes:bytes,encoding:.ascii) else {
            return nil
        }
        return ascii.uppercased()
    }

    /// The scanner cannot certify compressed RAF, X-Trans demosaicing or
    /// Nikon NEF proprietary compression. It only identifies containers
    /// and preserves original file bytes for a later actual decoder.
    static func classify(
        filename:String,header:Data
    ) throws -> Kind? {
        let ext=(filename as NSString).pathExtension.lowercased()
        guard possiblyRAW.contains(ext) else { return nil }
        guard let kind=Kind(rawValue:ext) else {
            throw Failure.invalid(
                "识别到尚未移植的 RAW 扩展名 .\(ext)；禁止当作 JPEG/HEIC 处理"
            )
        }
        switch kind {
        case .raf:
            let sig=Array("FUJIFILMCCD-RAW ".utf8)
            try require(header.count>=16 && Array(header.prefix(16))==sig,
                        "RAF 扩展名与 Fujifilm RAW 原文件头不符")
        case .cr3:
            let head=Array(header.prefix(12))
            try require(head.count==12 &&
                        Array(head[4..<8])==Array("ftyp".utf8) &&
                        Array(head[8..<12])==Array("crx ".utf8),
                        "CR3 缺少 Canon crx ISO-BMFF RAW 品牌，不能取代为容器预览")
        case .dng:
            let tags=try tiffIFD(header)
            // DNGVersion (0xC612) is a four-byte, INLINE TIFF BYTE value.
            // A zero-filled field is not a genuine DNG header. Both TIFF
            // byte orders are supported, without interpreting TIFF data
            // as an embedded thumbnail.
            guard let version=tags.first(where:{
                $0.tag==50706 && $0.type==1 && $0.count==4
            }) else {
                throw Failure.invalid(
                    "DNG TIFF 缺少有效 DNGVersion BYTE[4] 标记"
                )
            }
            let major=version.little
                ? (version.value & 0xff)
                : ((version.value >> 24) & 0xff)
            try require(major==1,
                "DNGVersion 不是已验证的 1.x 文件；拒绝伪造或未知版本")
        case .cr2:
            // Canon CR2: TIFF header, "CR" bytes at offsets 8–9,
            // raw format version 2.0 at 10–11 and IFD3 pointer at 12.
            // This identifies the container, not Lossless JPEG RAW.
            let little:Bool
            switch Array(header.prefix(4)) {
            case [0x49,0x49,0x2a,0x00]: little=true
            case [0x4d,0x4d,0x00,0x2a]: little=false
            default: throw Failure.invalid("CR2 TIFF 文件头非法")
            }
            guard header.count>=16,
                  header[8]==0x43,header[9]==0x52,
                  header[10]==2,header[11]==0,
                  let ifd0=u32(header,4,little),ifd0>=16,
                  let rawIFD=u32(header,12,little),rawIFD>=16 else {
                throw Failure.invalid(
                    "CR2 缺少 Canon CR 2.0 文件标记或有效 IFD 指针"
                )
            }
        case .nef,.arw:
            let tags=try tiffIFD(header)
            guard let maker=tags.first(where:{$0.tag==0x010f}),
                  let brand=cameraMake(header,maker) else {
                throw Failure.invalid(
                    "NEF/ARW TIFF Make 元数据丢失或越界，拒绝猜测"
                )
            }
            let expected=kind == .nef ? "NIKON" : "SONY"
            try require(brand.contains(expected),
                "\(kind.rawValue.uppercased()) TIFF Make 不是 \(expected)，拒绝误识别")
        }
        return kind
    }

    static func probeFile(_ url:URL) throws -> Kind? {
        let name=url.lastPathComponent
        let ext=url.pathExtension.lowercased()
        guard possiblyRAW.contains(ext) else { return nil }
        let file=try FileHandle(forReadingFrom:url)
        defer { try? file.close() }
        let prefix=try file.read(upToCount:512*1024) ?? Data()
        return try classify(filename:name,header:prefix)
    }
}
