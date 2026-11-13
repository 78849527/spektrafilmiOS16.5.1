import Foundation
import CoreGraphics
import ImageIO
#if os(iOS)
import os
#endif

/// v1.8.22: opt-in full-source *nonlinear* optical spatial image pipeline.
/// It calls the ACTUAL Swift production Hanatos, H-D, optical enlarger,
/// s023 paper development and measured-spectrum scanner for EACH pixel.
/// Unlike the older exact-DIR path, it never creates or interpolates a
/// colour 3D LUT. Only original 2D FIR/YVV is used for spatial DIR.
/// Unsupported stochastic grain, RAW, halation and post-scanner effects
/// remain deliberately unavailable, without a silent approximate fallback.
///
/// Remaining limits: some original measured data are Float32-packed; this
/// is not all-modules Float64 parity or source Numba stochastic emulation.
enum OriginalSourcePhysicalImage {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    /// 12 MP is a provisional experimental entry cap, NOT a device promise.
    /// Unlike v1.8.23, actual process and physical memory budgets are checked
    /// before any full-size ImageIO decode. This includes the user's
    /// 3888x2592 (10.08MP) only when measured available memory permits.
    static let maximumPixels = 12_000_000
    static let estimatedPeakBytesPerPixel: UInt64 = 120
    static let maximumSourceMemoryBudget: UInt64 = 1_500_000_000

    static func validateMemoryBudget(
        width:Int,height:Int,
        physicalMemory:UInt64?=nil,
        processAvailableMemory:UInt64?=nil
    ) throws {
        guard width>0,height>0,width<=8192,height<=8192,
              width<=maximumPixels/height else {
            throw Failure.invalid(
                "逐像素全光学（实验）：当前最大 1200 万像素，单边不超过 8192。" +
                "禁止自动缩图或切换快速算法。"
            )
        }
        let peak = UInt64(width) * UInt64(height) * estimatedPeakBytesPerPixel
        let physical = physicalMemory ?? ProcessInfo.processInfo.physicalMemory
        let allowed = min(maximumSourceMemoryBudget,physical/3)
        let headroom:UInt64?
        if let explicit=processAvailableMemory {
            headroom=explicit
        } else {
            #if os(iOS)
            headroom=UInt64(os_proc_available_memory())
            #else
            headroom=nil
            #endif
        }
        let sourceOK = peak <= allowed
        // Advisory headroom can fluctuate, so require 20% margin.
        let processOK = headroom.map {
            $0 > 0 && peak <= ($0 / 10) * 8
        } ?? true
        guard sourceOK,processOK else {
            let required = peak/1_000_000
            let budget = allowed/1_000_000
            let free = headroom.map {
                String($0/1_000_000)
            } ?? "未获取"
            throw Failure.invalid(
                "逐像素全光学（实验）原尺寸内存预算不足：" +
                "\(width)×\(height)，预估峰值约 \(required) MB，" +
                "安全预算 \(budget) MB，当前可分配约 \(free) MB。" +
                "请减少后台内存占用后重新确认，或显式选用" +
                "已验证的 8-bit 原版像素直连模式；" +
                "不会擅自缩图、跳过物理显影或切换 Float32 LUT。"
            )
        }
    }

    struct Parameters {
        let filmID: String
        let paperID: String
        let cameraEV: Double
        let paperEV: Double
        let dir: SpatialDIRSettings
        let print: OriginalPrintOptics.Settings
        let morph: OriginalPrintMorph.Settings

        func validate() throws {
            guard SpectralPhysics.supportedFilmIDs.contains(filmID),
                  SpectralPhysics.supportedPaperIDs.contains(paperID),
                  cameraEV.isFinite && abs(cameraEV) <= 4,
                  paperEV.isFinite && abs(paperEV) <= 4,
                  dir.enabled && dir.valid && dir.sourceConvolutionEnabled,
                  print.isValid else {
                throw Failure.invalid(
                    "原版逐像素物理模式需要有效胶片/相纸、源 DIR 和原版光学参数"
                )
            }
            if !SpectralPhysics.isPositiveFilm(filmID) && !print.enabled {
                throw Failure.invalid(
                    "负片逐像素物理模式需要启用原版放大机光学印相和相纸 H-D"
                )
            }
        }

        func createEngine() throws -> SpectralPhysics {
            try validate()
            return try SpectralPhysics(
                filmID: filmID, paperID: paperID,
                sourceScanner: true,
                scannerBlackWhite: false,
                cam16Gamut: false,
                printReferenceCorrection: false,
                printMorph: morph,
                printOptics: print,
                cameraExposureEV: cameraEV,
                hanatosPrecision: .originalFloat64
            )
        }
    }

    /// Compatibility API for existing Python image diagnostic fixtures.
    /// Large-image production calls developInPlace, which takes unique
    /// ownership of an existing ImageIO Double buffer instead of retaining
    /// the source and also allocating separate logRaw + printed frames.
    static func develop(
        _ input: OriginalSourcePixelIO.Frame,
        parameters: Parameters,
        stageDoubleObserver: ((String, [Double]) -> Void)? = nil
    ) throws -> OriginalSourcePixelIO.Frame {
        var frame=input
        try developInPlace(
            &frame,parameters:parameters,
            stageDoubleObserver:stageDoubleObserver
        )
        return frame
    }

    /// Full-resolution source photon / H-D / DIR / print / scan, reusing
    /// one mutable full-size Double RGB array for input, camera log exposure
    /// AND final encoded RGB. Full-dimension FIR and YVV remain exact:
    /// NO independent tiles, cropped Gaussian support or altered seed.
    static func developInPlace(
        _ frame: inout OriginalSourcePixelIO.Frame,
        parameters: Parameters,
        stageDoubleObserver: ((String, [Double]) -> Void)? = nil
    ) throws {
        try parameters.validate()
        let w=frame.width,h=frame.height
        try validateMemoryBudget(width:w,height:h)
        guard frame.rgb.count==w*h*3,
              frame.rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else {
            throw Failure.invalid(
                "逐像素原版显影输入 RGB 尺寸／颜色范围错误，" +
                "不能静默截断或改用移动模式"
            )
        }

        let engine=try parameters.createEngine()
        let source=try engine.sourceSpatialFilmParameters()
        let size=w*h*3
        var inhibitors=[Double](repeating:0,count:size)
        var initialObserved:[Double]?=stageDoubleObserver == nil
            ? nil : [Double](repeating:0,count:size)

        // Compute initial photon response, H-D and donor/receiver inhibitor
        // from the original sample BEFORE overwriting that sample with
        // its raw log exposure. This is safe for opaque source RGB pixels:
        // no neighboring pixel is used by the source camera/H-D stages.
        for p in 0..<(w*h) {
            let k=p*3
            let sample=[frame.rgb[k],frame.rgb[k+1],frame.rgb[k+2]]
            let initial=try engine.sourceSpatialInput(
                encodedRGB:sample,cameraEV:parameters.cameraEV
            )
            for receiver in 0..<3 {
                var total=0.0
                for donor in 0..<3 {
                    let d=initial.initialDensity[donor]
                    let silver=source.positive
                        ? source.densityMaximum[donor]-d : d
                    total+=silver*source.matrix[donor*3+receiver]
                }
                inhibitors[k+receiver]=total
            }
            for c in 0..<3 {
                frame.rgb[k+c]=initial.rawLog[c]
                initialObserved?[k+c]=initial.initialDensity[c]
            }
        }
        stageDoubleObserver?("logRaw",frame.rgb)
        if let initialObserved {
            stageDoubleObserver?("initial",initialObserved)
        }
        stageDoubleObserver?("inhibitors",inhibitors)

        // All four exact source Gaussian passes operate on the entire
        // original image with TWO reusable 1-channel work arrays.
        // Only one additional 3-channel result buffer is ever retained.
        let pixelUM=parameters.dir.referencePixelSizeUM ??
            (36_000.0/Double(max(w,h)))
        let radius=parameters.dir.diffusionRadiusScale
        let diffused=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
            inhibitors,width:w,height:h,
            coreSigma:20.0*radius/pixelUM,
            tailSigma:200.0*radius/pixelUM,
            tailWeight:parameters.dir.tailWeight
        )
        // Do not keep another full-frame 3-channel inhibitor buffer alive
        // while computing the real spectral paper/scan output.
        inhibitors.removeAll(keepingCapacity:false)
        stageDoubleObserver?("diffused",diffused)

        var correctedObserved:[Double]?=stageDoubleObserver == nil
            ? nil : [Double](repeating:0,count:size)
        var densityObserved:[Double]?=stageDoubleObserver == nil
            ? nil : [Double](repeating:0,count:size)
        // Each corrected pixel is completely consumed before its
        // historical camera log buffer is overwritten by final scan RGB.
        for p in 0..<(w*h) {
            let k=p*3
            let corrected=(0..<3).map { c in
                frame.rgb[k+c]-diffused[k+c]
            }
            let density=try engine.sourceSpatialDevelopCorrectedLog(
                corrected
            )
            let rgb=try engine.sourceSpatialScan(
                filmDensity:density,paperEV:parameters.paperEV
            )
            for c in 0..<3 {
                correctedObserved?[k+c]=corrected[c]
                densityObserved?[k+c]=density[c]
                frame.rgb[k+c]=rgb[c]
            }
        }
        if let correctedObserved {
            stageDoubleObserver?("correctedLog",correctedObserved)
        }
        if let densityObserved {
            stageDoubleObserver?("density",densityObserved)
        }
        stageDoubleObserver?("printed",frame.rgb)
        guard frame.rgb.allSatisfy({ $0.isFinite }) else {
            throw Failure.invalid("逐像素源光学计算产生非有限扫描 RGB")
        }
    }

}

#if canImport(UIKit)
import UIKit
#endif

extension OriginalSourcePixelIO {
    // Keep source-physical utilities separate so existing original DIR-only
    // ImageIO and source kernel tests compile without SpectralPhysics.
    #if canImport(UIKit)
    static func previewPhysical(
        _ data:Data,parameters:OriginalSourcePhysicalImage.Parameters
    ) throws -> UIImage {
        var frame=try decode(
            data,previewMaxSide:640,
            maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
        )
        try OriginalSourcePhysicalImage.developInPlace(
            &frame,parameters:parameters
        )
        return UIImage(cgImage:try displayImage(frame))
    }
    #endif

    static func exportPhysicalJPEG(
        _ data:Data,parameters:OriginalSourcePhysicalImage.Parameters
    ) throws -> URL {
        // The exact same original-file full-size limit and device memory
        // guard run BEFORE allocating the CGImage/Double RGBA transport.
        try preflightExport(
            data,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
        )
        guard let imageSource=CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache:false] as CFDictionary
        ), let metadata=CGImageSourceCopyPropertiesAtIndex(
            imageSource,0,nil
        ) as NSDictionary?,
        let w=metadata[kCGImagePropertyPixelWidth] as? NSNumber,
        let h=metadata[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw Failure.invalid("原版全光学导出前无法确认原图尺寸")
        }
        try OriginalSourcePhysicalImage.validateMemoryBudget(
            width:w.intValue,height:h.intValue
        )
        var frame=try decode(
            data,maximumAllowedPixels:OriginalSourcePhysicalImage.maximumPixels
        )
        try OriginalSourcePhysicalImage.developInPlace(
            &frame,parameters:parameters
        )
        return try createJPEG(frame)
    }
}
