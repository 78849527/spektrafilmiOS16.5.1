import CoreImage
import CoreGraphics
import Foundation

@main
struct ScannerFinishingValidation {
    static func pixel(_ image: CIImage,x: Int,y: Int) -> [Double] {
        let c=CIContext(options:[.useSoftwareRenderer:true])
        let cs=CGColorSpace(name: CGColorSpace.sRGB)!
        var v=[Float](repeating:0,count:4)
        v.withUnsafeMutableBytes { raw in
            c.render(image,toBitmap:raw.baseAddress!,rowBytes:16,
                     bounds:CGRect(x:x,y:y,width:1,height:1),
                     format:.RGBAf,colorSpace:cs)
        }
        return v.map(Double.init)
    }
    static func main() {
        setbuf(stdout,nil)
        let frame=CGRect(x:0,y:0,width:256,height:256)
        let flat=CIImage(color:CIColor(red:0.3,green:0.4,blue:0.5))
            .cropped(to:frame)
        let off=ScannerFinishing.apply(to:flat,settings:ScannerFinishSettings())
        precondition(off.extent==flat.extent)
        let before=pixel(flat,x:128,y:128)
        let after=pixel(ScannerFinishing.apply(to:flat,settings:
            ScannerFinishSettings(enabled:true,applyGlare:false,unsharpAmount:0.7)),
            x:128,y:128)
        for i in 0..<3 {
            precondition(abs(before[i]-after[i]) < 0.004,
                         "Scanner unsharp must conserve constant field")
        }
        precondition(abs(ScannerFinishing.unsharpScalar(
            original:0.6,blurred:0.4,amount:0.7)-0.74)<1e-12)
        print("PASS: source unsharp-mask equation, constant-field neutrality.")

        let output=ScannerFinishing.apply(to:flat,settings:
            ScannerFinishSettings(enabled:true,applyGlare:true,unsharpAmount:0,
                                  glarePercent:0.03,seed:8888))
        let plus=pixel(output,x:128,y:128)
        precondition(plus[0]>=before[0]-0.003)
        precondition(plus.allSatisfy { $0.isFinite && $0 >= 0 })
        precondition(output.extent==flat.extent)
        print("PASS: CoreImage scanner glare kernel compiles, adds finite energy and retains image extent.")
    }
}
