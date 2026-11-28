import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
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
    // Distinct exact pre-grain caches; switching grids invalidates the other.
    private static let previewDensityCache = OriginalSourcePhysicalImage.FilmDensityReuse()
    private static let previewPaperDensityCache = OriginalSourcePhysicalImage.FilmDensityReuse()
    private static let fullDensityCache = OriginalSourcePhysicalImage.FilmDensityReuse()
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
        previewDensityCache.clear()
        previewPaperDensityCache.clear()
    }

    // Release only packed decoder input before throwing away the much
    // more valuable exact film density. No arithmetic headroom credit.
    static func clearPackedFullInputCache(reason:String) {
        fullInputCache.clear(reason:reason)
    }

    static func clearAllInputCaches(reason:String="source_invalidation") {
        clearPreviewInputCache()
        fullInputCache.clear(reason:reason)
        fullDensityCache.clear()
    }

    // Only called within the serialized export render, AFTER a possibly
    // cancelled preview has released its working arrays. Preserve the exact
    // confirmed dimensions, captured allowance, and fresh 70% gate.
    static func validateConfirmedExportPlan(_ plan:SafeExportResolution.Plan,
        rawURL:URL,opticalSettings:OriginalSourcePhysicalImage.Parameters,
        crop:Build141RAWPreCrop.Selection?) throws {
        if plan.committedSourceBytes>0 {
            let verified=try verifiedExportDensityBytes(rawURL,opticalSettings:opticalSettings,
                width:plan.sourceWidth,height:plan.sourceHeight,crop:crop)
            try SafeExportResolution.validateBeforeRender(plan,verifiedCommittedSourceBytes:verified)
            OPTDeviceFeedback.mark("export_hot_plan_admitted",["verifiedCommittedSourceBytes":String(verified),
                "estimatedPeakBytes":String(plan.estimatedPeakBytes)])
            return
        }
        try SafeExportResolution.retryAfterCacheEviction(
            attempt:{try SafeExportResolution.validateBeforeRender(plan)},
            isMemoryRefusal:{$0 is SafeExportResolution.Failure},
            evict:{
                let before=SafeExportResolution.currentProcessHeadroom()
                clearPackedFullInputCache(reason:"confirmed_export_packed_pressure")
                if (try? SafeExportResolution.validateBeforeRender(plan)) == nil {
                    clearAllInputCaches(reason:"confirmed_export_pressure")
                }
                OPTDeviceFeedback.mark("export_optional_cache_evicted",[
                    "headroomBefore":before.map{String($0)} ?? "unavailable",
                    "headroomAfter":SafeExportResolution.currentProcessHeadroom().map{String($0)} ?? "unavailable"])
            })
        OPTDeviceFeedback.mark("export_plan_admitted",[
            "estimatedPeakBytes":String(plan.estimatedPeakBytes),
            "capturedAllowanceBytes":String(plan.allocationAllowanceBytes),
            "width":String(plan.dimensions.width),"height":String(plan.dimensions.height)])
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

    // Hash actual verified packed RAW samples with the exact normalization
    // used by makeSourceFrame, without a second full Double allocation.
    static func verifiedExportDensityBytes(_ rawURL:URL,
        opticalSettings:OriginalSourcePhysicalImage.Parameters,width:Int,height:Int,
        crop:Build141RAWPreCrop.Selection?) throws -> UInt64 {
        guard crop==nil,SafeExportResolution.currentProcessHeadroom() != nil,
              let identity=try fullSourceKey(rawURL),
              let packed=fullInputCache.matchingValue(identity),
              packed.width==width,packed.height==height,width>0,height>0,
              packed.packedRGB16.count==width*height*6 else{return 0}
        var p=opticalSettings
        p.cameraInputColorSpace = .acesLinear
        p.enableFullOpticalDensityCache=true
        let seeded=p.sourceGrain.active && p.sourceGrain.sublayersActive
        guard OriginalSourcePhysicalImage.canReuseFilmDensity(p,allowSeededGrain:seeded) else{return 0}
        let lease=fullDensityCache.lease()
        let normalizedHash=try normalizedRGBSHA256(packed)
        let key=try OriginalSourcePhysicalImage.filmDensityReuseKey(
            inputSHA256:normalizedHash,width:width,height:height,parameters:p,
            allowSeededGrain:seeded)
        guard let density=fullDensityCache.matchingDensity(key,expectedGeneration:lease),
              density.count==width*height*3,
              try fullSourceKey(rawURL)==identity,
              fullDensityCache.hasEntry(expectedGeneration:lease) else{return 0}
        return UInt64(density.count)*8
    }

    private static func normalizedRGBSHA256(_ source:Source) throws -> [UInt8] {
        guard source.width>0,source.height>0,source.width<=Int.max/source.height/6,
              source.packedRGB16.count==source.width*source.height*6 else {
            throw Failure.invalid("RAW packed hash geometry mismatch")
        }
        var hash=SHA256()
        var chunk=[Double](repeating:0,count:4096)
        try source.packedRGB16.withUnsafeBytes {buffer in
            let bytes=buffer.bindMemory(to:UInt8.self)
            let count=source.width*source.height*3
            for start in stride(from:0,to:count,by:chunk.count) {
                try Task.checkCancellation()
                let n=min(chunk.count,count-start)
                for j in 0..<n {
                    let i=(start+j)*2
                    let sample=UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)
                    chunk[j]=Double(Float(sample)/Float(65535.0))
                }
                chunk.withUnsafeBytes {raw in
                    hash.update(bufferPointer:UnsafeRawBufferPointer(start:raw.baseAddress,count:n*8))
                }
            }
        }
        return Array(hash.finalize())
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

    /// Record modeled full-plane payload alongside the existing 25ms
    /// measured footprint/RSS and actual phase boundaries. Do not apply
    /// this model to one-layer, unseeded parallel, or non-grain renders.
    private static func recordSerialGrainLifetime(
        _ p:OriginalSourcePhysicalImage.Parameters,width:Int,height:Int,
        cacheAdmitted:Bool
    ) {
        guard p.sourceGrain.active,p.sourceGrain.sublayersActive,
              !p.sourceGrain.useUnseededParallel,width>0,height>0 else{return}
        let pixelUM=p.dir.referencePixelSizeUM ??
            (p.cameraOptics.filmFormatMM*1000.0/Double(max(width,height)))
        guard pixelUM.isFinite,pixelUM>0 else{return}
        let pixels=UInt64(width)*UInt64(height)
        guard let life=Build106SourceMemoryLedger.serialGrainLifetime(
            pixels:pixels,dyeCloud:p.sourceGrain.dyeCloudBlurUM>0,
            microstructure:p.sourceGrain.microstructureNM*0.001/pixelUM>0.05,
            microBlur:p.sourceGrain.microstructureUM/pixelUM>0.4,
            finalBlur:p.sourceGrain.grainBlur>0) else{return}
        let admission=OriginalSourcePhysicalImage.memoryEnvelope(width:width,height:height,parameters:p)
        let measuredReduction=admission.additionalBytesPerPixel==56
        OPTDeviceFeedback.mark("grain_lifetime_model",[
            "scope":"logical_serial_3x3_payload_not_measured_RSS",
            "pixels":String(pixels),"pixelUM":String(pixelUM),
            "inputBytes":String(life.inputBytes),"outputBytes":String(life.outputBytes),
            "layerBytes":String(life.layerBytes),"probabilityBytes":String(life.probabilityBytes),
            "ratesBytes":String(life.ratesBytes),"countBytes":String(life.countBytes),
            "cloudBytes":String(life.cloudBytes),
            "particlePhaseBytes":String(life.particlePhaseBytes),
            "releasedScratchBytes":String(life.releasedScratchBytes),
            "microstructurePhaseBytes":life.microstructurePhaseBytes.map{String($0)} ?? "inactive",
            "finalBlurPhaseBytes":life.finalBlurPhaseBytes.map{String($0)} ?? "inactive",
            "logicalPeakBytes":String(life.logicalPeakBytes),
            "optionalDensityCacheBudgetBytes":String(cacheAdmitted ? pixels*24 : 0),
            "admissionChanged":String(measuredReduction),
            "admittedAdditionalBytesPerPixel":String(admission.additionalBytesPerPixel),
            "countPlaneStorage":"reused_rate_Int64_bits",
            "admissionBasis":measuredReduction ? "Build152_measured_8B_reduction_only" : "unchanged_conservative"])
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
        retainDecodedSource:Bool = false,
        consumeConfirmedDensity:Bool = false
    ) throws -> OriginalSourcePixelIO.Frame {
        var selected = opticalSettings
        // Python raw_file_processor outputs linear ACES2065-1 by default;
        // ensure its samples can NEVER enter a display-sRGB transfer function.
        selected.cameraInputColorSpace = .acesLinear
        selected.enableFullOpticalDensityCache=true
        try selected.validate()
        // Uncropped full optics retain the current work-grid ceiling.
        // A confirmed crop instead admits the native decoder geometry
        // independently; the cropped work grid still passes the full gate.
        clearPreviewInputCache()
        var densityLease=fullDensityCache.lease()
        var keepDensity=false
        // Export may consume an existing full preview density, but never
        // retain a new export cache. Errors/cancellation release the entry.
        defer {if !keepDensity {fullDensityCache.clear()}}
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
        let envelope=OriginalSourcePhysicalImage.memoryEnvelope(
            width:working.width,height:working.height,parameters:selected)
        let opticalPlan=try Build91PhysicalMemory.plan(
            width:working.width,height:working.height,
            baseBytesPerPixel:OriginalSourcePhysicalImage.estimatedPeakBytesPerPixel,
            additionalBytesPerPixel:envelope.additionalBytesPerPixel,
            physicalMemory:ProcessInfo.processInfo.physicalMemory,
            processAvailable:SafeExportResolution.currentProcessHeadroom(),
            camera:envelope.cameraDiffusion,paper:envelope.paperDiffusion,
            compactSequentialFFT:envelope.compactSequentialFFT)
        var phaseDetails:[String:String]=[
            "compactSequentialFFT":String(envelope.compactSequentialFFT),
            "nonFFTBytes":String(opticalPlan.basePeakBytes),
            "fftScratchAndPSFBytes":String(opticalPlan.additionalFFTBytes),
            "estimatedPeakBytes":String(opticalPlan.estimatedPeakBytes),
            "allowedBytes":String(opticalPlan.allowedBytes),
            "phasesBPP":envelope.phaseModel.phases.map{"\($0.phase):\($0.bytesPerPixel)"}.joined(separator:",")]
        if let camera=opticalPlan.cameraFFT {
            phaseDetails["cameraFFTGrid"]="\(camera.fftWidth)x\(camera.fftHeight)"
            phaseDetails["cameraPSFRadius"]=String(camera.radius)
        }
        if let paper=opticalPlan.paperFFT {
            phaseDetails["paperFFTGrid"]="\(paper.fftWidth)x\(paper.fftHeight)"
            phaseDetails["paperPSFRadius"]=String(paper.radius)
        }
        OPTDeviceFeedback.mark("full_optical_phase_plan",phaseDetails)
        // Build152 actual uncropped RAW cold/hot SHA256 matched both
        // fixed-seed serial SciPy and fixed-seed serial FastStats.
        // canReuseFilmDensity still enforces seed equality for FastStats
        // and excludes the unseeded workers. Never cache grain output.
        let allowSeededFull=selected.sourceGrain.active &&
            selected.sourceGrain.sublayersActive
        if consumeConfirmedDensity {
            guard crop==nil,!retainDecodedSource,acquisition.key != nil else {
                throw Failure.invalid("原尺寸导出缓存已失效；请重新确认导出")
            }
            try OriginalSourcePhysicalImage.validateMemoryBudget(width:working.width,height:working.height,parameters:selected)
            var frame = try makeSourceFrame(working,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels)
            OPTDeviceFeedback.mark("float64_input_ready")
            OPTDeviceFeedback.mark("full_density_cache_policy",["eligible":"true","reason":"confirmed_one_shot_export",
                "retainPreview":"false","requiredHotHit":"true"])
            recordSerialGrainLifetime(selected,width:working.width,height:working.height,cacheAdmitted:false)
            try OriginalSourcePhysicalImage.developInPlace(&frame,parameters:selected,
                phaseMemoryObserver:{OPTDeviceFeedback.mark($0)},filmDensityReuse:fullDensityCache,
                filmDensityReuseLease:densityLease,allowSeededGrainDensityReuse:allowSeededFull,
                consumeExistingFilmDensity:true)
            try Task.checkCancellation()
            OPTDeviceFeedback.mark("optics_done")
            return frame
        }
        let densityBytes=UInt64(working.width)*UInt64(working.height)*24
        let retainedBytes=densityBytes+UInt64(decoded.packedRGB16.count)
        let eligible=crop==nil &&
            OriginalSourcePhysicalImage.canReuseFilmDensity(selected,allowSeededGrain:allowSeededFull)
        var reuseAllowed=false
        var requireHotHit=false
        var reuseReason="unsupported_parameters"
        if !eligible || acquisition.key==nil ||
            fullDensityCache.lease() != densityLease ||
            (!retainDecodedSource && !fullDensityCache.hasEntry(expectedGeneration:densityLease)) ||
            !canRetainPreviewDensity(bytes:retainedBytes) {
            if eligible {reuseReason="identity_lease_or_retention"}
            densityLease=fullDensityCache.clear(expectedGeneration:densityLease)
        } else {
            reuseAllowed=true
            reuseReason="candidate"
        }
        // First admit the unmodified optical job. The optional existing
        // cache can be evicted to make room, never reduce render quality.
        do {
            try OriginalSourcePhysicalImage.validateMemoryBudget(
                width:working.width,height:working.height,parameters:selected)
        } catch {
            guard reuseAllowed else {throw error}
            fullDensityCache.clear(expectedGeneration:densityLease)
            reuseAllowed=false
            reuseReason="baseline_headroom_eviction"
            try OriginalSourcePhysicalImage.validateMemoryBudget(
                width:working.width,height:working.height,parameters:selected)
        }
        var frame = try makeSourceFrame(
            working, maximumAllowedPixels: OriginalSourcePhysicalImage.maximumPixels
        )
        OPTDeviceFeedback.mark("float64_input_ready")
        if reuseAllowed {
            let key=try OriginalSourcePhysicalImage.filmDensityReuseKey(
                frame:frame,parameters:selected,allowSeededGrain:allowSeededFull)
            // Strong actual matching snapshot across the live budget query.
            // No credit for a stale key, alias, or unallocated future scratch.
            let existing=fullDensityCache.matchingDensity(key,expectedGeneration:densityLease)
            defer {withExtendedLifetime(existing) {}}
            let existingBytes:UInt64
            if let existing,existing.count==frame.rgb.count,
               existing.withUnsafeBufferPointer({ cache in
                   frame.rgb.withUnsafeBufferPointer { input in cache.baseAddress != input.baseAddress }
               }) {
                existingBytes=UInt64(existing.count)*8
                requireHotHit=true
            } else {
                existingBytes=0
                densityLease=fullDensityCache.clear(expectedGeneration:densityLease)
                // Export never builds a fresh cache on a miss.
                if !retainDecodedSource {reuseAllowed=false;reuseReason="export_key_miss"}
            }
            if reuseAllowed && fullDensityCache.lease() != densityLease {
                reuseAllowed=false
                requireHotHit=false
                reuseReason="lease_invalidated"
            }
            if reuseAllowed {
                let envelope=OriginalSourcePhysicalImage.memoryEnvelope(
                    width:working.width,height:working.height,parameters:selected)
                do {
                    try OriginalSourcePhysicalImage.validateMemoryBudget(
                        width:working.width,height:working.height,
                        additionalBytesPerPixel:envelope.additionalBytesPerPixel+24,
                        alreadyCommittedInputBytes:UInt64(frame.rgb.count)*8+existingBytes,
                        cameraDiffusion:envelope.cameraDiffusion,paperDiffusion:envelope.paperDiffusion,
                        compactSequentialFFT:envelope.compactSequentialFFT,
                        retainedFFTBytesPerPixel:envelope.compactSequentialFFT ? 24 : 0)
                    reuseReason=requireHotHit ? "verified_owned_hot_cache" : "cold_cache_admitted"
                } catch {
                    reuseAllowed=false
                    requireHotHit=false
                    reuseReason="cache_memory_admission"
                }
            }
        }
        if !reuseAllowed {fullDensityCache.clear(expectedGeneration:densityLease)}
        OPTDeviceFeedback.mark("full_density_cache_policy",[
            "eligible":String(reuseAllowed),"reason":reuseReason,
            "densityBytes":String(densityBytes),"retainPreview":String(retainDecodedSource),
            "seededSciPy":String(allowSeededFull && !selected.sourceGrain.useFastStats),
            "seededFastStats":String(allowSeededFull && selected.sourceGrain.useFastStats),
            "requiredHotHit":String(requireHotHit)])
        recordSerialGrainLifetime(selected,width:working.width,height:working.height,
                                  cacheAdmitted:reuseAllowed)
        // Build158 no grain/halation and Build159 full seeded grain/halation
        // real 3024x4032 RAW, both 8192x8192 FFTs: full Double SHA matched.
        // Only cold compact routes with the measured grain modes qualify.
        let verifiedPlain = !selected.sourceGrain.active && !selected.filmHalation.active
        let verifiedFull = selected.sourceGrain.active && selected.sourceGrain.sublayersActive &&
            !selected.sourceGrain.useUnseededParallel && !selected.sourceGrain.useFastStats &&
            selected.sourceGrain.numbaSeed==8888 && selected.filmHalation.active
        let useVerifiedFFT = !retainDecodedSource && !reuseAllowed && crop==nil &&
            working.width==3024 && working.height==4032 &&
            envelope.compactSequentialFFT && (verifiedPlain || verifiedFull) &&
            opticalPlan.cameraFFT?.fftWidth==8192 && opticalPlan.cameraFFT?.fftHeight==8192 &&
            opticalPlan.paperFFT?.fftWidth==8192 && opticalPlan.paperFFT?.fftHeight==8192
        let useVerifiedScan=useVerifiedFFT && verifiedFull
        OPTDeviceFeedback.mark("production_fft_policy",[
            "workers":useVerifiedFFT ? "2" : "1",
            "reuseIdenticalRows":String(useVerifiedFFT),
            "postDiffusionScanWorkers":useVerifiedScan ? "2" : "1",
            "scope":useVerifiedFFT ? (verifiedFull ? "verified_12MP_two_diffusions_seeded_grain_halation" : "verified_12MP_two_diffusions_no_grain_no_halation") : "serial_reference"])
        try OriginalSourcePhysicalImage.developInPlace(
            &frame, parameters: selected,
            phaseMemoryObserver:{OPTDeviceFeedback.mark($0)},
            filmDensityReuse:reuseAllowed ? fullDensityCache : nil,
            filmDensityReuseLease:reuseAllowed ? densityLease : nil,
            allowSeededGrainDensityReuse:allowSeededFull,
            requireExistingFilmDensity:reuseAllowed && requireHotHit,
            diffusionFFTWorkers:useVerifiedFFT ? 2 : 1,
            reuseIdenticalDiffusionKernelRows:useVerifiedFFT,
            postDiffusionScanWorkers:useVerifiedScan ? 2 : 1
        )
        try Task.checkCancellation()
        OPTDeviceFeedback.mark("optics_done")
        // Retain only a successful preview, subject to combined live margin.
        // Export, errors and cancelled operations release the density.
        keepDensity=retainDecodedSource && reuseAllowed &&
            fullDensityCache.hasEntry(expectedGeneration:densityLease &+ 1) &&
            canRetainPreviewDensity(bytes:retainedBytes)
        OPTDeviceFeedback.mark("full_density_retention_policy",["retained":String(keepDensity)])
        // The independent packed ACES16 cache keeps its original policy.
        if retainDecodedSource {
            retainFullEditorSource(decoded,key:acquisition.key,
                                   generation:acquisition.generation)
        }
        return frame
    }

    /// OPT-15: isolated full-grid RAW diagnostic, never a production cache.
    /// No RGB output frames are retained between trials: compare SHA256
    /// over every actual Float64 byte (including signed zero), rather
    /// than holding an additional full reference frame in device memory.
    static func runFullDensityReuseComparison(
        _ rawURL:URL,opticalSettings:OriginalSourcePhysicalImage.Parameters
    ) throws -> Bool {
        var selected=opticalSettings
        selected.cameraInputColorSpace = .acesLinear
        selected.enableFullOpticalDensityCache=true
        try selected.validate()
        let allowSeededDiagnostic=selected.sourceGrain.active
        guard OriginalSourcePhysicalImage.canReuseFilmDensity(selected,allowSeededGrain:allowSeededDiagnostic) else {
            throw Failure.invalid("原尺寸缓存对照需要受支持的负片 Hanatos 串行设置；颗粒必须使用受控种子")
        }
        clearAllInputCaches(reason:"full_density_diagnostic")
        let session=OriginalSourcePhysicalImage.FilmDensityReuse()
        let initialLease=session.lease()
        #if canImport(UIKit)
        let warning=NotificationCenter.default.addObserver(
            forName:UIApplication.didReceiveMemoryWarningNotification,
            object:nil,queue:nil) { _ in session.clear() }
        defer {NotificationCenter.default.removeObserver(warning)}
        #endif
        defer {session.clear()}
        guard let identity=try fullSourceKey(rawURL) else {
            throw Failure.invalid("原尺寸缓存对照无法确认 RAW 文件身份")
        }
        let source=try open(rawURL,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels)
        guard try fullSourceKey(rawURL)==identity else {
            throw Failure.invalid("原尺寸缓存对照 RAW 解码期间身份改变")
        }
        let w=source.width,h=source.height
        let bytes=UInt64(w)*UInt64(h)*24
        OPTDeviceFeedback.mark("full_density_compare_begin",[
            "width":String(w),"height":String(h),"cacheBytes":String(bytes),
            "grainFastStats":String(selected.sourceGrain.useFastStats),
            "grainUnseededParallel":String(selected.sourceGrain.useUnseededParallel),
            "scope":allowSeededDiagnostic
                ? "actual_uncropped_RAW_seeded_grain_SHA256_all_Float64_bytes"
                : "actual_uncropped_RAW_no_grain_SHA256_all_Float64_bytes"])
        var changed=selected
        // Downstream only, and explicitly reported. No saved user setting
        // is changed. This compares linear versus encoded scan output.
        changed.sourceOutputCCTFEncoding.toggle()

        func admit(_ params:OriginalSourcePhysicalImage.Parameters,cache:Bool,
                   existingLease:UInt64?=nil) throws {
            // An owned cache snapshot is already charged by OS headroom.
            // This credit is diagnostic-only; the renderer independently
            // matches the actual input SHA and pins a distinct buffer.
            let existing=existingLease.flatMap{session.existingDensity(expectedGeneration:$0)}
            if existingLease != nil {
                guard let existing,UInt64(existing.count)*8==bytes else {
                    throw Failure.invalid("原尺寸热缓存预检缺少有效已分配密度")
                }
            }
            let committed=existing.map{UInt64($0.count)*8} ?? 0
            defer {withExtendedLifetime(existing) {}}
            if cache {
                let envelope=OriginalSourcePhysicalImage.memoryEnvelope(width:w,height:h,parameters:params)
                try OriginalSourcePhysicalImage.validateMemoryBudget(
                    width:w,height:h,additionalBytesPerPixel:envelope.additionalBytesPerPixel+24,
                    alreadyCommittedInputBytes:committed,
                    cameraDiffusion:envelope.cameraDiffusion,paperDiffusion:envelope.paperDiffusion,
                    compactSequentialFFT:envelope.compactSequentialFFT,
                    retainedFFTBytesPerPixel:envelope.compactSequentialFFT ? 24 : 0)
            } else {
                try OriginalSourcePhysicalImage.validateMemoryBudget(width:w,height:h,parameters:params)
            }
        }
        func trial(_ name:String,_ params:OriginalSourcePhysicalImage.Parameters,
                   cache:Bool,expectedLease:UInt64?=nil,requireHit:Bool=false,consume:Bool=false) throws -> (digest:[UInt8],hit:Bool,stored:Bool,invalidated:Bool) {
            try Task.checkCancellation()
            OPTDeviceFeedback.mark("full_density_trial_begin",[
                "case":name,"cache":String(cache),"outputCCTF":String(params.sourceOutputCCTFEncoding),
                "requiredHotHit":String(requireHit),"ownedCacheCreditBytes":String(requireHit ? bytes : 0)])
            do {try admit(params,cache:cache,existingLease:requireHit ? expectedLease : nil)}
            catch {
                OPTDeviceFeedback.mark("full_density_admission_refused",["case":name,"error":error.localizedDescription])
                throw error
            }
            if let expectedLease,session.lease() != expectedLease {
                throw Failure.invalid("原尺寸缓存对照内存告警/代际失效")
            }
            var frame=try makeSourceFrame(source,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels)
            if name=="baseline_cold" {
                var fullHash=SHA256()
                frame.rgb.withUnsafeBytes {fullHash.update(bufferPointer:$0)}
                let streamEqual=try normalizedRGBSHA256(source)==Array(fullHash.finalize())
                OPTDeviceFeedback.mark("export_stream_hash_parity",["equal":String(streamEqual)])
                guard streamEqual else {throw Failure.invalid("RAW streaming input SHA mismatch")}
            }
            var phases=[String]()
            let sampler=Build133RAWMemoryLadder.RSSSampler()
            let start=ProcessInfo.processInfo.systemUptime
            let thermalBefore=ProcessInfo.processInfo.thermalState.rawValue
            sampler.start()
            do {
                try OriginalSourcePhysicalImage.developInPlace(
                    &frame,parameters:params,phaseMemoryObserver:{stage in
                        phases.append(stage)
                        OPTDeviceFeedback.mark("full_density_legacy_phase",["case":name,"phase":stage])
                    },filmDensityReuse:cache ? session : nil,
                    filmDensityReuseLease:expectedLease,
                    allowSeededGrainDensityReuse:allowSeededDiagnostic,
                    requireExistingFilmDensity:requireHit && !consume,
                    consumeExistingFilmDensity:consume)
            } catch {
                _=sampler.finish()
                throw error
            }
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            let samples=sampler.finish()
            try Task.checkCancellation()
            var hash=SHA256()
            frame.rgb.withUnsafeBytes {hash.update(bufferPointer:$0)}
            let digest=Array(hash.finalize())
            let hit=phases.contains("film_density_cache_hit")
            let stored=phases.contains("film_density_cache_stored")
            let invalidated=phases.contains("film_density_cache_store_invalidated") ||
                (cache && (consume ? (!phases.contains("export_density_cache_consumed") || session.hasEntry(expectedGeneration:session.lease())) : !session.hasEntry(expectedGeneration:session.lease())))
            if allowSeededDiagnostic && !phases.contains("three_sublayer_grain_ready") {
                throw Failure.invalid("原尺寸颗粒缓存对照未执行实际颗粒")
            }
            OPTDeviceFeedback.mark("full_density_trial_result",[
                "case":name,"seconds":String(elapsed),"hit":String(hit),"consumed":String(consume),
                "thermalBefore":String(thermalBefore),
                "thermalAfter":String(ProcessInfo.processInfo.thermalState.rawValue),
                "workers":String(params.deterministicPixelWorkers),
                "stageMask":String(params.deterministicPixelStageMask),
                "stored":String(stored),"invalidated":String(invalidated),
                "outputBytes":String(frame.rgb.count*8),
                "sampledPeakPhysicalFootprintBytes":samples.footprint.map{String($0)} ?? "not_measured",
                "sampledPeakRSSBytes":samples.peak.map{String($0)} ?? "not_measured",
                "sampledLowestHeadroomBytes":samples.lowest.map{String($0)} ?? "not_measured",
                "sampleCount":String(samples.count)])
            return (digest,hit,stored,invalidated)
        }
        // Both independent baselines run before any full density is retained.
        // Early optional-cache admission avoids long baselines when even the
        // cold candidate cannot fit. Recheck live admission at every trial.
        try admit(selected,cache:true)
        try admit(changed,cache:true)
        let baseline=try trial("baseline_cold",selected,cache:false)
        let baselineChanged=try trial("baseline_changed_CCTF",changed,cache:false)
        let cold=try trial("cache_cold",selected,cache:true,expectedLease:initialLease)
        guard !cold.hit,cold.stored,!cold.invalidated else {
            throw Failure.invalid("原尺寸缓存未成功保留或被内存告警清除")
        }
        // Credit only the actual matching owned CMY allocation, never
        // assumed scratch release. Live 80% headroom and full peak stay.
        let hotLease=session.lease()
        let hot=try trial("cache_hot_changed_CCTF",changed,cache:true,
                          expectedLease:hotLease,requireHit:true,consume:true)
        let coldEqual=cold.digest==baseline.digest
        let hotEqual=hot.digest==baselineChanged.digest
        session.clear()
        // The fixed reduced-grid diagnostic favored only print/scan on
        // two workers. Check real uncropped input and identical settings
        // against the earlier independent serial SHA; no cache here.
        var parallel=selected
        parallel.deterministicPixelWorkers=2
        parallel.deterministicPixelStageMask=4
        // Full optical diagnostic compares serial cold/hot only. The
        // legacy parallel renderer retains a larger FFT admission model;
        // it is not a required or promoted full-optics optimization.
        let complex=selected.cameraOptics.active || selected.filmHalation.active ||
            selected.printDiffusion.active || selected.scannerGlare.active || selected.scannerOptics.active
        let printEqual:Bool
        if complex {
            printEqual=true
            OPTDeviceFeedback.mark("full_density_parallel_skipped",["reason":"complex_optics_legacy_budget"])
        } else {
            let printTrial=try trial("parallel_print_full",parallel,cache:false)
            printEqual=printTrial.digest==baseline.digest
        }
        let passed=coldEqual && hotEqual && hot.hit && !hot.invalidated && printEqual
        OPTDeviceFeedback.mark("full_density_compare_result",[
            "passed":String(passed),"coldAllBytesSHA256Equal":String(coldEqual),
            "hotAllBytesSHA256Equal":String(hotEqual),"hotHit":String(hot.hit),"oneShotConsumed":"true",
            "productionEnabled":"false","cacheCleared":"true",
            "parallelPrintSHA256Equal":complex ? "not_tested" : String(printEqual),
            "fullOpticalCache":String(complex),
            "grainFastStats":String(selected.sourceGrain.useFastStats),
            "seededGrain":String(allowSeededDiagnostic)])
        return passed
    }

    /// Build158: independent original-size serial and two-worker JPEG
    /// exports. No preview or density cache. Only a SHA survives each trial.
    static func runFullExportFFTComparison(
        _ rawURL:URL,opticalSettings:OriginalSourcePhysicalImage.Parameters
    ) throws -> Bool {
        var selected=opticalSettings
        selected.cameraInputColorSpace = .acesLinear
        try selected.validate()
        let camera=selected.cameraOptics.diffusion
        let paper=selected.printDiffusion
        let cameraActive=(selected.cameraOptics.active || selected.filmHalation.active) &&
            camera.active && camera.strength>0 && camera.spatialScale>0
        let paperActive=paper.active && paper.strength>0 && paper.spatialScale>0
        guard paperActive else {
            throw Failure.invalid("原尺寸 FFT / 扫描并行对照请开启印相柔化")
        }
        guard !selected.sourceGrain.active ||
              (!selected.sourceGrain.useUnseededParallel &&
               selected.sourceGrain.numbaSeed != nil &&
               (!selected.sourceGrain.useFastStats || selected.sourceGrain.fastStatsSeed==selected.sourceGrain.numbaSeed)) else {
            throw Failure.invalid("原尺寸 FFT 对照需要受控种子颗粒")
        }
        guard let identity=try fullSourceKey(rawURL) else {
            throw Failure.invalid("原尺寸导出 FFT 无法确认 RAW 文件身份")
        }
        clearAllInputCaches(reason:"full_export_fft_diagnostic")
        defer {clearAllInputCaches(reason:"full_export_fft_diagnostic_finished")}
        func exportTrial(_ name:String,workers:Int,reuseRows:Bool,scanWorkers:Int,pixelWorkers:Int) throws -> [UInt8] {
            try Task.checkCancellation()
            let sampler=Build133RAWMemoryLadder.RSSSampler()
            let start=ProcessInfo.processInfo.systemUptime
            let thermalBefore=ProcessInfo.processInfo.thermalState.rawValue
            OPTDeviceFeedback.mark("full_export_fft_trial_begin",["case":name,
                "workers":String(workers),"reuseIdenticalRows":String(reuseRows),
                "postDiffusionScanWorkers":String(scanWorkers),"compactPixelWorkers":String(pixelWorkers)])
            sampler.start()
            let digest:[UInt8]
            var hashSeconds=0.0
            do {
                digest=try autoreleasepool { () throws -> [UInt8] in
                    var stages=[String:Double]()
                    // Packed sensor input is scoped to development; not kept
                    // across JPEG packaging or the next independent trial.
                    func develop() throws -> OriginalSourcePixelIO.Frame {
                        guard try fullSourceKey(rawURL)==identity else {
                            throw Failure.invalid("原尺寸 FFT 对照 RAW 身份已变化")
                        }
                        let source=try open(rawURL,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels)
                        guard try fullSourceKey(rawURL)==identity else {
                            throw Failure.invalid("原尺寸 FFT 对照 RAW 解码期间身份改变")
                        }
                        let envelope=OriginalSourcePhysicalImage.memoryEnvelope(
                            width:source.width,height:source.height,parameters:selected)
                        guard envelope.compactSequentialFFT else {
                            throw Failure.invalid("原尺寸 FFT 对照需要紧凑 Float64 光学设置")
                        }
                        try OriginalSourcePhysicalImage.validateMemoryBudget(
                            width:source.width,height:source.height,parameters:selected)
                        var frame=try makeSourceFrame(source,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels)
                        let begin=ProcessInfo.processInfo.systemUptime
                        try OriginalSourcePhysicalImage.developInPlace(&frame,parameters:selected,
                            phaseMemoryObserver:{phase in
                                stages[phase]=ProcessInfo.processInfo.systemUptime-begin
                                OPTDeviceFeedback.mark("full_export_fft_phase",["case":name,"phase":phase])
                            },diffusionFFTWorkers:workers,reuseIdenticalDiffusionKernelRows:reuseRows,
                            postDiffusionScanWorkers:scanWorkers,compactPixelWorkers:pixelWorkers)
                        return frame
                    }
                    var frame=try develop()
                    if selected.sourceGrain.active && selected.sourceGrain.sublayersActive &&
                       stages["three_sublayer_grain_ready"]==nil {
                        throw Failure.invalid("原尺寸导出 FFT 对照未执行三亚层颗粒")
                    }
                    if cameraActive && stages["camera_diffusion_ready"]==nil {
                        throw Failure.invalid("原尺寸导出 FFT 对照未执行摄影柔化")
                    }
                    if paperActive && stages["paper_diffusion_ready"]==nil {
                        throw Failure.invalid("原尺寸导出 FFT 对照未执行印相柔化")
                    }
                    if scanWorkers>1 && stages["parallel_post_diffusion_scan_begin"]==nil {
                        throw Failure.invalid("原尺寸对照未执行双核印相后扫描")
                    }
                    if pixelWorkers>1 && (stages["parallel_camera_begin"]==nil || stages["parallel_develop_begin"]==nil) {
                        throw Failure.invalid("原尺寸对照未执行双核初始及校正显影")
                    }
                    let hashStart=ProcessInfo.processInfo.systemUptime
                    var hash=SHA256()
                    frame.rgb.withUnsafeBytes {hash.update(bufferPointer:$0)}
                    let words=Array(hash.finalize())
                    hashSeconds=ProcessInfo.processInfo.systemUptime-hashStart
                    try Task.checkCancellation()
                    let jpegStart=ProcessInfo.processInfo.systemUptime
                    let url=try Build90NativeOutputWriter.write(
                        width:frame.width,height:frame.height,rgb:frame.rgb,
                        options:.init(format:.jpeg,bitDepth:8,outputSpace:"sRGB",
                                      cctfEncoded:selected.sourceOutputCCTFEncoding))
                    defer {try? FileManager.default.removeItem(at:url)}
                    let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
                    let size=(attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    guard size>0 else {throw Failure.invalid("原尺寸 FFT JPEG 写出空文件")}
                    OPTDeviceFeedback.mark("full_export_fft_jpeg_ready",["case":name,
                        "width":String(frame.width),"height":String(frame.height),
                        "outputBytes":String(size),"float64Bytes":String(frame.rgb.count*8),
                        "jpegSeconds":String(ProcessInfo.processInfo.systemUptime-jpegStart),
                        "cameraFFTSeconds":String((stages["camera_diffusion_ready"] ?? 0)-(stages["camera_diffusion_begin"] ?? 0)),
                        "paperFFTSeconds":String((stages["paper_diffusion_ready"] ?? 0)-(stages["paper_diffusion_begin"] ?? 0)),
                        "postDiffusionScanSeconds":String((stages["paper_scan_pixels_ready"] ?? 0)-(stages["paper_diffusion_ready"] ?? 0)),
                        "initialHDSeconds":String((stages["camera_photons_ready"] ?? 0)-(stages["phase_admitted_DIR"] ?? 0)),
                        "correctedHDSeconds":String((stages["film_density_ready_DIR_released"] ?? 0)-(stages["spatial_DIR_ready"] ?? 0))])
                    frame.rgb.removeAll(keepingCapacity:false)
                    return words
                }
            } catch {
                _=sampler.finish()
                throw error
            }
            let samples=sampler.finish()
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            OPTDeviceFeedback.mark("full_export_fft_trial_result",[
                "case":name,"seconds":String(elapsed),"shaSeconds":String(hashSeconds),
                "secondsExcludingSHA":String(elapsed-hashSeconds),
                "thermalBefore":String(thermalBefore),"thermalAfter":String(ProcessInfo.processInfo.thermalState.rawValue),
                "workers":String(workers),"rowReuse":String(reuseRows),
                "postDiffusionScanWorkers":String(scanWorkers),"compactPixelWorkers":String(pixelWorkers),
                "sampledPeakPhysicalFootprintBytes":samples.footprint.map{String($0)} ?? "not_measured",
                "sampledPeakRSSBytes":samples.peak.map{String($0)} ?? "not_measured",
                "sampledLowestHeadroomBytes":samples.lowest.map{String($0)} ?? "not_measured",
                "sampleCount":String(samples.count)])
            return digest
        }
        let reference=try exportTrial("verified_fft_scan_reference",workers:2,reuseRows:true,scanWorkers:2,pixelWorkers:1)
        let candidate=try exportTrial("two_worker_hd_candidate",workers:2,reuseRows:true,scanWorkers:2,pixelWorkers:2)
        let equal=reference==candidate
        OPTDeviceFeedback.mark("full_export_fft_compare_result",["passed":String(equal),
            "allFloat64BytesSHA256Equal":String(equal),"productionEnabled":"false",
            "candidate":"two_worker_initial_and_corrected_hd",
            "scope":"actual_uncropped_RAW_full_resolution_two_independent_JPEG_exports"])
        return equal
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
        // Full preview/export never use either reduced-grid cache.
        // Drop the other grid's density before any preview allocation.
        fullDensityCache.clear()
        // Capture before decode so a pressure/source notification during
        // decoding cannot be undone by a late optical cache transaction.
        var densityLease=previewDensityCache.lease()
        var paperLease=previewPaperDensityCache.lease()
        var completedPreview=false
        defer {
            if !completedPreview {
                previewDensityCache.clear()
                previewPaperDensityCache.clear()
            }
        }
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
            densityLease=previewDensityCache.clear(expectedGeneration:densityLease)
            paperLease=previewPaperDensityCache.clear(expectedGeneration:paperLease)
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
        // A cache is optional memory, never an optical mode change.
        // Charge its full 24 B/px on top of the existing production plan.
        // The preview input is still retained, so no COW credit here.
        let densityBytes=UInt64(reduced.rgb.count)*UInt64(MemoryLayout<Double>.stride)
        let validIdentity=key != nil && key==Build139RAWPreviewDownsample.CacheKey.make(
            url:rawURL,crop:cropKey,maxLongEdge:maxLongEdge
        )
        var reuseAllowed=false
        var reuseReason="unsupported_parameters"
        // Build147 device matrix: explicitly controlled serial grain
        // re-runs after the deterministic boundary. Never admit unseeded RNG.
        let allowSeededPreview=true
        if OriginalSourcePhysicalImage.canReuseFilmDensity(selected,allowSeededGrain:allowSeededPreview) {
            if !validIdentity {
                reuseReason="identity_unavailable"
            } else if previewDensityCache.lease() != densityLease {
                reuseReason="lease_invalidated"
            } else if !canRetainPreviewDensity(bytes:densityBytes) {
                reuseReason="retention_headroom"
            } else {
                let envelope=OriginalSourcePhysicalImage.memoryEnvelope(
                    width:reduced.width,height:reduced.height,parameters:selected)
                do {
                    try OriginalSourcePhysicalImage.validateMemoryBudget(
                        width:reduced.width,height:reduced.height,
                        additionalBytesPerPixel:envelope.additionalBytesPerPixel+24,
                        cameraDiffusion:envelope.cameraDiffusion,paperDiffusion:envelope.paperDiffusion)
                    reuseAllowed=true
                    reuseReason="admitted"
                } catch {
                    // Only optional caching is declined; the original
                    // renderer must still pass its independent full gate.
                    reuseReason="cache_memory_admission"
                }
            }
        }
        if !reuseAllowed {previewDensityCache.clear(expectedGeneration:densityLease)}
        // Build149 5/5 exact paper cases on A15. Admit reduced-grid
        // no-grain/no-print-diffusion only, charge a SECOND 24 B/px.
        // Full resolution and stochastic paper caching stay disabled.
        var paperAllowed=false
        var paperReason="unsupported_parameters"
        if reuseAllowed && !selected.sourceGrain.active && !selected.printDiffusion.active {
            if previewPaperDensityCache.lease() != paperLease {
                paperReason="lease_invalidated"
            } else if !canRetainPreviewDensity(bytes:densityBytes*2) {
                paperReason="combined_retention_headroom"
            } else {
                let envelope=OriginalSourcePhysicalImage.memoryEnvelope(
                    width:reduced.width,height:reduced.height,parameters:selected)
                do {
                    try OriginalSourcePhysicalImage.validateMemoryBudget(
                        width:reduced.width,height:reduced.height,
                        additionalBytesPerPixel:envelope.additionalBytesPerPixel+48,
                        cameraDiffusion:envelope.cameraDiffusion,paperDiffusion:envelope.paperDiffusion)
                    paperAllowed=true
                    paperReason="admitted"
                } catch {paperReason="combined_cache_memory_admission"}
            }
        }
        if !paperAllowed {previewPaperDensityCache.clear(expectedGeneration:paperLease)}
        OPTDeviceFeedback.mark("preview_paper_density_cache_policy",[
            "eligible":String(paperAllowed),"reason":paperReason,
            "densityBytes":String(densityBytes),"combinedBytes":String(densityBytes*2)])
        OPTDeviceFeedback.mark("preview_density_cache_policy",[
            "eligible":String(reuseAllowed),"reason":reuseReason,
            "densityBytes":String(densityBytes)])
        recordSerialGrainLifetime(selected,width:reduced.width,height:reduced.height,
                                  cacheAdmitted:reuseAllowed)
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:reduced.width,height:reduced.height,parameters:selected
        )
        var frame=OriginalSourcePixelIO.Frame(
            width:reduced.width,height:reduced.height,rgb:reduced.rgb
        )
        try OriginalSourcePhysicalImage.developInPlace(
            &frame,parameters:selected,phaseMemoryObserver:{OPTDeviceFeedback.mark($0)},
            filmDensityReuse:reuseAllowed ? previewDensityCache : nil,
            filmDensityReuseLease:reuseAllowed ? densityLease : nil,
            allowSeededGrainDensityReuse:allowSeededPreview,
            paperDensityReuse:paperAllowed ? previewPaperDensityCache : nil,
            paperDensityReuseLease:paperAllowed ? paperLease : nil
        )
        if paperAllowed && !canRetainPreviewDensity(bytes:densityBytes*2) {
            previewPaperDensityCache.clear()
            OPTDeviceFeedback.mark("preview_paper_density_cache_evicted",["reason":"combined_post_render_headroom"])
        }
        if reuseAllowed && !canRetainPreviewDensity(bytes:densityBytes) {
            previewDensityCache.clear()
            OPTDeviceFeedback.mark("preview_density_cache_evicted",["reason":"post_render_headroom"])
        }
        try Task.checkCancellation()
        completedPreview=true
        OPTDeviceFeedback.mark("optics_done")
        return PreviewWithGeometry(
            frame:frame,sourceWidth:sourceWidth,sourceHeight:sourceHeight
        )
    }

    private static func canRetainPreviewDensity(bytes:UInt64)->Bool {
        #if os(iOS)
        let headroom=UInt64(os_proc_available_memory())
        #else
        let headroom=ProcessInfo.processInfo.physicalMemory/3
        #endif
        // Retention heuristic only, never a render limit. No fixed
        // memory ceiling and no precision/geometry substitution.
        return headroom>0 && bytes<=headroom/5
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
