import Foundation

/// Build114: compare NEW bounded-memory FIR/YVV production against the
/// retained original whole-frame Double implementation. No visual metrics
/// can substitute for these per-channel output comparisons.
@main
struct Build114InPlaceDIRValidation {
    struct Scenario {
        let width:Int
        let height:Int
        let core:Double
        let tail:Double
        let weight:Double
        let rgb:Bool
    }
    static func main() throws {
        let cases:[Scenario]=[
            .init(width:1,height:1,core:0,tail:0,weight:0,rgb:false),
            .init(width:4,height:3,core:0.2,tail:2.7,weight:0.2,rgb:true),
            .init(width:15,height:11,core:1.5,tail:7.5,weight:0.28,rgb:false),
            .init(width:41,height:23,core:3.0,tail:18,weight:0.4,rgb:true),
            .init(width:73,height:41,core:0.01,tail:40,weight:0.8,rgb:false),
            .init(width:127,height:91,core:7,tail:27,weight:0.0,rgb:false),
            .init(width:200,height:149,core:12,tail:100,weight:0.67,rgb:true),
        ]
        var tested=0
        var maximum=0.0
        for (caseIndex,test) in cases.enumerated() {
            var samples=[Double](repeating:0,count:test.width*test.height*3)
            for p in 0..<(test.width*test.height) {
                for ch in 0..<3 {
                    let x=Double((p*131+ch*17+caseIndex*19)%991)/991.0
                    samples[p*3+ch]=0.001+0.99*x
                }
            }
            let coreRGB=test.rgb ? [test.core,test.core*0.8,test.core*1.2] : nil
            let tailRGB=test.rgb ? [test.tail,test.tail*0.75,test.tail*1.25] : nil
            let reference=try SourceSpatialDIRConvolution.diffuseMemoryBounded(
                samples,width:test.width,height:test.height,
                coreSigma:test.core,tailSigma:test.tail,tailWeight:test.weight,
                coreSigmaRGB:coreRGB,tailSigmaRGB:tailRGB)
            var inPlace=samples
            try SourceSpatialDIRConvolution.diffuseInPlaceMemoryBounded(
                &inPlace,width:test.width,height:test.height,
                coreSigma:test.core,tailSigma:test.tail,tailWeight:test.weight,
                coreSigmaRGB:coreRGB,tailSigmaRGB:tailRGB)
            precondition(reference.count==inPlace.count)
            for k in reference.indices {
                let delta=abs(reference[k]-inPlace[k])
                maximum=max(maximum,delta)
                if reference[k].bitPattern != inPlace[k].bitPattern {
                    // A changed floating point evaluation order is not an
                    // equivalent in-place memory optimization.
                    fatalError("Build114 Float64 DIR non-bit-identical case=\(caseIndex), pixel=\(k/3), channel=\(k%3), delta=\(delta)")
                }
                tested+=1
            }
        }
        let fullPixels=13_000_000
        let baseEstimate=fullPixels*112
        precondition(baseEstimate==1_456_000_000)
        precondition(baseEstimate<1_500_000_000)
        precondition(baseEstimate + fullPixels*40 > 1_500_000_000,
            "Optional source optics must not fit under the baseline memory gate")
        print("PASS Build114 original FIR/YVV exact in-place Float64: \(cases.count) cases, \(tested) channels, max=\(maximum); 13MP baseline admission estimate \(baseEstimate/1_000_000)MB. NOT measured device RSS.")
    }
}
