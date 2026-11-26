import Foundation

@main
struct OPTHanatosMitchellValidation {
    static func main() throws {
        var count=0
        let samples:[[Double]]=[
            [0,0,0],[1,1,1],[1,0,0],[0,1,0],[0,0,1],
            [-0.1,0.4,2.0],[2.4,-0.2,0.5],[0.01,0.02,0.03],
            [1e-12,2e-12,3e-12],[-0.0,0.0,-0.0],
            [-1,1,0],[1e-100,1e-100,1e-100]
        ]+(0..<512).map { i in
            (0..<3).map { c in Double((i*31+c*17)%997)/313.0-0.15 }
        }
        for stock in GeneratedHanatosPreciseData.lutByFilm.keys.sorted() {
            for space:OriginalHanatosResponse.InputColorSpace in [.sRGB,.proPhotoLinear,.acesLinear] {
                let engine=try OriginalHanatosResponse(filmID:stock,inputColorSpace:space)
                for rgb in samples {
                    let ref=engine.raw(linearRGB:rgb,scalarInterpolation:true)
                    let actual=engine.raw(linearRGB:rgb)
                    precondition(actual.map{$0.bitPattern}==ref.map{$0.bitPattern},
                                 "OPT Hanatos Mitchell SIMD changed source bits: "+stock)
                    let lanes=engine.rawLanes(SIMD3<Double>(rgb[0],rgb[1],rgb[2]))
                    precondition([lanes[0],lanes[1],lanes[2]].map{$0.bitPattern}==ref.map{$0.bitPattern},
                                 "OPT Hanatos value lanes changed source bits: "+stock)
                    count+=1
                }
            }
        }
        precondition(count>0)
        print("PASS OPT Hanatos Mitchell real measured Float64 LUT \(count) RGB cases bitwise")
    }
}
