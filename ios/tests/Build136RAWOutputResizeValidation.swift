import Foundation

@main
struct Build136RAWOutputResizeValidation {
    static func main() throws {
        precondition(ExportResolutionMode.presetWanPixels == [720,800,900,1000,1200])
        for count in ExportResolutionMode.presetWanPixels {
            let plan=try SafeExportResolution.plan(
                width:4032,height:3024,
                physicalMemory:8_000_000_000,
                processAvailableMemory:5_000_000_000,
                mode:.megapixels(count),estimatedBytesPerPixel:128,
                fullSourceProcessing:true
            )
            precondition(plan.dimensions.pixels<=UInt64(count*10_000))
            precondition(plan.dimensions.pixels>UInt64(count*10_000-20_000))
            precondition(plan.fullSourceProcessing && plan.dimensions.reduced)
            // Build140: optical arrays and final packing do not peak
            // concurrently; reserve the larger stage, NOT their sum.
            let sourcePeak=UInt64(4032*3024)*128
            let packingPeak=UInt64(4032*3024)*24 +
                plan.dimensions.pixels*48
            precondition(plan.estimatedPeakBytes==max(sourcePeak,packingPeak))
            try SafeExportResolution.validateForHeadroom(
                plan,processAvailableMemory:5_000_000_000)
        }
        let full=try SafeExportResolution.plan(
            width:4032,height:3024,physicalMemory:8_000_000_000,
            processAvailableMemory:5_000_000_000,mode:.megapixels(1200),
            estimatedBytesPerPixel:128,fullSourceProcessing:true
        )
        do {
            try SafeExportResolution.validateForHeadroom(
                full,processAvailableMemory:900_000_000)
            fatalError("Must reject low-headroom full-size RAW processing")
        } catch SafeExportResolution.Failure.invalid {}
        do {
            _=try SafeExportResolution.plan(
                width:4032,height:3024,physicalMemory:8_000_000_000,
                processAvailableMemory:5_000_000_000,mode:.megapixels(1250))
            fatalError("Unknown preset accepted")
        } catch SafeExportResolution.Failure.invalid {}
        let constant=(0..<12).flatMap { _ in [-0.125,0.5,1.625] }
        let out=try Build136RAWOutputResize.resample(
            width:4,height:3,rgb:constant,
            targetWidth:2,targetHeight:2
        )
        for i in stride(from:0,to:out.rgb.count,by:3) {
            precondition(abs(out.rgb[i]+0.125)<1e-9)
            precondition(abs(out.rgb[i+1]-0.5)<1e-9)
            precondition(abs(out.rgb[i+2]-1.625)<1e-9)
        }
        let mean=try Build136RAWOutputResize.resample(
            width:2,height:2,rgb:[
                0,0,0, 2,2,2,
                4,4,4, 6,6,6
            ],targetWidth:1,targetHeight:1)
        precondition(mean.rgb==[3.0,3.0,3.0])
        let original=try Build136RAWOutputResize.resample(
            width:2,height:2,rgb:[Double](repeating:0.5,count:12),
            targetWidth:2,targetHeight:2)
        precondition(original.rgb.count==12)
        print("PASS Build136 720/800/900/1000/1200 fixed sizes, full RAW source memory estimate, low memory refusal, signed HDR Float64 output-only area resize")
    }
}
