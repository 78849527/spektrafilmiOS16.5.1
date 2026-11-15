import Foundation

/// Exact original ICC embedding after native ImageIO has encoded pixels.
/// CoreGraphics may NORMALIZE the ICC tag (observed: source 9552 bytes,
/// saved 9436 bytes), so CGColorSpace.copyICCData cannot certify
/// source-EXACT embedded bytes. Patch the actual JPEG APP2 / PNG iCCP /
/// classic TIFF ICCProfile tag 34675; then re-parse actual disk container.
/// Preserves every unrelated EXIF/IPTC/JPEG segment and TIFF IFD entry.
/// Source XMP preservation beyond ImageIO is NOT certified by this file.
enum Build90OriginalICCContainer {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String?{
            if case let .invalid(message)=self{return message}
            return nil
        }
    }
    private static let prefix:[UInt8]=Array("ICC_PROFILE\0".utf8)
    private static let pngMagic:[UInt8]=[
        137,80,78,71,13,10,26,10
    ]
    private static func read32BE(_ b:[UInt8],_ i:Int)throws->Int {
        guard i>=0,i<=b.count-4 else {
            throw Failure.invalid("Malformed PNG/ICC binary length")
        }
        return Int(b[i])<<24|Int(b[i+1])<<16|
               Int(b[i+2])<<8|Int(b[i+3])
    }
    private static func append32BE(_ n:UInt32,_ out:inout [UInt8]) {
        out.append(UInt8((n>>24)&255))
        out.append(UInt8((n>>16)&255))
        out.append(UInt8((n>>8)&255))
        out.append(UInt8(n&255))
    }
    private static func crc32(_ bytes:[UInt8])->UInt32 {
        var crc:UInt32=0xffffffff
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc&1)==1 ? (crc>>1)^0xedb88320 :crc>>1
            }
        }
        return ~crc
    }
    private static func zlibStored(_ content:[UInt8])->[UInt8] {
        // RFC1950 zlib with RFC1951 uncompressed DEFLATE blocks.
        // Deterministic, no dependency on lossy or OS-specific compressors.
        var out:[UInt8]=[0x78,0x01]
        var start=0
        repeat {
            let amount=min(65535,content.count-start)
            let isFinal=(start+amount==content.count)
            let n=UInt16(amount)
            out.append(isFinal ? 1:0)
            out.append(UInt8(n&255))
            out.append(UInt8(n>>8))
            let inverted=~n
            out.append(UInt8(inverted&255))
            out.append(UInt8(inverted>>8))
            out.append(contentsOf:content[start..<start+amount])
            start+=amount
        } while start<content.count
        var a:UInt32=1,b:UInt32=0
        for v in content {
            a=(a+UInt32(v))%65521
            b=(b+a)%65521
        }
        append32BE((b<<16)|a,&out)
        return out
    }
    private static func decodeZlibStored(
        _ compressed:[UInt8]
    )throws->[UInt8] {
        guard compressed.count>=7,compressed[0]==0x78,
              (Int(compressed[0])*256+Int(compressed[1]))%31==0 else {
            throw Failure.invalid("Actual PNG iCCP ZLIB header invalid")
        }
        var at=2,out=[UInt8](),done=false
        while !done {
            guard at+5<=compressed.count-4 else {
                throw Failure.invalid("Actual PNG source ICC deflate truncated")
            }
            let flag=compressed[at];at+=1
            guard (flag&0x06)==0 else {
                throw Failure.invalid("Expected our deterministic raw deflate ICC")
            }
            done=(flag&1)==1
            let n=Int(compressed[at])|Int(compressed[at+1])<<8
            let inv=Int(compressed[at+2])|Int(compressed[at+3])<<8
            at+=4
            guard n ^ inv == 65535,at+n<=compressed.count-4 else {
                throw Failure.invalid("Actual PNG source ICC block length mismatch")
            }
            out.append(contentsOf:compressed[at..<at+n])
            at+=n
        }
        let expected=try read32BE(compressed,at)
        guard at+4==compressed.count else {
            throw Failure.invalid("PNG source ICC zlib trailing data")
        }
        var a:UInt32=1,b:UInt32=0
        for v in out {
            a=(a+UInt32(v))%65521
            b=(b+a)%65521
        }
        guard (b<<16)|a==UInt32(expected) else {
            throw Failure.invalid("Actual PNG source ICC Adler32 mismatch")
        }
        return out
    }

    private static func jpegSegments(
        _ bytes:[UInt8]
    ) throws->[(Int,Int,UInt8)] {
        guard bytes.count>=4,bytes[0]==255,bytes[1]==216 else {
            throw Failure.invalid("Not actual JPEG SOI")
        }
        var positions=[(Int,Int,UInt8)]()
        var at=2
        while at<bytes.count {
            guard bytes[at]==255,at+1<bytes.count else {
                throw Failure.invalid("JPEG marker malformed")
            }
            let start=at
            while at<bytes.count && bytes[at]==255 {at+=1}
            guard at<bytes.count else {
                throw Failure.invalid("JPEG marker stream truncated")
            }
            let marker=bytes[at];at+=1
            if marker==0xda || marker==0xd9 {
                positions.append((start,bytes.count,marker))
                break
            }
            guard at+2<=bytes.count else {
                throw Failure.invalid("JPEG segment length truncated")
            }
            let len=Int(bytes[at])<<8 | Int(bytes[at+1])
            guard len>=2,at+len<=bytes.count else {
                throw Failure.invalid("JPEG marker length invalid")
            }
            positions.append((start,at+len,marker))
            at+=len
        }
        guard !positions.isEmpty else {
            throw Failure.invalid("JPEG missing segment structure")
        }
        return positions
    }
    private static func jpegICC(_ byte:[UInt8])throws->[UInt8] {
        var chunks=[Int:[UInt8]](),total=0
        for (begin,end,marker) in try jpegSegments(byte) {
            guard marker==0xe2 else{continue}
            let markerEnd=begin+2
            guard markerEnd+2<=end else{continue}
            let start=markerEnd+2
            guard start+prefix.count+2<=end,
                  Array(byte[start..<start+prefix.count])==prefix else {
                continue
            }
            let sequence=Int(byte[start+prefix.count])
            let count=Int(byte[start+prefix.count+1])
            guard count>0,count<=255,sequence>0,sequence<=count,
                  (total==0 || total==count),
                  chunks[sequence]==nil else {
                throw Failure.invalid("JPEG ICC APP2 segment ordering invalid")
            }
            total=count
            chunks[sequence]=Array(byte[(start+prefix.count+2)..<end])
        }
        guard total>0,chunks.count==total else {
            throw Failure.invalid("No complete source ICC JPEG APP2 segments")
        }
        var result=[UInt8]()
        for i in 1...total { result+=chunks[i]! }
        return result
    }
    private static func embedJPEG(
        _ original:[UInt8],_ icc:[UInt8]
    )throws->[UInt8] {
        let chunks=(icc.count+65518)/65519
        guard chunks>0,chunks<=255 else {
            throw Failure.invalid("Source ICC exceeds valid JPEG APP2 limits")
        }
        var out:[UInt8]=[0xff,0xd8]
        for chunk in 0..<chunks {
            let from=chunk*65519,to=min(icc.count,from+65519)
            let payload=prefix+[
                UInt8(chunk+1),UInt8(chunks)
            ]+Array(icc[from..<to])
            let length=payload.count+2
            out.append(contentsOf:[
                0xff,0xe2,UInt8((length>>8)&255),UInt8(length&255)
            ])
            out+=payload
        }
        for (start,end,marker) in try jpegSegments(original) {
            if marker==0xe2 {
                let content=start+4
                if content+prefix.count<=end,
                   Array(original[content..<content+prefix.count])==prefix {
                    continue
                }
            }
            out.append(contentsOf:original[start..<end])
        }
        return out
    }

    private static func pngChunks(
        _ bytes:[UInt8]
    )throws->[(Int,Int,String)] {
        guard bytes.count>=20,
              Array(bytes.prefix(8))==pngMagic else {
            throw Failure.invalid("Not a PNG with real signature")
        }
        var chunks=[(Int,Int,String)](),pos=8
        while pos<bytes.count {
            let size=try read32BE(bytes,pos)
            guard size>=0,size<=bytes.count-pos-12 else {
                throw Failure.invalid("PNG chunk out of bounds")
            }
            let end=pos+size+12
            let type=String(
                bytes:bytes[(pos+4)..<(pos+8)],encoding:.ascii
            ) ?? ""
            chunks.append((pos,end,type))
            pos=end
            if type=="IEND" {break}
        }
        guard chunks.first?.2=="IHDR",chunks.last?.2=="IEND",
              chunks.last!.1==bytes.count else {
            throw Failure.invalid("Invalid PNG chunk ordering/IEND")
        }
        return chunks
    }
    private static func buildPNGChunk(
        _ type:String,_ content:[UInt8]
    )throws->[UInt8] {
        guard let magic=type.data(using:.ascii),magic.count==4,
              content.count<=Int(UInt32.max) else {
            throw Failure.invalid("Invalid PNG ICC chunk type/size")
        }
        var out=[UInt8]()
        append32BE(UInt32(content.count),&out)
        let crcContent=Array(magic)+content
        out+=crcContent
        append32BE(crc32(crcContent),&out)
        return out
    }
    private static func embedPNG(
        _ original:[UInt8],_ icc:[UInt8]
    )throws->[UInt8] {
        var result=pngMagic
        let zlib=zlibStored(icc)
        let value=Array("SpektraFilm ICC".utf8)+[0,0]+zlib
        let newICC=try buildPNGChunk("iCCP",value)
        for (start,end,type) in try pngChunks(original) {
            if type=="iCCP" || type=="sRGB" {continue}
            result.append(contentsOf:original[start..<end])
            if type=="IHDR" {result+=newICC}
        }
        return result
    }
    private static func pngICC(_ byte:[UInt8])throws->[UInt8] {
        let chunks=try pngChunks(byte)
        let profiles=chunks.filter{$0.2=="iCCP"}
        guard profiles.count==1 else {
            throw Failure.invalid("PNG must contain exactly one original iCCP")
        }
        let p=profiles[0]
        let content=Array(byte[(p.0+8)..<(p.1-4)])
        guard let terminator=content.firstIndex(of:0),
              terminator>0,terminator+1<content.count,
              content[terminator+1]==0 else {
            throw Failure.invalid("Actual PNG iCCP name/compression invalid")
        }
        return try decodeZlibStored(Array(content[(terminator+2)...]))
    }

    private struct TIFF {
        let little:Bool
        let iccEntry:Int
        let bytes:[UInt8]
        init(_ bytes:[UInt8])throws {
            guard bytes.count>=16 else {
                throw Failure.invalid("Actual TIFF too short")
            }
            let le=bytes[0]==73 && bytes[1]==73
            let be=bytes[0]==77 && bytes[1]==77
            guard le || be else {
                throw Failure.invalid("Not actual little/big endian TIFF")
            }
            self.little=le
            self.bytes=bytes
            func r16(_ pos:Int)->Int {
                le ? Int(bytes[pos])|Int(bytes[pos+1])<<8 :
                Int(bytes[pos])<<8|Int(bytes[pos+1])
            }
            func r32(_ pos:Int)->Int {
                le ? Int(bytes[pos])|Int(bytes[pos+1])<<8|
                     Int(bytes[pos+2])<<16|Int(bytes[pos+3])<<24 :
                Int(bytes[pos])<<24|Int(bytes[pos+1])<<16|
                     Int(bytes[pos+2])<<8|Int(bytes[pos+3])
            }
            guard r16(2)==42 else {
                throw Failure.invalid(
                    "BigTIFF/unsupported TIFF IFD layout not certified"
                )
            }
            let offset=r32(4)
            guard offset>=8,offset<=bytes.count-2 else {
                throw Failure.invalid("Original TIFF IFD offset invalid")
            }
            let n=r16(offset)
            guard n>=1,n<4096,
                  offset+2+n*12<=bytes.count else {
                throw Failure.invalid("Original TIFF IFD entries invalid")
            }
            var entry:Int?
            for i in 0..<n {
                let pos=offset+2+i*12
                if r16(pos)==34675 {
                    guard entry==nil else {
                        throw Failure.invalid("Multiple TIFF ICC tags")
                    }
                    entry=pos
                }
            }
            guard let entry else {
                throw Failure.invalid("TIFF original ICCProfile tag missing")
            }
            self.iccEntry=entry
        }
        func r16(_ i:Int)->Int {
            little ? Int(bytes[i])|Int(bytes[i+1])<<8 :
                Int(bytes[i])<<8|Int(bytes[i+1])
        }
        func r32(_ i:Int)->Int {
            little ? Int(bytes[i])|Int(bytes[i+1])<<8|
                Int(bytes[i+2])<<16|Int(bytes[i+3])<<24 :
                Int(bytes[i])<<24|Int(bytes[i+1])<<16|
                Int(bytes[i+2])<<8|Int(bytes[i+3])
        }
        func write32(_ val:Int,_ out:inout [UInt8],_ at:Int)throws {
            guard val>=0,val<=Int(UInt32.max),
                  at+4<=out.count else {
                throw Failure.invalid("TIFF ICC count/offset exceeds 4 GB")
            }
            for j in 0..<4 {
                let shift=little ? j*8 : (3-j)*8
                out[at+j]=UInt8((val>>shift)&255)
            }
        }
        func embedded()throws->[UInt8] {
            let count=r32(iccEntry+4),offset=r32(iccEntry+8)
            guard (r16(iccEntry+2)==7 || r16(iccEntry+2)==1),
                  count>=128,offset>=0,
                  offset<=bytes.count-count else {
                throw Failure.invalid("Actual TIFF ICC tag size/offset invalid")
            }
            return Array(bytes[offset..<offset+count])
        }
        func patched(_ icc:[UInt8])throws->[UInt8] {
            var bytes=self.bytes
            if bytes.count%2 != 0 {bytes.append(0)}
            let newOffset=bytes.count
            bytes+=icc
            try write32(icc.count,&bytes,iccEntry+4)
            try write32(newOffset,&bytes,iccEntry+8)
            return bytes
        }
    }
    static func embed(
        sourceICC:Data,inEncoded file:Data,
        format:Build90SourceOutputQuantization.FileFormat
    )throws->Data {
        let icc=[UInt8](sourceICC),bytes=[UInt8](file)
        let output:[UInt8]
        switch format {
        case .jpeg:output=try embedJPEG(bytes,icc)
        case .png:output=try embedPNG(bytes,icc)
        case .tiff:output=try TIFF(bytes).patched(icc)
        case .exr:
            throw Failure.invalid("EXR must not receive fake ICC container")
        }
        let direct=try extract(
            from:Data(output),format:format
        )
        guard direct==sourceICC else {
            throw Failure.invalid(
                "Actual image container failed original ICC raw-byte validation"
            )
        }
        return Data(output)
    }
    static func extract(
        from file:Data,
        format:Build90SourceOutputQuantization.FileFormat
    )throws->Data {
        let bytes=[UInt8](file)
        switch format {
        case .jpeg:return Data(try jpegICC(bytes))
        case .png:return Data(try pngICC(bytes))
        case .tiff:return Data(try TIFF(bytes).embedded())
        case .exr:throw Failure.invalid("EXR native ICC not supported")
        }
    }
}
