import Foundation
import CoreImage
import CoreGraphics

// Build97 macOS-only safety regression. It is NOT an iPhone16.5.1
// device test, not proof of original Python numeric equivalence.
func ensure(_ result: @autoclosure () -> Bool, _ label: String) {
    if !result() { fatalError("Build97 P0 FAIL: " + label) }
}

let base = CIImage(
    color: CIColor(red:0.24, green:0.51, blue:0.81, alpha:1)
).cropped(to:CGRect(x:0,y:0,width:32,height:24))
let accepted=try Build97FilterContract.required(base,stage:"positive image")
ensure(accepted.extent.width==32,"valid filter result returns image")
var missingRejected=false
do {
    _ = try Build97FilterContract.required(nil,stage:"injected-nil-kernel")
} catch {
    ensure(error.localizedDescription.contains("injected-nil-kernel"),
           "first failing stage reported")
    missingRejected=true
}
ensure(missingRejected,"nil filter must never return unchanged source")
var emptyRejected=false
do {
    _ = try Build97FilterContract.required(
        CIImage.empty(),stage:"injected-empty-kernel"
    )
} catch { emptyRejected=true }
ensure(emptyRejected,"empty filter result rejected")

let noOptics=try SpatialOptics.apply(
    to:base,settings:SpatialOpticsSettings()
)
ensure(noOptics.extent==base.extent,"disabled optics returns image unchanged")
let noScanner=try ScannerFinishing.apply(
    to:base,settings:ScannerFinishSettings()
)
ensure(noScanner.extent==base.extent,"disabled scanner returns image unchanged")

// Exercise real enabled Core Image kernels, not only a textual static check.
let optics=try SpatialOptics.apply(
    to:base,
    settings:SpatialOpticsSettings(
        scatterAmount:0.15, halationAmount:0.3,
        filmUse:"still", antihalation:"weak"
    )
)
var finish=ScannerFinishSettings()
finish.enabled=true
finish.applyGlare=true
finish.glarePercent=0.03
finish.unsharpAmount=0.7
let processed=try ScannerFinishing.apply(to:optics,settings:finish)
let ci=CIContext(options:[.cacheIntermediates:false])
guard let rendered=ci.createCGImage(processed,from:processed.extent) else {
    fatalError("Build97 P0 FAIL: enabled CI stages failed to render")
}
ensure(rendered.width==32 && rendered.height==24,
       "enabled optics/scanner retain geometry")

var physical=try SafeExportResolution.plan(
    width:4000,height:3000,
    physicalMemory:8_000_000_000,
    processAvailableMemory:2_000_000_000,
    mode:.original
)
ensure(physical.dimensions.width==4000 &&
       physical.dimensions.height==3000,
       "explicit original geometry never reduced")
try SafeExportResolution.validateForHeadroom(
    physical,processAvailableMemory:2_000_000_000
)
var insufficientRejected=false
do {
    try SafeExportResolution.validateForHeadroom(
        physical,processAvailableMemory:1_000_000_000
    )
} catch { insufficientRejected=true }
ensure(insufficientRejected,"original JPEG now rejects low live RAM")

let oversize=try SafeExportResolution.plan(
    width:8000,height:5000,physicalMemory:8_000_000_000,
    processAvailableMemory:8_000_000_000,mode:.original
)
ensure(oversize.dimensions.pixels==40_000_000,
       "original mode never silently shrinks 40MP")
// Build135: remove obsolete 1500MB/physical-RAM-third ceiling.
// 40MP is preserved when live OS process headroom genuinely supports
// its 4160MB estimated peak; refuse at lower available headroom.
try SafeExportResolution.validateForHeadroom(
    oversize,processAvailableMemory:8_000_000_000
)
ensure(oversize.estimatedPeakBytes==4_160_000_000,
       "40MP complete-image estimate remains truthful")
var lowHeadroomRejected=false
do {
    try SafeExportResolution.validateForHeadroom(
        oversize,processAvailableMemory:5_000_000_000
    )
} catch { lowHeadroomRejected=true }
ensure(lowHeadroomRejected,"40MP must refuse insufficient live memory")

let reduced=try SafeExportResolution.plan(
    width:8000,height:5000,
    physicalMemory:8_000_000_000,
    processAvailableMemory:1_000_000_000,
    mode:.safe
)
ensure(reduced.dimensions.reduced &&
       reduced.dimensions.pixels<=12_000_000,
       "safe reduction only by explicit mode")
try SafeExportResolution.validateForHeadroom(
    reduced,processAvailableMemory:1_000_000_000
)

print("PASS Build97 P0 CoreImage explicit nil/empty rejection, disabled-stage identity, " +
      "original JPEG dynamic 40MP admission/low-memory refusal, explicit safe geometry")
