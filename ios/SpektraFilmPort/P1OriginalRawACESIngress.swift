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
    }

    static func clearAllInputCaches(reason:String="source_invalidation") {
        clearPreviewInputCache()
        fullInputCache.clear(reason:reason)
        fullDensityCache.clear()
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
            "admissionChanged":"false"])
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
        let densityLease=fullDensityCache.lease()
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
        // Build148-A: only the real-device verified no-grain, uncropped
        // full-grid scope. The optional cache never changes optical settings.
        let densityBytes=UInt64(working.width)*UInt64(working.height)*24
        let retainedBytes=densityBytes+UInt64(decoded.packedRGB16.count)
        var reuseAllowed=false
        var reuseReason="unsupported_parameters"
        if crop==nil && !selected.sourceGrain.active &&
            OriginalSourcePhysicalImage.canReuseFilmDensity(selected) {
            if acquisition.key==nil {
                reuseReason="identity_unavailable"
            } else if fullDensityCache.lease() != densityLease {
                reuseReason="lease_invalidated"
            } else if !retainDecodedSource &&
                !fullDensityCache.hasEntry(expectedGeneration:densityLease) {
                reuseReason="export_without_preview_entry"
            } else if !canRetainPreviewDensity(bytes:retainedBytes) {
                reuseReason="retention_headroom"
            } else {
                let envelope=OriginalSourcePhysicalImage.memoryEnvelope(
                    width:working.width,height:working.height,parameters:selected)
                do {
                    try OriginalSourcePhysicalImage.validateMemoryBudget(
                        width:working.width,height:working.height,
                        additionalBytesPerPixel:envelope.additionalBytesPerPixel+24,
                        cameraDiffusion:envelope.cameraDiffusion,paperDiffusion:envelope.paperDiffusion)
                    reuseAllowed=true
                    reuseReason="admitted"
                } catch {
                    reuseReason="cache_memory_admission"
                }
            }
        }
        if !reuseAllowed {fullDensityCache.clear(expectedGeneration:densityLease)}
        OPTDeviceFeedback.mark("full_density_cache_policy",[
            "eligible":String(reuseAllowed),"reason":reuseReason,
            "densityBytes":String(densityBytes),"retainPreview":String(retainDecodedSource)])
        recordSerialGrainLifetime(selected,width:working.width,height:working.height,
                                  cacheAdmitted:reuseAllowed)
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:working.width,height:working.height,parameters:selected
        )
        var frame = try makeSourceFrame(
            working, maximumAllowedPixels: OriginalSourcePhysicalImage.maximumPixels
        )
        OPTDeviceFeedback.mark("float64_input_ready")
        try OriginalSourcePhysicalImage.developInPlace(
            &frame, parameters: selected,
            phaseMemoryObserver:{OPTDeviceFeedback.mark($0)},
            filmDensityReuse:reuseAllowed ? fullDensityCache : nil,
            filmDensityReuseLease:reuseAllowed ? densityLease : nil
        )
        try Task.checkCancellation()
        OPTDeviceFeedback.mark("optics_done")
        // Retain only a successful preview, subject to combined live margin.
        // Export, errors and cancelled operations release the density.
        keepDensity=retainDecodedSource && reuseAllowed &&
            fullDensityCache.hasEntry(expectedGeneration:fullDensityCache.lease()) &&
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
            "scope":allowSeededDiagnostic
                ? "actual_uncropped_RAW_seeded_grain_SHA256_all_Float64_bytes"
                : "actual_uncropped_RAW_no_grain_SHA256_all_Float64_bytes"])
        var changed=selected
        // Downstream only, and explicitly reported. No saved user setting
        // is changed. This compares linear versus encoded scan output.
        changed.sourceOutputCCTFEncoding.toggle()

        func admit(_ params:OriginalSourcePhysicalImage.Parameters,cache:Bool) throws {
            if cache {
                let envelope=OriginalSourcePhysicalImage.memoryEnvelope(width:w,height:h,parameters:params)
                try OriginalSourcePhysicalImage.validateMemoryBudget(
                    width:w,height:h,additionalBytesPerPixel:envelope.additionalBytesPerPixel+24,
                    cameraDiffusion:envelope.cameraDiffusion,paperDiffusion:envelope.paperDiffusion)
            } else {
                try OriginalSourcePhysicalImage.validateMemoryBudget(width:w,height:h,parameters:params)
            }
        }
        func trial(_ name:String,_ params:OriginalSourcePhysicalImage.Parameters,
                   cache:Bool,expectedLease:UInt64?=nil) throws -> (digest:[UInt8],hit:Bool,stored:Bool,invalidated:Bool) {
            try Task.checkCancellation()
            OPTDeviceFeedback.mark("full_density_trial_begin",[
                "case":name,"cache":String(cache),"outputCCTF":String(params.sourceOutputCCTFEncoding)])
            do {try admit(params,cache:cache)}
            catch {
                OPTDeviceFeedback.mark("full_density_admission_refused",["case":name,"error":error.localizedDescription])
                throw error
            }
            if let expectedLease,session.lease() != expectedLease {
                throw Failure.invalid("原尺寸缓存对照内存告警/代际失效")
            }
            var frame=try makeSourceFrame(source,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels)
            var phases=[String]()
            let sampler=Build133RAWMemoryLadder.RSSSampler()
            let start=ProcessInfo.processInfo.systemUptime
            sampler.start()
            do {
                try OriginalSourcePhysicalImage.developInPlace(
                    &frame,parameters:params,phaseMemoryObserver:{stage in
                        phases.append(stage)
                        OPTDeviceFeedback.mark("full_density_legacy_phase",["case":name,"phase":stage])
                    },filmDensityReuse:cache ? session : nil,
                    filmDensityReuseLease:expectedLease,
                    allowSeededGrainDensityReuse:allowSeededDiagnostic)
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
                (cache && !session.hasEntry(expectedGeneration:session.lease()))
            if allowSeededDiagnostic && !phases.contains("three_sublayer_grain_ready") {
                throw Failure.invalid("原尺寸颗粒缓存对照未执行实际颗粒")
            }
            OPTDeviceFeedback.mark("full_density_trial_result",[
                "case":name,"seconds":String(elapsed),"hit":String(hit),
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
        // Admission is conservative: no credit for already-resident
        // cached CMY, or assumed future release. A refused hot trial is
        // NOT a numerical PASS and never triggers a reduced image.
        let hotLease=session.lease()
        let hot=try trial("cache_hot_changed_CCTF",changed,cache:true,expectedLease:hotLease)
        let coldEqual=cold.digest==baseline.digest
        let hotEqual=hot.digest==baselineChanged.digest
        let passed=coldEqual && hotEqual && hot.hit && !hot.invalidated
        session.clear()
        OPTDeviceFeedback.mark("full_density_compare_result",[
            "passed":String(passed),"coldAllBytesSHA256Equal":String(coldEqual),
            "hotAllBytesSHA256Equal":String(hotEqual),"hotHit":String(hot.hit),
            "productionEnabled":"false","cacheCleared":"true",
            "seededGrain":String(allowSeededDiagnostic)])
        return passed
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
            allowSeededGrainDensityReuse:allowSeededPreview
        )
        if reuseAllowed && !canRetainPreviewDensity(bytes:densityBytes) {
            previewDensityCache.clear()
            OPTDeviceFeedback.mark("preview_density_cache_evicted",["reason":"post_render_headroom"])
        }
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
