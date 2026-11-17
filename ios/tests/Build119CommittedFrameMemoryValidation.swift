import Foundation

@main
enum Build119CommittedFrameMemoryValidation {
    enum Failure:Error {case invalid(String)}
    static func demand(_ result:Bool,_ message:String)throws {
        if !result {throw Failure.invalid(message)}
    }
    static func main() throws {
        // Exact evidence from Build118 13MP Numba second-stage gate:
        // estimated 2392MB, processAvailable 2873MB, allowed 2298MB.
        let peak=UInt64(13_000_000)*184
        let committed=UInt64(13_000_000)*3*8
        let avail:UInt64=2_873_685_440
        let plan=try Build91PhysicalMemory.plan(
            width:5000,height:2600,baseBytesPerPixel:112,
            additionalBytesPerPixel:72,physicalMemory:4_000_000_000,
            processAvailable:avail
        )
        try demand(plan.estimatedPeakBytes==peak,"Build118 13MP Numba budget changed")
        // Pre-decode cannot claim an input frame before it exists.
        do {
            try Build91PhysicalMemory.validate(plan)
            throw Failure.invalid("Original no-credit predecode gate must reject")
        } catch Build91PhysicalMemory.Failure.invalid(_) {}
        // developInPlace receives one already allocated RGB Float64 frame.
        // Do NOT charge those 312MB against the remaining process headroom.
        try Build91PhysicalMemory.validate(
            plan,alreadyCommittedInputBytes:committed
        )
        try demand(peak-committed==2_080_000_000,
                   "Only 312MB of existing Float64 input may be credited")
        // Dynamic headroom gate stays active under genuine memory pressure.
        let tight=try Build91PhysicalMemory.plan(
            width:5000,height:2600,baseBytesPerPixel:112,
            additionalBytesPerPixel:72,physicalMemory:4_000_000_000,
            processAvailable:2_300_000_000
        )
        do {
            try Build91PhysicalMemory.validate(
                tight,alreadyCommittedInputBytes:committed
            )
            throw Failure.invalid("Insufficient late-stage headroom admitted")
        } catch Build91PhysicalMemory.Failure.invalid(_) {}
        // A caller cannot invent committed scratch or discount the estimate.
        do {
            try Build91PhysicalMemory.validate(
                plan,alreadyCommittedInputBytes:plan.basePeakBytes+1
            )
            throw Failure.invalid("Caller credited unallocated future scratch")
        } catch Build91PhysicalMemory.Failure.invalid(_) {}
        // Existing 8/10/13MP cases remain gated at predecode. No change
        // to the original optical calculations or buffer allocation.
        for (w,h) in [(4000,2000),(4000,2500),(5000,2600)] {
            let ordinary=try Build91PhysicalMemory.plan(
                width:w,height:h,baseBytesPerPixel:112,
                additionalBytesPerPixel:64,
                physicalMemory:4_000_000_000,
                processAvailable:3_200_000_000
            )
            try Build91PhysicalMemory.validate(ordinary)
        }
        print("PASS Build119 13MP inner 312MB input-frame double-count fix, unchanged predecode/80%-headroom and unsafe-credit rejection")
    }
}
