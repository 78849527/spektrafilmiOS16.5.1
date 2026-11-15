import Foundation

/// Same executable compiled TWICE against separate production source
/// revisions: Build90 unpooled FFT versus Build91 pooled FFT. This
/// measures wall time with fixed deterministic full-source output,
/// not a synthetic isolated butterfly that changes convolution order.
@main
enum Build91DoubleFFTBenchmark {
    enum Failure:Error {case invalid(String)}
    static func main()throws {
        guard CommandLine.arguments.count==2 else {
            throw Failure.invalid("Need output full-frame Float64 JSON path")
        }
        var results=[[String:Any]]()
        for (w,h) in [(113,87),(320,224)] {
            let input=(0..<(w*h*3)).map {k->Double in
                Double((k*97+23)%241)/241.0 +
                0.0007*Double((k/11)%4)
            }
            var s=OriginalSourceDiffusion.Settings()
            s.active=true
            s.family = .blackProMist
            s.strength=0.5
            s.spatialScale=0.7
            let start=Date().timeIntervalSinceReferenceDate
            let processed=try OriginalSourceDiffusion.apply(
                input,width:w,height:h,pixelUM:1000,settings:s
            )
            let elapsed=Date().timeIntervalSinceReferenceDate-start
            guard processed.count==input.count,
                  processed.allSatisfy({$0.isFinite}) else {
                throw Failure.invalid("Full source FFT performance produced NaN")
            }
            results.append([
                "width":w,"height":h,"elapsedSeconds":elapsed,
                "pixels":processed
            ])
            print("BUILD91 FFT BENCH \(w)x\(h): " +
                  String(format:"%.6f",elapsed)+" s; CPU Float64 source")
        }
        let data=try JSONSerialization.data(
            withJSONObject:["cases":results],options:[.sortedKeys]
        )
        try data.write(
            to:URL(fileURLWithPath:CommandLine.arguments[1])
        )
    }
}
