import Foundation
import CryptoKit
#if os(iOS)
import os
#endif

/// P1 candidate input for original rawpy 'as_shot' RAW path.
/// This is a genuine sensor LibRaw 16-bit linear ACES2065-1 output, not
/// Apple CIRAWFilter, sRGB, a JPEG sidecar, or a Float32 TIFF compatibility copy.
/// Same parameters alone do not certify rawpy pixel parity: check same LibRaw
/// build, demosaic, matrix, WB, orientation and Python reference frame first.
enum P1OriginalRawACESIngress {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    // OPT-02: only one editor RAW decode/develop/encode operation may own
    // the large working buffers. Cancellation is checked on both sides of
    // lock acquisition; LibRaw itself cannot be interrupted mid-native call.
    private static let editorRAWLock = NSLock()
    private static let previewInputCache = Build139RAWPreviewDownsample.InputCache()
    private static let fullInputCache = Build139RAWPreviewDownsample.FullInputCache<Source>()

    static func withExclusiveRAWWork<T>(operation:String="raw_editor",_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        let queued=ProcessInfo.processInfo.systemUptime
        editorRAWLock.lock()
        defer { editorRAWLock.unlock() }
        try Task.checkCancellation()
        return try OPTDeviceFeedback.measure(operation,
            queueWait:ProcessInfo.processInfo.systemUptime-queued,body)
    }

    static func clearPreviewInputCache() {
        previewInputCache.clear()
    }

    static func clearAllInputCaches(reason:String="source_invalidation") {
        previewInputCache.clear()
        fullInputCache.clear(reason:reason)
    }

    struct Source {
        let width: Int
        let height: Int
        let packedRGB16: Data
        let decoderVersion: String
        let colorSpace = "ACES2065-1"
        let sourceCCTFEncoded = false
    }

    static func open(
        _ url: URL, maximumAllowedPixels: Int = 0
    ) throws -> Source {
        try Task.checkCancellation()
        guard try Build79RAWSignature.probeFile(url) != nil else {
            throw Failure.invalid("P1: 文件不是可验证的真实 RAW；不读内嵌 JPEG")
        }
        // The native bridge rejects unsupported cameras, compression and
        // insufficient memory instead of switching to Apple RAW/sRGB/RGB8.
        let result = try SFBuild94LibRaw.decode(
            url, bitsPerComponent: 16, sourceLinearACES: true,
            maximumAllowedPixels: maximumAllowedPixels
        )
        try Task.checkCancellation()
        let w = result.width, h = result.height
        guard result.bitsPerComponent == 16,
              w > 0, h > 0, w <= 10_000, h <= 10_000,
              w <= 45_000_000 / h else {
            throw Failure.invalid("P1: LibRaw ACES 返回位深或尺寸非法")
        }
        let bytes = result.rgb8 as Data
        guard bytes.count == w * h * 3 * 2 else {
            throw Failure.invalid("P1: 16-bit ACES RGB 通道字节数错误")
        }
        return Source(width: w, height: h, packedRGB16: bytes,
                      decoderVersion: result.decoder)
    }

    // Hash the real source in bounded chunks; identical file metadata
    // alone is insufficient for a full-precision export cache hit.
    // A missing identity disables reuse, never substitutes a preview.
    private static func fullSourceKey(_ url:URL) throws
        -> Build139RAWPreviewDownsample.FullSourceKey? {
        try Task.checkCancellation()
        guard let before=Build139RAWPreviewDownsample.CacheKey.make(
            url:url,crop:[],maxLongEdge:0
        ) else {return nil}
        do {
            let file=try FileHandle(forReadingFrom:url)
            defer {try? file.close()}
            var hash=SHA256()
            while true {
                try Task.checkCancellation()
                let bytes=try file.read(upToCount:1024*1024) ?? Data()
                if bytes.isEmpty {break}
                hash.update(data:bytes)
            }
            guard before==Build139RAWPreviewDownsample.CacheKey.make(
                url:url,crop:[],maxLongEdge:0
            ) else {return nil}
            return .init(metadata:before,sha256:hash.finalize().map {
                String(format:"%02x",$0)
            }.joined())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func openFullEditorSource(
        _ url:URL,maximumAllowedPixels:Int
    ) throws -> (source:Source,key:Build139RAWPreviewDownsample.FullSourceKey?,generation:UInt64) {
        let generation=fullInputCache.begin()
        let key=try fullSourceKey(url)
        let lookup=fullInputCache.takeWithDisposition(key,generation:generation)
        if let cached=lookup.value {
            // No new native allocation on hit; the decoded bytes are
            // already resident. Keep the full-grid admission contract.
            guard cached.width>0,cached.height>0,
                  cached.width<=10_000,cached.height<=10_000,
                  cached.width<=45_000_000/cached.height,
                  cached.packedRGB16.count==cached.width*cached.height*6,
                  maximumAllowedPixels>=0,
                  maximumAllowedPixels==0 ||
                    cached.width<=maximumAllowedPixels/cached.height else {
                throw Failure.invalid("RAW 缓存几何超出当前光学输入范围；不缩图")
            }
            try Task.checkCancellation()
            OPTDeviceFeedback.mark("full_cache_hit",["width":String(cached.width),"height":String(cached.height)])
            return (cached,key,generation)
        }
        OPTDeviceFeedback.mark("full_cache_miss_decode_begin",["reason":lookup.reason])
        let source=try open(url,maximumAllowedPixels:maximumAllowedPixels)
        OPTDeviceFeedback.mark("decode_done",["width":String(source.width),"height":String(source.height)])
        let verifiedKey=try fullSourceKey(url)
        // A changed readable source is not a trustworthy decode cache.
        // Reject actual identity change rather than display stale bytes.
        if let key,let verifiedKey,key != verifiedKey {
            throw Failure.invalid("RAW 在解码过程中发生变化；请重新打开原片")
        }
        return (source,key==verifiedKey ? key : nil,generation)
    }

    private static func retainFullEditorSource(
        _ source:Source,key:Build139RAWPreviewDownsample.FullSourceKey?,
        generation:UInt64
    ) {
        guard let key,!Task.isCancelled else {
            OPTDeviceFeedback.mark("full_cache_retention_policy",
                ["eligible":"false","disposition":Task.isCancelled ? "cancelled" : "identity_unavailable"])
            return
        }
        // This is only a cache-retention heuristic, NOT a render limit.
        // Live headroom already excludes the currently resident buffer.
        // Retain at most one packed ACES16 buffer if ample margin remains.
        #if os(iOS)
        let headroom=UInt64(os_proc_available_memory())
        #else
        let headroom=ProcessInfo.processInfo.physicalMemory/3
        #endif
        let eligible=headroom>0 && UInt64(source.packedRGB16.count)<=headroom/5
        let disposition=fullInputCache.store(source,key:key,generation:generation,canRetain:eligible)
        OPTDeviceFeedback.mark("full_cache_retention_policy",["eligible":String(eligible),
            "disposition":disposition,"packedBytes":String(source.packedRGB16.count)])
    }

    private static func recordOpticalOptions(_ p:OriginalSourcePhysicalImage.Parameters,cropped:Bool) {
        OPTDeviceFeedback.mark("optical_options",[
            "cameraEV":String(p.cameraEV),"paperEV":String(p.paperEV),
            "cropped":String(cropped),"grain":String(p.sourceGrain.active),
            "grainSublayers":String(p.sourceGrain.sublayersActive),
            "grainFastStats":String(p.sourceGrain.useFastStats),
            "grainUnseededParallel":String(p.sourceGrain.useUnseededParallel),
            "cameraOptics":String(p.cameraOptics.active),
            "halation":String(p.filmHalation.active),
            "printDiffusion":String(p.printDiffusion.active),
            "scannerGlare":String(p.scannerGlare.active),
            "scannerOptics":String(p.scannerOptics.active),
            "sourceOutputGamut":String(p.sourceOutputGamut != nil),
            "outputCCTF":String(p.sourceOutputCCTFEncoding),
            "dir":String(p.sourceDIR?.active ?? p.sourceCouplersActive),
            "cameraRawMethod":p.cameraRawMethod.rawValue
        ])
    }

    struct PreviewWithGeometry {
        let frame:OriginalSourcePixelIO.Frame
        let sourceWidth:Int
        let sourceHeight:Int
    }

    /// No Float64 source frame is ever created before the user-confirmed
    /// packed-ACES16 crop. The immutable original file and saved LibRaw
    /// decoder output remain untouched.
    private static func selectedSource(
        _ decoded:Source,crop:Build141RAWPreCrop.Selection?
    ) throws -> Source {
        guard let crop else {return decoded}
        try crop.validate()
        guard crop.sourceWidth==decoded.width,crop.sourceHeight==decoded.height else {
            throw Failure.invalid("RAW 裁切源几何已变化")
        }
        #if os(iOS)
        // The native decode is already committed. Admit only the new
        // packed crop allocation before copying; do not credit future frees.
        if !crop.isWholeSource {
            let bytes=UInt64(crop.width)*UInt64(crop.height)*6
            let headroom=UInt64(os_proc_available_memory())
            guard headroom>0,bytes<=(headroom/10)*8 else {
                throw Failure.invalid("RAW 裁切 ACES16 缓冲内存不足；不缩图")
            }
        }
        #endif
        let bytes=try Build141RAWPreCrop.cropPackedRGB16(
            decoded.packedRGB16,
            sourceWidth:decoded.width,sourceHeight:decoded.height,
            selection:crop
        )
        return Source(width:crop.width,height:crop.height,
                      packedRGB16:bytes,decoderVersion:decoded.decoderVersion)
    }

    /// Diagnostic-only full original optical engine call from a preserved RAW
    /// file. The decoder and image are NEVER passed through Apple CI or TIFF.
    /// Critical: this does NOT establish rawpy/LibRaw equality; it is not
    /// connected to the user-facing "原版精确" selector until the Python tap
    /// comparison and real iPhoneOS hardware gates pass.
    ///
    /// Unlike the old flow, a caller receives the actual source-space pixel
    /// frame, and the existing original film/paper/scanner engine is reused.
    /// No new optical approximation, LUT substitution or mode fallback.
    static func developSourceCandidate(
        _ rawURL: URL, opticalSettings: OriginalSourcePhysicalImage.Parameters,
        crop:Build141RAWPreCrop.Selection? = nil,
        retainDecodedSource:Bool = false
    ) throws -> OriginalSourcePixelIO.Frame {
        var selected = opticalSettings
        // Python raw_file_processor outputs linear ACES2065-1 by default;
        // ensure its samples can NEVER enter a display-sRGB transfer function.
        selected.cameraInputColorSpace = .acesLinear
        try selected.validate()
        // Uncropped full optics retain the current work-grid ceiling.
        // A confirmed crop instead admits the native decoder geometry
        // independently; the cropped work grid still passes the full gate.
        clearPreviewInputCache()
        if let crop { try crop.validate() }
        let acquisition=try openFullEditorSource(
            rawURL,
            maximumAllowedPixels: crop == nil ? OriginalSourcePhysicalImage.maximumPixels : 0
        )
        let decoded=acquisition.source
        // Build141: geometry and memory are based on selected RAW pixels,
        // NOT the final JPEG/TIFF size; this is before original-wide Double.
        let working=try selectedSource(decoded,crop:crop)
        OPTDeviceFeedback.mark("full_optical_admission",["width":String(working.width),
            "height":String(working.height),"film":selected.filmID,"paper":selected.paperID])
        recordOpticalOptions(selected,cropped:crop != nil)
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:working.width,height:working.height,parameters:selected
        )
        var frame = try makeSourceFrame(
            working, maximumAllowedPixels: OriginalSourcePhysicalImage.maximumPixels
        )
        OPTDeviceFeedback.mark("float64_input_ready")
        try OriginalSourcePhysicalImage.developInPlace(
            &frame, parameters: selected,
            phaseMemoryObserver:{OPTDeviceFeedback.mark($0)}
        )
        OPTDeviceFeedback.mark("optics_done")
        // Full preview may keep the original packed input; JPEG/TIFF
        // export consumes it and does not refill the cache. Always rerun
        // all optical stages, including the original random streams.
        if retainDecodedSource {
            retainFullEditorSource(decoded,key:acquisition.key,
                                   generation:acquisition.generation)
        }
        return frame
    }

    /// Build139: automatic speed-oriented preview ONLY. Full JPEG/TIFF16
    /// export always uses developSourceCandidate() unchanged. It first
    /// decodes the real full sensor RAW as ACES16, averages those LINEAR
    /// samples into a bounded preview frame without creating a full Double
    /// image, then runs the SAME source Float64 optical engine on that grid.
    /// The spatial grain/halation result is not pixel-identical to a full
    /// optical render subsequently reduced for display.
    static func developPreviewCandidate(
        _ rawURL:URL,
        opticalSettings:OriginalSourcePhysicalImage.Parameters,
        maxLongEdge:Int=1280
    ) throws -> OriginalSourcePixelIO.Frame {
        try developPreviewWithGeometry(
            rawURL,opticalSettings:opticalSettings,maxLongEdge:maxLongEdge
        ).frame
    }

    /// The reference geometry belongs to the FULL LibRaw frame even when
    /// a small preview is requested; the visual crop sheet needs these exact
    /// coordinates and must not guess from Apple RAW/JPEG orientation.
    static func developPreviewWithGeometry(
        _ rawURL:URL,
        opticalSettings:OriginalSourcePhysicalImage.Parameters,
        maxLongEdge:Int=1280,
        crop:Build141RAWPreCrop.Selection?=nil
    ) throws -> PreviewWithGeometry {
        var selected=opticalSettings
        selected.cameraInputColorSpace = .acesLinear
        try selected.validate()
        // OPT-01: reuse only the original Build139 linear input; all
        // optical settings are applied anew. Full preview/export never use it.
        // Do not stack an unused full-size cache with a quick preview.
        fullInputCache.clear(reason:"switch_to_quick_preview")
        try Task.checkCancellation()
        let cropKey = crop.map {
            [$0.sourceWidth,$0.sourceHeight,$0.x,$0.y,$0.width,$0.height]
        } ?? []
        let key = Build139RAWPreviewDownsample.CacheKey.make(
            url:rawURL,crop:cropKey,maxLongEdge:maxLongEdge
        )
        let reduced: Build139RAWPreviewDownsample.Frame
        let sourceWidth: Int, sourceHeight: Int
        if let key, let cached = previewInputCache.lookup(key) {
            OPTDeviceFeedback.mark("preview_cache_hit")
            reduced = cached.reduced
            sourceWidth = cached.sourceWidth
            sourceHeight = cached.sourceHeight
        } else {
            let cacheGeneration=previewInputCache.clear()
            OPTDeviceFeedback.mark("preview_cache_miss_decode_begin")
            // Native LibRaw 45MP/10k and live pre-unpack budget still apply.
            // The small optical preview has its own post-reduction gate.
            let decoded=try open(
                rawURL,
                maximumAllowedPixels:0
            )
            OPTDeviceFeedback.mark("decode_done",["width":String(decoded.width),"height":String(decoded.height)])
            let working=try selectedSource(decoded,crop:crop)
            reduced=try Build139RAWPreviewDownsample.frame(
                packedRGB16:working.packedRGB16,
                width:working.width,height:working.height,
                maxLongEdge:maxLongEdge
            )
            sourceWidth=decoded.width
            sourceHeight=decoded.height
            try Task.checkCancellation()
            if let key, key == Build139RAWPreviewDownsample.CacheKey.make(
                url:rawURL,crop:cropKey,maxLongEdge:maxLongEdge
            ) {
                previewInputCache.store(.init(
                    key:key,reduced:reduced,
                    sourceWidth:decoded.width,sourceHeight:decoded.height
                ),generation:cacheGeneration)
            }
        }
        try Task.checkCancellation()
        OPTDeviceFeedback.mark("preview_optical_admission",["width":String(reduced.width),
            "height":String(reduced.height),"film":selected.filmID,"paper":selected.paperID])
        recordOpticalOptions(selected,cropped:crop != nil)
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:reduced.width,height:reduced.height,parameters:selected
        )
        var frame=OriginalSourcePixelIO.Frame(
            width:reduced.width,height:reduced.height,rgb:reduced.rgb
        )
        try OriginalSourcePhysicalImage.developInPlace(
            &frame,parameters:selected,phaseMemoryObserver:{OPTDeviceFeedback.mark($0)}
        )
        OPTDeviceFeedback.mark("optics_done")
        return PreviewWithGeometry(
            frame:frame,sourceWidth:sourceWidth,sourceHeight:sourceHeight
        )
    }

    /// Match original rawpy: np.float32(uint16) / np.float32(65535).
    /// Values are promoted to Double only after that source quantization.
    /// Caller must separately validate downstream memory and stage gamut.
    /// Never reinterpret these linear ACES values as encoded sRGB.
    static func makeSourceFrame(
        _ source: Source, maximumAllowedPixels: Int
    ) throws -> OriginalSourcePixelIO.Frame {
        try OriginalSourcePixelIO.validatePixelDimensions(
            width: source.width, height: source.height,
            maximumAllowedPixels: maximumAllowedPixels
        )
        let count = source.width * source.height * 3
        guard source.packedRGB16.count == count * 2 else {
            throw Failure.invalid("P1: RAW ACES 原始缓冲区长度改变")
        }
        try Task.checkCancellation()
        var rgb = [Double](repeating: 0, count: count)
        try source.packedRGB16.withUnsafeBytes { buffer in
            let p = buffer.bindMemory(to: UInt8.self)
            for i in 0..<count {
                if i & 4095 == 0 { try Task.checkCancellation() }
                let sample = UInt16(p[i*2]) | (UInt16(p[i*2+1]) << 8)
                rgb[i] = Double(Float(sample) / Float(65535.0))
            }
        }
        return OriginalSourcePixelIO.Frame(
            width: source.width, height: source.height, rgb: rgb
        )
    }
}
