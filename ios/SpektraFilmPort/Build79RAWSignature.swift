import Foundation

/// Build79/09 source RAW FILE identification ONLY.
/// This is not a demosaic, colour transform, rawpy replacement,
/// or a claim that the operating system supports decoding that camera.
/// Reject extension/spoofed-header mismatches before CIImage/thumbnail
/// can quietly turn a RAW file into an unrelated embedded JPEG preview.
enum Build79RAWSignature {
    enum Kind:String,CaseIterable {
        case dng,raf,cr3,nef
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
            try require(tags.contains {
                $0.tag==50706 && $0.type==1 && $0.count==4
            }, "DNG TIFF 原始数据缺少 DNGVersion 标记；不是已验证 DNG")
        case .nef:
            let tags=try tiffIFD(header)
            guard let maker=tags.first(where:{$0.tag==0x010f}) else {
                throw Failure.invalid("NEF 无 Nikon TIFF Make 元数据，拒绝猜测")
            }
            try require(maker.type==2 && maker.count>5 &&
                        maker.count<256 && maker.value<=header.count-maker.count,
                        "NEF Nikon Make 字符串越界或无效")
            let begin=maker.value,end=begin+maker.count
            let brand=String(
                bytes:Array(header[begin..<end]),encoding:.ascii
            )?.uppercased() ?? ""
            try require(brand.contains("NIKON"),
                        "NEF TIFF Maker 不是 Nikon，拒绝按 NEF 解码")
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
