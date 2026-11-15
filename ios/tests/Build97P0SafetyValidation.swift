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
var capRejected=false
do {
    try SafeExportResolution.validateForHeadroom(
        oversize,processAvailableMemory:8_000_000_000
    )
} catch { capRejected=true }
ensure(capRejected,"over-physical-cap original must fail closed")

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
      "original JPEG live RAM admission, physical cap, explicit safe geometry")
