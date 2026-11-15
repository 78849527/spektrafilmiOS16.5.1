import Foundation

func require(_ condition: @autoclosure () -> Bool, _ title: String) {
    if !condition() { fatalError("Build99 interaction regression FAIL: " + title) }
}
require(Build99InteractionRules.nextPhotoScale(1) == 2,"first doubletap zoom 2x")
require(Build99InteractionRules.nextPhotoScale(2) == 1,"second doubletap reset")
require(Build99InteractionRules.nextPhotoScale(.nan) == 2,"non-finite zoom restored")
require(Build99InteractionRules.compareDivider(x:50,width:100)==0.5,
        "split at half")
require(Build99InteractionRules.compareDivider(x:-20,width:100)==0.02,
        "split low clamped")
require(Build99InteractionRules.compareDivider(x:200,width:100)==0.98,
        "split high clamped")
require(Build99InteractionRules.compareDivider(x:12,width:0)==0.5,
        "zero width safe")
require(Build99InteractionRules.compareDivider(x:.nan,width:100)==0.5,
        "invalid pointer safe")
require(!Build99InteractionRules.acceptsPreview(generation:9,current:10),
        "stale wheel generation forbidden")
require(Build99InteractionRules.acceptsPreview(generation:10,current:10),
        "latest wheel generation accepted")
require(!Build99InteractionRules.canExport(pendingSelectedMaterial:true),
        "pending or failed film may not export old LUT")
require(Build99InteractionRules.canExport(pendingSelectedMaterial:false),
        "confirmed current film permits export")
print("PASS Build99 real zoom/divider, stale-generation and material export gate 12/12")
