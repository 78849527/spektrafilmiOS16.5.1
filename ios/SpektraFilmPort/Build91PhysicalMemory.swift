import Foundation

/// Build91 (#44) original array/FFT geometry dry-run planner. It never
/// allocates a 1–13 MP image merely to decide whether the image can fit.
/// All values use UInt64 and are checked BEFORE ImageIO/photon buffers.
/// Estimated peak is NOT a measured iPhone resident memory sample.
enum Build91PhysicalMemory {
    enum Failure:LocalizedError {
        case invalid(String)
        var errorDescription:String? {
            if case let .invalid(m)=self{return m}
            return nil
        }
    }
    struct FFT {
        let radius:Int
        let paddedWidth:Int
        let paddedHeight:Int
        let fftWidth:Int
        let fftHeight:Int
        let gridElements:UInt64
        let sourceFFTGuardBytes:UInt64
        let actualScratchBytes:UInt64
        let psfBytes:UInt64
        /// Historical conservative FFT workspace estimate for telemetry.
        /// No static-MB rejection: the full plan uses live OS headroom.
    }
    struct Plan {
        let width:Int
        let height:Int
        let pixels:UInt64
        let basePeakBytes:UInt64
        let additionalFFTBytes:UInt64
        let estimatedPeakBytes:UInt64
        let allowedBytes:UInt64
        let processAvailableBytes:UInt64?
        let cameraFFT:FFT?
        let paperFFT:FFT?
        var megapixels:Double {Double(pixels)/1_000_000}
        var peakMB:Double {Double(estimatedPeakBytes)/1_000_000}
    }
    private static func pow2(_ value:Int) throws->Int {
        guard value>0,value<=32768 else {
            throw Failure.invalid(
                "Build91 原版 Double FFT 大于 32768 网格；" +
                "禁止减少源扩散 PSF 或换 GPU 近似滤波"
            )
        }
        var n=1
        while n<value {n*=2}
        return n
    }
    /// OriginalSourceDiffusion.apply uses this exact reflect geometry.
    static func fft(
        width:Int,height:Int,pixelUM:Double,
        settings:OriginalSourceDiffusion.Settings
    ) throws->FFT? {
        if !settings.active || settings.strength<=0 ||
           settings.spatialScale<=0 {return nil}
        let radius=try OriginalSourceDiffusion.radius(
            width:width,height:height,pixelUM:pixelUM,
            settings:settings
        )
        guard width>0,height>0,radius>=0,
              radius<=4096,width<=Int.max-4*radius,
              height<=Int.max-4*radius else {
            throw Failure.invalid("源 FFT padded radius 整数溢出")
        }
        let kernel=2*radius+1
        let w=try pow2(width+4*radius)
        let h=try pow2(height+4*radius)
        let elements=UInt64(w)*UInt64(h)
        let pixels=UInt64(width)*UInt64(height)
        let guardBytes=elements*40+pixels*48
        let scratchBytes=elements*32+UInt64(2*(w+h))*8
        let psf=UInt64(kernel)*UInt64(kernel)*3*8
        return FFT(
            radius:radius,paddedWidth:width+2*radius,
            paddedHeight:height+2*radius,
            fftWidth:w,fftHeight:h,
            gridElements:elements,
            sourceFFTGuardBytes:guardBytes,
            actualScratchBytes:scratchBytes,
            psfBytes:psf
        )
    }
    /// Camera and paper FFT execute SEQUENTIALLY, so account for their
    /// maximum extra scratch, not the sum of both stages.
    static func plan(
        width:Int,height:Int,
        baseBytesPerPixel:UInt64=120,
        additionalBytesPerPixel:UInt64=0,
        physicalMemory:UInt64,
        processAvailable:UInt64?=nil,
        camera:(settings:OriginalSourceDiffusion.Settings,pixelUM:Double)?=nil,
        paper:(settings:OriginalSourceDiffusion.Settings,pixelUM:Double)?=nil,
        diagnosticExtendedGeometry:Bool=false
    ) throws->Plan {
        // Extended dry-run only: use the actual existing FIR/YVV backend
        // geometry envelope. All production callers retain the 13MP gate
        // until all downstream stages and output contracts are aligned.
        let pixelLimit=diagnosticExtendedGeometry ? 32_000_000 : 13_000_000
        guard width>0,height>0,width<=8192,height<=8192,
              width<=pixelLimit/height else {
            throw Failure.invalid(
                "全光学源工作尺寸不合法或超过 \(pixelLimit/10_000) 万像素；" +
                "任何输出分辨率必须用户明确选择"
            )
        }
        guard baseBytesPerPixel>0,
              baseBytesPerPixel<=4096,
              additionalBytesPerPixel<=4096,
              physicalMemory>0 else {
            throw Failure.invalid("原版物理内存预算参数不合法")
        }
        let pixels=UInt64(width)*UInt64(height)
        let bytesPerPixel=baseBytesPerPixel+additionalBytesPerPixel
        let basePeak=pixels*bytesPerPixel
        let cameraFFT=try camera.flatMap{
            try fft(width:width,height:height,
                    pixelUM:$0.pixelUM,settings:$0.settings)
        }
        let paperFFT=try paper.flatMap{
            try fft(width:width,height:height,
                    pixelUM:$0.pixelUM,settings:$0.settings)
        }
        // Fixed 512MB FFT gate removed. The original geometry,
        // pooled Double FFT arrays and PSF remain unchanged. Total
        // source+FFT memory is admitted by the live 80% headroom
        // check in validate(), never by an arbitrary scratch ceiling.
        let additionalFFT=max(
            cameraFFT.map{$0.actualScratchBytes+$0.psfBytes} ?? 0,
            paperFFT.map{$0.actualScratchBytes+$0.psfBytes} ?? 0
        )
        let estimated=basePeak+additionalFFT
        // Build117: the device-reported process headroom is authoritative.
        // No invented 1500 MB ceiling. If unavailable, retain the safer
        // physical-memory-third fallback rather than permit unbounded use.
        let allowed=processAvailable.map{($0/10)*8} ?? physicalMemory/3
        return Plan(
            width:width,height:height,pixels:pixels,
            basePeakBytes:basePeak,additionalFFTBytes:additionalFFT,
            estimatedPeakBytes:estimated,
            allowedBytes:allowed,processAvailableBytes:processAvailable,
            cameraFFT:cameraFFT,paperFFT:paperFFT
        )
    }
    /// Real process headroom governs admission; physicalMemory/3 is only
    /// the fallback when the OS cannot report current process headroom.
    /// pre-decode: committed=0, full estimated peak against OS headroom.
    /// developInPlace: the caller's already allocated RGB Double buffer is
    /// included in the full estimate but no longer in OS process headroom.
    /// Subtract exactly those committed input bytes, NEVER estimates of
    /// future scratch or stage releases. Keep the 80% live OS gate.
    static func validate(
        _ plan:Plan,alreadyCommittedInputBytes:UInt64=0
    ) throws {
        guard alreadyCommittedInputBytes<=plan.basePeakBytes else {
            throw Failure.invalid("Build119 已分配输入帧扣除量超过完整峰值预算")
        }
        let remainingPeak=plan.estimatedPeakBytes-alreadyCommittedInputBytes
        let headroomOK=plan.processAvailableBytes.map{
            $0>0 && remainingPeak<=($0/10)*8
        } ?? true
        guard remainingPeak<=plan.allowedBytes,
              headroomOK else {
            let available=plan.processAvailableBytes.map{
                "\($0/1_000_000)"
            } ?? "未获取"
            throw Failure.invalid(
                "Build91 原版 Double 内存预算不足 " +
                "\(plan.width)×\(plan.height)：" +
                "完整预估峰值 \(plan.estimatedPeakBytes/1_000_000) MB，" +
                "已分配输入 \(alreadyCommittedInputBytes/1_000_000) MB，" +
                "尚需 \(remainingPeak/1_000_000) MB，" +
                "允许 \(plan.allowedBytes/1_000_000) MB，" +
                "当前可分配 \(available) MB。" +
                "请明确选择较低导出分辨率，不会自动缩图、" +
                "跳过胶片颗粒或将 CPU Float64 换为 GPU Float32。"
            )
        }
    }
}
