import Foundation

@main
enum Build91PhysicalMemoryMatrixValidation {
    enum Failure:Error {case invalid(String)}
    struct Case {
        let width:Int
        let height:Int
        var pixels:Int {width*height}
    }
    static func main() throws {
        let dimensions=[
            Case(width:1000,height:1000), // 1 MP
            Case(width:1600,height:1250), // 2 MP
            Case(width:2000,height:2000), // 4 MP
            Case(width:3000,height:2400), // 7.2 MP
            Case(width:4000,height:3000), // 12 MP
            Case(width:5000,height:2600), // 13 MP
        ]
        let physical:UInt64=8_000_000_000
        let available:UInt64=6_000_000_000
        var outcomes=[String]()
        for c in dimensions {
            let p=try Build91PhysicalMemory.plan(
                width:c.width,height:c.height,
                physicalMemory:physical,processAvailable:available
            )
            let expected=UInt64(c.pixels)*120
            guard p.estimatedPeakBytes==expected,
                  p.basePeakBytes==expected,
                  p.additionalFFTBytes==0,
                  p.pixels==UInt64(c.pixels) else {
                throw Failure.invalid("Build91 1–13MP baseline peak estimate drift")
            }
            try Build91PhysicalMemory.validate(p)
            guard p.allowedBytes==4_800_000_000 else {
                throw Failure.invalid("Current 80% process memory not used")
            }
            outcomes.append("\(c.pixels/1_000_000)MP \(p.peakMB)MB PASS")
        }
        // Actual source grain+halation+scan-glare can change the
        // outcome at a SAME image geometry. No silent reduced-precision
        // or smaller-image fallback is permitted.
        let complex=try Build91PhysicalMemory.plan(
            width:3000,height:2400,
            additionalBytesPerPixel:272+120+96+40,
            physicalMemory:physical,processAvailable:available
        )
        guard complex.estimatedPeakBytes==4_665_600_000 else {
            throw Failure.invalid("Build91 did not count grain/halation/glare")
        }
        // This complex frame fits within 80% of the 6GB headroom.
        try Build91PhysicalMemory.validate(complex)
        // Restrict only the reported process headroom, not an arbitrary
        // static MB cap: identical optical features must now be rejected.
        let tightComplex=try Build91PhysicalMemory.plan(
            width:3000,height:2400,
            additionalBytesPerPixel:272+120+96+40,
            physicalMemory:physical,processAvailable:4_000_000_000
        )
        do {
            try Build91PhysicalMemory.validate(tightComplex)
            throw Failure.invalid("Complex 7.2MP exceeded 80% headroom")
        } catch Build91PhysicalMemory.Failure.invalid(_) {}
        // No OS headroom: use conservative physical-memory third fallback.
        let fallback=try Build91PhysicalMemory.plan(
            width:5000,height:2600,physicalMemory:3_000_000_000
        )
        guard fallback.allowedBytes==1_000_000_000 else {
            throw Failure.invalid("Missing process headroom fallback changed")
        }
        do {
            try Build91PhysicalMemory.validate(fallback)
            throw Failure.invalid("Fallback admitted 13MP above physical third")
        } catch Build91PhysicalMemory.Failure.invalid(_) {}

        // User's current process headroom can reject a still-valid
        // 4MP physical-memory configuration. Evaluate before decode.
        let constrained=try Build91PhysicalMemory.plan(
            width:2000,height:2000,physicalMemory:physical,
            processAvailable:400_000_000
        )
        do {
            try Build91PhysicalMemory.validate(constrained)
            throw Failure.invalid("Insufficient 80% process headroom accepted")
        } catch Build91PhysicalMemory.Failure.invalid(_) {}

        var opt=OriginalSourceDiffusion.Settings()
        opt.active=true
        opt.family = .blackProMist
        opt.strength=0.125
        opt.spatialScale=0.4
        let pixels:Double=36000.0/Double(1000)
        let fft=try Build91PhysicalMemory.fft(
            width:1000,height:1000,pixelUM:pixels,settings:opt
        )
        guard let fft else {
            throw Failure.invalid("Valid original camera PSF lacks FFT preflight")
        }
        let grid=UInt64(fft.fftWidth)*UInt64(fft.fftHeight)
        let sourceGuard=grid*40+1_000_000*48
        let rowColumn=UInt64(2*(fft.fftWidth+fft.fftHeight))*8
        let exactScratch=grid*32+rowColumn
        guard fft.sourceFFTGuardBytes==sourceGuard,
              fft.actualScratchBytes==exactScratch else {
            throw Failure.invalid("Original fft2 work allocations mismatch")
        }

        // Both camera and paper diffusion are sequential. The budget
        // must use max of their FFT workspaces instead of their sum.
        let doublePlan=try Build91PhysicalMemory.plan(
            width:1000,height:1000,
            physicalMemory:physical,processAvailable:available,
            camera:(opt,pixels),paper:(opt,pixels)
        )
        let oneFFT=fft.actualScratchBytes+fft.psfBytes
        guard doublePlan.additionalFFTBytes==oneFFT else {
            throw Failure.invalid(
                "Camera and paper non-overlapping FFT scratch was double counted"
            )
        }
        // Build136: full Double FFTs can exceed the old arbitrary
        // 512MB cap when memory permits. Low real process headroom must
        // still reject the same geometry before decode/heap allocation.
        let largeFFT=try Build91PhysicalMemory.plan(
            width:4000,height:3000,
            physicalMemory:128_000_000_000,
            processAvailable:100_000_000_000,
            camera:(opt,36_000.0/4000.0)
        )
        guard largeFFT.cameraFFT != nil,
              largeFFT.additionalFFTBytes > 512_000_000 else {
            throw Failure.invalid("Large original FFT planner discarded full workspace")
        }
        try Build91PhysicalMemory.validate(largeFFT)
        let constrainedFFT=try Build91PhysicalMemory.plan(
            width:4000,height:3000,
            physicalMemory:physical,processAvailable:500_000_000,
            camera:(opt,36_000.0/4000.0)
        )
        do {
            try Build91PhysicalMemory.validate(constrainedFFT)
            throw Failure.invalid("Low-headroom original FFT unexpectedly admitted")
        } catch Build91PhysicalMemory.Failure.invalid(_) {}

        // Reject even a 13.1MP image at a generous 128GB memory size:
        // source full-frame physical geometry is not an elastic limit.
        do {
            _=try Build91PhysicalMemory.plan(
                width:5000,height:2621,physicalMemory:128_000_000_000
            )
            throw Failure.invalid("13.105 MP source ceiling bypassed")
        } catch Build91PhysicalMemory.Failure.invalid(_) {}

        // OPT-04: demonstrate large-frame accounting without allocating
        // giant buffers or changing production geometry admission.
        for (w,h) in [(4000,4000),(6000,4000),(8000,4000)] {
            let extended=try Build91PhysicalMemory.plan(
                width:w,height:h,baseBytesPerPixel:104,
                physicalMemory:16_000_000_000,processAvailable:12_000_000_000,
                diagnosticExtendedGeometry:true
            )
            guard extended.estimatedPeakBytes==UInt64(w*h)*104 else {
                throw Failure.invalid("Extended dry-run byte accounting")
            }
            try Build91PhysicalMemory.validate(extended)
            let tight=try Build91PhysicalMemory.plan(
                width:w,height:h,baseBytesPerPixel:104,
                physicalMemory:4_000_000_000,processAvailable:900_000_000,
                diagnosticExtendedGeometry:true
            )
            do {
                try Build91PhysicalMemory.validate(tight)
                throw Failure.invalid("Extended geometry low memory was admitted")
            } catch Build91PhysicalMemory.Failure.invalid {}
        }
        do {
            _=try Build91PhysicalMemory.plan(
                width:8000,height:4001,physicalMemory:128_000_000_000,
                diagnosticExtendedGeometry:true
            )
            throw Failure.invalid("Extended FIR/YVV geometry boundary lost")
        } catch Build91PhysicalMemory.Failure.invalid {}
        print("PASS OPT-04: 16/24/32MP dry-run budget; low-headroom refusal; production ceiling unchanged")
        print("PASS BUILD91 SOURCE MEMORY PREFLIGHT: 1,2,4,7.2,12,13MP " +
              "six exact UInt64 peak estimates; dynamic 80% process" +
              " budget and physical-third fallback; 7.2MP complex" +
              " admitted with 6GB but refused with 4GB headroom;" +
              " large full source FFT admitted with sufficient memory, denied with low headroom;" +
              " camera+paper 2× sequential Double FFT scratch max, " +
              "valid 1MP FFT dimensions \(fft.fftWidth)×\(fft.fftHeight);" +
              " 13MP ceiling and out-of-range fail closed.")
        print("BUILD91 MATRIX "+outcomes.joined(separator:" | "))
    }
}
