import Foundation

/// Exact source utils/io.py save_image_oiio numeric output domains.
/// JPEG/PNG: uint8 regardless requested bit_depth; TIFF 8,16,32;
/// EXR: binary16 or binary32 raw. This is source NUMERIC conversion,
/// NOT a claim that iOS can encode native OpenEXR without a codec.
enum Build90SourceOutputQuantization {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(s)=self{return s}
            return nil
        }
    }
    enum FileFormat:String,CaseIterable {
        case jpeg,png,tiff,exr
        var extensionName:String {
            switch self {
            case .jpeg:return "jpg"
            case .png:return "png"
            case .tiff:return "tiff"
            case .exr:return "exr"
            }
        }
    }
    enum Storage:String {
        case uint8,uint16
        case float16="half"
        case float32="float"
        var bitsPerChannel:Int {
            switch self {
            case .uint8:return 8
            case .uint16,.float16:return 16
            case .float32:return 32
            }
        }
    }
    struct Specification {
        let format:FileFormat
        let bitDepth:Int
        let storage:Storage
        init(format:FileFormat,bitDepth:Int) throws {
            self.format=format
            self.bitDepth=bitDepth
            switch format {
            case .jpeg,.png:
                // Exactly source: these ignore caller's bit depth,
                // without converting a TIFF-16 request to PNG-16.
                storage = .uint8
            case .tiff:
                switch bitDepth {
                case 8:storage = .uint8
                case 16:storage = .uint16
                case 32:storage = .float32
                default:throw Failure.invalid(
                    "原版 TIFF 仅允许 8/16/32，每种分别为 U8/U16/F32"
                )
                }
            case .exr:
                switch bitDepth {
                case 16:storage = .float16
                case 32:storage = .float32
                default:throw Failure.invalid(
                    "原版 EXR 仅允许 Float16 或 Float32，不能用 8bit 冒充"
                )
                }
            }
        }
    }
    static func quantize(
        _ rgb:[Double],as spec:Specification
    ) throws->[Double] {
        guard rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "源输出有 NaN/Inf，拒绝将其当成真实 uint8/EXR 成功"
            )
        }
        return rgb.map {v in
            switch spec.storage {
            case .uint8:
                return Double(UInt8((min(1,max(0,v))*255).rounded(.towardZero)))
            case .uint16:
                return Double(UInt16((min(1,max(0,v))*65535).rounded(.towardZero)))
            case .float16:
                return Double(Float16(v))
            case .float32:
                return Double(Float(v))
            }
        }
    }
    /// Bytes are little-endian for Float16/32 and big-endian for
    /// integer 16 CGImage. This helper does NOT create a fake EXR file.
    static func packed(
        _ rgb:[Double],as spec:Specification
    ) throws->Data {
        let bpc=spec.storage.bitsPerChannel/8
        guard rgb.count <= Int.max/bpc else {
            throw Failure.invalid("输出缓冲区溢出")
        }
        guard rgb.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid(
                "源输出有 NaN/Inf，拒绝将其当成真实 uint8/EXR 成功"
            )
        }
        // Build136 memory audit: write the exact source quantization
        // directly to the packed buffer. The previous quantize() call
        // allocated an unnecessary full-frame [Double] (24 B/px RGB).
        // Preserve source rounding, component order and byte order.
        var data=Data(capacity:rgb.count*bpc)
        for value in rgb {
            switch spec.storage {
            case .uint8:
                data.append(UInt8(
                    (min(1,max(0,value))*255).rounded(.towardZero)
                ))
            case .uint16:
                let v=UInt16(
                    (min(1,max(0,value))*65535).rounded(.towardZero)
                )
                data.append(UInt8((v>>8)&255))
                data.append(UInt8(v&255))
            case .float16:
                let v=Float16(value).bitPattern
                data.append(UInt8(v&255))
                data.append(UInt8((v>>8)&255))
            case .float32:
                let v=Float(value).bitPattern
                for shift in stride(from:0,to:32,by:8) {
                    data.append(UInt8((v>>shift)&255))
                }
            }
        }
        return data
    }
}
