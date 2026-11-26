import Foundation

/// Build139: PRE-OPTICAL preview input geometry only.
///
/// A full source-quality export NEVER calls this helper. It consumes real
/// LibRaw ACES16 RGB data (not the DNG JPEG), quantizes each UInt16 through
/// the exact existing Float32 -> Double mapping and averages LINEAR samples.
/// Spatial optics/grain on the smaller grid are an intentionally approximate
/// preview; no claim of pixel parity with full-resolution optical development.
enum Build139RAWPreviewDownsample {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    struct Frame {
        let width: Int
        let height: Int
        let rgb: [Double]
    }

    // OPT-01: a single immutable pre-optical preview, never rendered RGB.
    // Cache size is independent of the source/optical image limits.
    struct CacheKey: Equatable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let bytes: UInt64
        let modified: Date
        let crop: [Int]
        let maxLongEdge: Int

        static func make(url: URL, crop: [Int], maxLongEdge: Int) -> CacheKey? {
            let file = url.standardizedFileURL
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let device = attrs[.systemNumber] as? NSNumber,
                  let inode = attrs[.systemFileNumber] as? NSNumber,
                  let bytes = attrs[.size] as? NSNumber,
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return CacheKey(path: file.path, device: device.uint64Value,
                            inode: inode.uint64Value, bytes: bytes.uint64Value,
                            modified: modified, crop: crop, maxLongEdge: maxLongEdge)
        }
    }

    struct CachedInput {
        let key: CacheKey
        let reduced: Frame
        let sourceWidth: Int
        let sourceHeight: Int
    }

    final class InputCache {
        private let lock = NSLock()
        private var entry: CachedInput?
        private var generation: UInt64 = 0
        private let maximumBytes = 40 * 1024 * 1024

        func lookup(_ key: CacheKey) -> CachedInput? {
            lock.lock()
            defer { lock.unlock() }
            guard entry?.key == key else { return nil }
            return entry
        }

        func store(_ value: CachedInput, generation expected: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            guard expected == generation, !Task.isCancelled,
                  value.reduced.rgb.count <= maximumBytes / MemoryLayout<Double>.stride
            else { return }
            entry = value
        }

        // Capture the generation at the start of a miss. A memory
        // warning, source invalidation or export can revoke that lease.
        @discardableResult
        func clear() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            entry = nil
            return generation
        }
    }

    // Full-resolution cache is a separate, single-entry lease. It never
    // stores a developed Float64 frame or a reduced preview. A caller owns
    // the cached value during rendering, not a second cache reference.
    struct FullSourceKey: Equatable {
        let metadata: CacheKey
        let sha256: String
    }

    final class FullInputCache<Value> {
        private let lock=NSLock()
        private var entry:(key:FullSourceKey,value:Value)?
        private var generation:UInt64=0
        // Record only fixed disposition labels, never source identity.
        private var lastDisposition="cold"

        func begin() -> UInt64 {
            lock.lock()
            defer {lock.unlock()}
            generation &+= 1
            return generation
        }

        func take(_ key:FullSourceKey?,generation expected:UInt64) -> Value? {
            takeWithDisposition(key,generation:expected).value
        }

        func takeWithDisposition(_ key:FullSourceKey?,generation expected:UInt64)
            -> (value:Value?,reason:String) {
            lock.lock()
            defer {lock.unlock()}
            guard expected==generation else {return (nil,"lease_revoked")}
            let reason:String
            if key==nil {reason="identity_unavailable"}
            else if entry==nil {reason=lastDisposition}
            else if entry?.key != key {reason="identity_changed"}
            else {reason="hit"}
            let value = key != nil && entry?.key==key ? entry?.value : nil
            entry=nil
            lastDisposition=value == nil ? reason : "consumed"
            return (value,reason)
        }

        @discardableResult
        func store(_ value:Value,key:FullSourceKey,generation expected:UInt64,
                   canRetain:Bool) -> String {
            lock.lock()
            defer {lock.unlock()}
            // A stale job cannot overwrite the newer lease's disposition.
            guard expected==generation else {return "lease_revoked"}
            guard !Task.isCancelled else {return "cancelled"}
            guard canRetain else {
                if entry==nil {lastDisposition="headroom_policy"}
                return "headroom_policy"
            }
            entry=(key,value)
            lastDisposition="stored"
            return "stored"
        }

        func clear(reason:String="explicit_clear") {
            lock.lock()
            defer {lock.unlock()}
            generation &+= 1
            entry=nil
            lastDisposition=reason
        }
    }

    private struct Tap {
        let index: Int
        let weight: Double
    }

    private static func taps(source: Int, target: Int) -> [[Tap]] {
        let scale = Double(source) / Double(target)
        return (0..<target).map { pixel in
            let start = Double(pixel) * scale
            let end = Double(pixel + 1) * scale
            let first = Int(start.rounded(.down))
            let last = Int(end.rounded(.up))
            return (first..<last).compactMap { sample -> Tap? in
                guard sample >= 0, sample < source else { return nil }
                let overlap = min(end,Double(sample+1)) -
                              max(start,Double(sample))
                return overlap > 0
                    ? Tap(index:sample,weight:overlap/scale)
                    : nil
            }
        }
    }

    static func frame(
        packedRGB16: Data,
        width: Int,
        height: Int,
        maxLongEdge: Int = 1280
    ) throws -> Frame {
        // OPT-04: input is packed decoder geometry, not the optical grid.
        // Match native LibRaw's retained decode boundary; preview output
        // remains bounded independently by maxLongEdge.
        guard width > 0, height > 0, width <= 10_000, height <= 10_000,
              width <= 45_000_000 / height,
              maxLongEdge >= 256, maxLongEdge <= 2048,
              packedRGB16.count == width*height*3*2 else {
            throw Failure.invalid(
                "RAW 快速预览输入不合法；只接受真实完整 ACES16 缓冲，禁止 JPEG 替代"
            )
        }
        try Task.checkCancellation()
        let factor = min(1.0,Double(maxLongEdge)/Double(max(width,height)))
        let outW = max(1,min(width,Int((Double(width)*factor).rounded())))
        let outH = max(1,min(height,Int((Double(height)*factor).rounded())))
        let count = outW*outH*3
        var rgb = [Double](repeating:0,count:count)

        // For tiny RAWs (no resize), retain the exact existing integer
        // -> Float32 / 65535 -> Double path with no additional averaging.
        if outW == width && outH == height {
            try packedRGB16.withUnsafeBytes { bytes in
                let input=bytes.bindMemory(to:UInt8.self)
                for i in 0..<count {
                    if i & 4095 == 0 { try Task.checkCancellation() }
                    let v=UInt16(input[i*2]) |
                        (UInt16(input[i*2+1]) << 8)
                    rgb[i]=Double(Float(v)/Float(65535.0))
                }
            }
            return Frame(width:outW,height:outH,rgb:rgb)
        }
        // Area-overlap source sampling: no full-sized Float64 image is ever
        // allocated for the preview. Intermediate values stay Double and
        // luminance/color are never gamma-encoded or clipped.
        let xt=taps(source:width,target:outW)
        let yt=taps(source:height,target:outH)
        try packedRGB16.withUnsafeBytes { bytes in
            let input=bytes.bindMemory(to:UInt8.self)
            for y in 0..<outH {
                try Task.checkCancellation()
                for x in 0..<outW {
                    let dst=(y*outW+x)*3
                    for row in yt[y] {
                        for col in xt[x] {
                            let src=(row.index*width+col.index)*6
                            let weight=row.weight*col.weight
                            for ch in 0..<3 {
                                let off=src+ch*2
                                let v=UInt16(input[off]) |
                                    (UInt16(input[off+1]) << 8)
                                rgb[dst+ch] +=
                                    Double(Float(v)/Float(65535.0))*weight
                            }
                        }
                    }
                }
            }
        }
        return Frame(width:outW,height:outH,rgb:rgb)
    }
}
