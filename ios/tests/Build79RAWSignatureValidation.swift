import Foundation
import CryptoKit

/// Build79: real byte-level backend routing before ImageIO/CIImage.
/// Synthetic headers test ONLY strict classification and RAW preservation;
/// do not claim any camera's mosaics, compressed RAF, or rawpy parity.
enum Build79RAWSignatureValidation {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case .invalid(let message)=self { return message }
            return nil
        }
    }

    private static func tiff(_ tag:Int,_ type:Int,
                             _ valueCount:Int,_ offset:Int,
                             extra:Data=Data()) -> Data {
        var result=Data(repeating:0,count:128)
        result[0]=0x49;result[1]=0x49;result[2]=0x2a
        result[4]=8;result[8]=1 // one IFD0 entry
        let start=10
        let fields:[(Int,Int,Int)]=[
            (0,tag,2),(2,type,2),(4,valueCount,4),(8,offset,4)
        ]
        for (relative,value,nbytes) in fields {
            for i in 0..<nbytes {
                result[start+relative+i]=UInt8(
                    truncatingIfNeeded:value>>(8*i)
                )
            }
        }
        if !extra.isEmpty {
            for i in extra.indices { result[64+i]=extra[i] }
        }
        return result
    }

    static func evaluate() throws {
        var raf=Data("FUJIFILMCCD-RAW ".utf8)
        raf.append(Data(repeating:0,count:112))
        var cr3=Data([0,0,0,24])
        cr3.append(Data("ftypcrx ".utf8))
        cr3.append(Data(repeating:0,count:116))
        let dng=tiff(50706,1,4,0x00000401)
        let nef=tiff(0x010f,2,6,64,extra:Data("NIKON\0".utf8))
        let arw=tiff(0x010f,2,5,64,extra:Data("SONY\0".utf8))
        var cr2=Data(repeating:0,count:128)
        cr2[0]=0x49; cr2[1]=0x49; cr2[2]=0x2a
        cr2[4]=16
        cr2[8]=0x43; cr2[9]=0x52 // "CR"
        cr2[10]=2; cr2[11]=0
        cr2[12]=64 // IFD3 offset
        var dngBig=Data(repeating:0,count:128)
        dngBig[0]=0x4d;dngBig[1]=0x4d;dngBig[3]=0x2a
        dngBig[7]=8; dngBig[9]=1 // big-endian one-entry IFD
        dngBig[10]=0xc6;dngBig[11]=0x12 // DNGVersion
        dngBig[13]=1;dngBig[17]=4 // BYTE[4]
        dngBig[18]=1;dngBig[19]=4 // version 1.4.0.0
        for (name,data,kind) in [
            ("X-T5.RAF",raf,Build79RAWSignature.Kind.raf),
            ("EOS-R.cr3",cr3,.cr3),
            ("Apple-ProRAW.dng",dng,.dng),
            ("Nikon.Z9.NEF",nef,.nef),
            ("Canon-5D.CR2",cr2,.cr2),
            ("Sony-A7.ARW",arw,.arw),
            ("big-endian.dng",dngBig,.dng)
        ] {
            guard try Build79RAWSignature.classify(
                filename:name,header:data
            )==kind else {
                throw Failure.invalid("Source RAW signature not classified: "+name)
            }
        }

        var fake=Data([0xff,0xd8,0xff,0xe0])
        fake.append(Data(repeating:0,count:100))
        for (name,data) in [
            ("renamed.dng",fake),
            ("renamed.raf",fake),
            ("renamed.cr3",fake),
            ("renamed.nef",fake),
            ("renamed.cr2",fake),
            ("renamed.arw",fake),
            ("no-dng-version.dng",tiff(0x010f,2,6,64)),
            ("zero-dng-version.dng",tiff(50706,1,4,0)),
            ("wrong-brand.arw",nef),
            ("wrong-brand.nef",arw)
        ] {
            var rejected=false
            do {
                _=try Build79RAWSignature.classify(
                    filename:name,header:data
                )
            } catch { rejected=true }
            guard rejected else {
                throw Failure.invalid(
                    "RAW import wrongly accepted spoofed header "+name
                )
            }
        }
        var unknownRejected=false
        do {
            _=try Build79RAWSignature.classify(
                filename:"Olympus.orf",header:fake
            )
        } catch { unknownRejected=true }
        guard unknownRejected else {
            throw Failure.invalid("Unported Olympus ORF must fail explicitly")
        }
        guard try Build79RAWSignature.classify(
            filename:"not-raw.jpg",header:fake
        )==nil else {
            throw Failure.invalid("JPEG must not enter RAW importer")
        }

        // On-disk copy MUST equal true source byte for byte.
        let temp=FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString+".RAF")
        try raf.write(to:temp,options:.atomic)
        defer {try? FileManager.default.removeItem(at:temp)}
        guard try Build79RAWSignature.probeFile(temp) == .raf else {
            throw Failure.invalid("Real file RAF identification failed")
        }
        let result=try Build79RAWStorage.preserve(temp,kind:.raf)
        defer {try? FileManager.default.removeItem(at:result.url)}
        let copy=try Data(contentsOf:result.url)
        let hash=SHA256.hash(data:raf).map {
            String(format:"%02x",$0)
        }.joined()
        guard copy==raf,result.sha256==hash,
              result.bytes==Int64(raf.count) else {
            throw Failure.invalid(
                "Original RAW import changed bytes/length/hash"
            )
        }
        // A real Apple CIRAWFilter cannot be used on a merely JPEG input.
        // Verify the native probe refuses it BEFORE opening the decoder,
        // rather than returning a CIImage from embedded/ordinary JPEG.
        let jpeg=FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString+".jpg")
        try fake.write(to:jpeg,options:.atomic)
        defer { try? FileManager.default.removeItem(at:jpeg) }
        var jpegRejected=false
        do { _=try Build79NativeRAWBackend.probe(jpeg) }
        catch { jpegRejected=true }
        guard jpegRejected else {
            throw Failure.invalid(
                "Apple RAW backend probe must reject ordinary JPEG"
            )
        }
        print(
            "PASS Build79 6 RAW source signatures "
            + "(RAF/CR3/DNG/NEF/CR2/ARW, plus big-endian DNG), "
            + "11 disguised/invalid header rejections, "
            + "unsupported RAW fail closed, non-RAW intact; "
            + "RAF file stream-copy SHA256 identical. "
            + "NO demosaic or numeric RAW backend equivalence claimed."
        )
    }
}
