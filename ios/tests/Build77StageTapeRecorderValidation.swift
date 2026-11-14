import Foundation

/// Small standalone validation on host Swift; iOS entrypoint is checked by
/// the separate iPhoneOS build. Do not call this scientific source parity.
@main
struct Build77StageTapeRecorderValidation {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: Build77TapeTest OUTPUT_DIRECTORY")
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1],
                         isDirectory: true)
        let recorder = try Build77StageTapeRecorder(
            width: 2, height: 1, maxTotalElements: 20
        )
        recorder.observe("cameraAutoExposureEV", [1.25])
        recorder.observe("logRaw", [0.125, -1.0, 0.25,
                                    Double.infinity, Double.nan, 4.5])
        try recorder.write(to: folder)
        let npy = try Data(contentsOf: folder.appendingPathComponent("logRaw.npy"))
        precondition(Array(npy.prefix(8)) ==
                     [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 0x01, 0x00],
                     "NPY v1 header must match the NumPy specification")
        let manifest = try Data(
            contentsOf: folder.appendingPathComponent("manifest.json")
        )
        let obj = try JSONSerialization.jsonObject(with: manifest)
        precondition(obj is [String: Any], "Expected JSON evidence manifest")

        let duplicate = try Build77StageTapeRecorder(width: 1, height: 1)
        duplicate.observe("sameName", [0.1, 0.2, 0.3])
        duplicate.observe("sameName", [0.4, 0.5, 0.6])
        var correctlyFailed = false
        do {
            try duplicate.write(to: folder.appendingPathComponent("shouldNotExist"))
        } catch {
            correctlyFailed = true
        }
        precondition(correctlyFailed, "Duplicate observer labels must fail")
        let memory = try Build77StageTapeRecorder(
            width: 1, height: 1, maxTotalElements: 2
        )
        memory.observe("tooBig", [1.0, 2.0, 3.0])
        correctlyFailed = false
        do {
            try memory.write(to: folder.appendingPathComponent("shouldNotExist"))
        } catch {
            correctlyFailed = true
        }
        precondition(correctlyFailed, "Memory budget must fail, never truncate")
        // The full source diagnostic tape must be truthful about
        // negative→paper and positive direct-film-scan topology. No
        // fabricated two print taps for the direct positive branch.
        let normal = try Build77StageTapeRecorder(
            width:1,height:1,maxTotalElements:60
        )
        for stage in ["iosInput","rgbPre","logRaw","density","paperLogExposure",
                      "paperDevelopedDensity","printed","iosOutput"] {
            normal.observe(stage,[0.25,0.5,0.75])
        }
        try normal.requirePhysicalSourceTopology(positiveFilm:false)
        let direct = try Build77StageTapeRecorder(
            width:1,height:1,maxTotalElements:60
        )
        for stage in ["iosInput","rgbPre","logRaw","density","printed","iosOutput"] {
            direct.observe(stage,[0.25,0.5,0.75])
        }
        try direct.requirePhysicalSourceTopology(positiveFilm:true)
        var rejectedMissing=false
        do {
            try direct.requirePhysicalSourceTopology(positiveFilm:false)
        } catch { rejectedMissing=true }
        precondition(rejectedMissing,
                     "Negative optical print must have both real paper stages")
        var rejectedFabricated=false
        do {
            try normal.requirePhysicalSourceTopology(positiveFilm:true)
        } catch { rejectedFabricated=true }
        precondition(rejectedFabricated,
                     "Direct positive scan must reject made-up print stages")
        // Candidate aliases are selected from actual source-stage names,
        // never created by fabricating original Python .npy data.
        let normalMap=try normal.candidateSourceTapMapping(
            positiveFilm:false,sourceGrainApplied:false
        )
        precondition(normalMap.count==7)
        precondition(normalMap["log_e_film"]=="logRaw")
        precondition(normalMap["cmy_film"]=="density")
        precondition(normalMap["log_e_print"]=="paperLogExposure")
        precondition(normalMap["cmy_print"]=="paperDevelopedDensity")
        try normal.writeCandidateSourceTapMapping(
            to:folder.appendingPathComponent("negative"),
            positiveFilm:false,sourceGrainApplied:false
        )
        let negativeManifest=try Data(contentsOf:folder
            .appendingPathComponent("negative")
            .appendingPathComponent("candidate-source-tap-mapping.json"))
        let negativeJSON=try JSONSerialization.jsonObject(
            with:negativeManifest
        ) as? [String:Any]
        precondition(
            negativeJSON?["numerically_certified"] as? Bool == false,
            "Mapped source stage shapes are NOT scientific numeric parity"
        )

        let directMap=try direct.candidateSourceTapMapping(
            positiveFilm:true,sourceGrainApplied:false
        )
        precondition(directMap.count==5)
        precondition(directMap["log_e_print"]==nil)
        precondition(directMap["cmy_print"]==nil)
        try direct.writeCandidateSourceTapMapping(
            to:folder.appendingPathComponent("positive"),
            positiveFilm:true,sourceGrainApplied:false
        )

        let grain=try Build77StageTapeRecorder(
            width:1,height:1,maxTotalElements:60
        )
        for name in ["iosInput","rgbPre","logRaw","density","grainDensity",
                     "paperLogExposure","paperDevelopedDensity",
                     "printed","iosOutput"] {
            grain.observe(name,[0.25,0.5,0.75])
        }
        let grainMap=try grain.candidateSourceTapMapping(
            positiveFilm:false,sourceGrainApplied:true
        )
        precondition(grainMap["cmy_film"]=="grainDensity")
        try grain.writeCandidateSourceTapMapping(
            to:folder.appendingPathComponent("negativeGrain"),
            positiveFilm:false,sourceGrainApplied:true
        )
        var missingGrainRejected=false
        do {
            _ = try normal.candidateSourceTapMapping(
                positiveFilm:false,sourceGrainApplied:true
            )
        } catch { missingGrainRejected=true }
        precondition(
            missingGrainRejected,
            "Source grain requested without real cmy_film must fail"
        )
        let badOrder=try Build77StageTapeRecorder(
            width:1,height:1,maxTotalElements:60
        )
        for name in ["iosInput","rgbPre","logRaw","density",
                     "paperLogExposure","grainDensity",
                     "paperDevelopedDensity","printed","iosOutput"] {
            badOrder.observe(name,[0.25,0.5,0.75])
        }
        var badOrderRejected=false
        do {
            _ = try badOrder.candidateSourceTapMapping(
                positiveFilm:false,sourceGrainApplied:true
            )
        } catch { badOrderRejected=true }
        precondition(
            badOrderRejected,
            "Grain post-paper stage must not be mislabeled cmy_film"
        )
        print("PASS Build77 candidate 7/5 Python tap manifest:"
              + " correct grain selection, failed fabricated branch,"
              + " invalid order rejected; NOT numerical parity")
        print("Build77 host Double NPY encoder PASS; not Python/iOS parity")
    }
}
