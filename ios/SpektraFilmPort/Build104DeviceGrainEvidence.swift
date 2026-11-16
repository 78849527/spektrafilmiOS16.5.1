import Foundation
import CryptoKit

/// Build104 separate original-Python grain.py/fast_stats.py physical-device
/// measurements. No generated Swift mock reference and no default-prange
/// certification. Store FIRST actual error and never synthesize success.
enum Build104DeviceGrainEvidence {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message)=self { return message }
            return nil
        }
    }
    struct Fixture: Decodable {
        let name: String
        let width: Int
        let height: Int
        let pixelUM: Double
        let dyeBlur: Double
        let finalBlur: Double
        let microUM: Double
        let microNM: Double
        let maxima: [Double]
        let microEnabled: Bool
        let useFastStats: Bool
        let sha256: [String:String]
    }
    struct Manifest: Decodable {
        let scope: String
        let numba_seed: UInt32
        let cases: [Fixture]
    }
    struct Stage: Codable {
        let caseName: String
        let stageName: String
        let channelCount: Int
        let mae: Double
        let rmse: Double
        let maximumAbsoluteError: Double
        let expectedPythonSHA256: String
        let tolerance: Double
    }
    struct Report: Codable {
        let schema: Int
        let appVersion: String
        let appBuild: String
        let compiledSourceCommit: String
        let deviceModel: String
        let osVersion: String
        let physicalDevice: Bool
        let generatedUTC: String
        let pythonReferenceManifestSHA256: String?
        let originalSourceScope: String
        let controlledSeed: UInt32
        let stageMetricCount: Int
        let stageMetrics: [Stage]
        let singleLayerFlagIgnoredMatchesSource: Bool
        let failure: String?
        let passedOnTarget: Bool
        let status: String
        let fullPythonOriginalCertified: Bool
        let limitations: [String]
    }
    static func sha(_ data:Data)->String {
        SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    private static func original(
        directory:URL, sample:Fixture, stage:String
    ) throws -> [Double] {
        guard let hash=sample.sha256[stage] else {
            throw Failure.invalid("缺少原版阶段 SHA "+sample.name+"/"+stage)
        }
        let path=directory.appendingPathComponent(
            sample.name+"."+stage+".f64le")
        let data=try Data(contentsOf:path)
        let channels=(stage=="sublayers" ? 9 : 3)
        guard data.count==sample.width*sample.height*channels*8,
              sha(data)==hash else {
            throw Failure.invalid("原版 Python SHA 或长度不匹配 "+path.lastPathComponent)
        }
        return data.withUnsafeBytes { raw in
            (0..<(data.count/8)).map { i in
                let bits=raw.loadUnaligned(
                    fromByteOffset:i*8,as:UInt64.self)
                return Double(bitPattern:UInt64(littleEndian:bits))
            }
        }
    }
    private static func evaluate(
        directory:URL, stages:inout [Stage]
    ) throws -> (String,Bool) {
        let url=directory.appendingPathComponent("manifest.json")
        let data=try Data(contentsOf:url)
        let manifest=try JSONDecoder().decode(Manifest.self,from:data)
        guard manifest.cases.count==5,manifest.numba_seed==8888,
              manifest.scope.contains("unmodified original grain.py"),
              manifest.cases.filter({$0.useFastStats}).count==2 else {
            throw Failure.invalid("原版 grain.py 的五组独立参考清单不完整")
        }
        let stageMap=[
            ("sublayers","sourceGrainSublayers"),
            ("dyeClouds","sourceGrainDyeClouds"),
            ("microstructure","sourceGrainMicrostructure"),
            ("final","sourceGrainFinalDensity")
        ]
        for sample in manifest.cases {
            let w=sample.width,h=sample.height
            guard sample.maxima.count==9,
                  (sample.microNM*0.001/sample.pixelUM>0.05)==sample.microEnabled else {
                throw Failure.invalid("源亚层或微结构阈值元数据错误 "+sample.name)
            }
            let maxima=sample.maxima
            let density=(0..<(w*h*3)).map { k -> Double in
                let p=k/3,ch=k%3
                return 0.12+0.015*Double((p+ch*4)%9)
            }
            let fraction=(0..<9).map { i -> Double in
                let ch=i%3
                return maxima[i]/(maxima[ch]+maxima[ch+3]+maxima[ch+6])
            }
            let measured=OriginalSourcePhysicalGrain.MeasuredLayers(
                maxima:maxima,
                sublayers:{input in (0..<9).map{i in input[i%3]*fraction[i]}}
            )
            var settings=OriginalSourcePhysicalGrain.Settings()
            settings.active=true
            settings.useFastStats=sample.useFastStats
            settings.fastStatsSeed=sample.useFastStats ? 8888 : nil
            settings.numbaSeed=8888
            settings.dyeCloudBlurUM=sample.dyeBlur
            settings.grainBlur=sample.finalBlur
            settings.microstructureUM=sample.microUM
            settings.microstructureNM=sample.microNM
            var snapshots=[String:[Double]]()
            let actual=try OriginalSourcePhysicalGrain.apply(
                density,width:w,height:h,pixelUM:sample.pixelUM,
                measured:measured,settings:settings,
                stageObserver:{name,values in snapshots[name]=values}
            )
            for (upstream,swift) in stageMap {
                guard let got=snapshots[swift] else {
                    throw Failure.invalid("Swift 中间阶段缺失 "+sample.name+"/"+swift)
                }
                let source=try original(directory:directory,
                                        sample:sample,stage:upstream)
                guard got.count==source.count else {
                    throw Failure.invalid("Float64 阶段长度错误 "+sample.name+"/"+upstream)
                }
                var maxError=0.0,mae=0.0,msq=0.0
                for i in got.indices {
                    let error=abs(got[i]-source[i])
                    guard error.isFinite && error<=1e-10 else {
                        throw Failure.invalid(
                            "Python 原版偏差 "+sample.name+"/"+upstream+" index=\(i) delta=\(error)")
                    }
                    maxError=max(maxError,error)
                    mae+=error
                    msq+=error*error
                }
                stages.append(Stage(
                    caseName:sample.name,stageName:upstream,
                    channelCount:got.count,
                    mae:mae/Double(got.count),
                    rmse:sqrt(msq/Double(got.count)),
                    maximumAbsoluteError:maxError,
                    expectedPythonSHA256:sample.sha256[upstream]!,
                    tolerance:1e-10
                ))
            }
            var noMicroSeed=settings
            noMicroSeed.numbaSeed=nil
            if sample.microEnabled {
                do {
                    _=try OriginalSourcePhysicalGrain.apply(
                        density,width:w,height:h,pixelUM:sample.pixelUM,
                        measured:measured,settings:noMicroSeed)
                    throw Failure.invalid("激活微结构却无 Numba seed，被错误接受")
                } catch OriginalSourcePhysicalGrain.Failure.invalid {}
            } else {
                let noSeed=try OriginalSourcePhysicalGrain.apply(
                    density,width:w,height:h,pixelUM:sample.pixelUM,
                    measured:measured,settings:noMicroSeed)
                guard noSeed==actual else {
                    throw Failure.invalid("非激活微结构错误依赖微结构 seed")
                }
            }
        }
        // The Python single-layer branch does not pass use_fast_stats.
        // Run same production SciPy path both ways on device.
        let density=(0..<36).map{k in 0.04+Double(k%9)*0.07}
        var single=OriginalSourcePhysicalGrain.Settings()
        single.active=true
        single.sublayersActive=false
        single.nSubLayers=3
        single.grainBlur=0.65
        let baseline=try OriginalSourcePhysicalGrain.applySingleLayer(
            density,width:4,height:3,pixelUM:1.8,
            maximum:[2.2,2.2,2.2],settings:single)
        single.useFastStats=true
        let ignored=try OriginalSourcePhysicalGrain.applySingleLayer(
            density,width:4,height:3,pixelUM:1.8,
            maximum:[2.2,2.2,2.2],settings:single)
        guard ignored==baseline,baseline.allSatisfy({$0.isFinite}) else {
            throw Failure.invalid("单层 SciPy fast_stats 标志非原版忽略分支")
        }
        guard stages.count==20 else {
            throw Failure.invalid("20 个源颗粒 Float64 阶段未全部执行")
        }
        return (sha(data),true)
    }
    static func capture(
        version:String,build:String,commit:String,
        device:String,osVersion:String,physicalDevice:Bool,
        directory:URL?,now:Date=Date()
    )->Report {
        var stages=[Stage]()
        var sourceHash:String?
        var singleOK=false
        var failure:String?
        do {
            guard let directory else {
                throw Failure.invalid("Build104 原版 Python 颗粒参考未打包")
            }
            let result=try evaluate(directory:directory,stages:&stages)
            sourceHash=result.0
            singleOK=result.1
        } catch {
            failure=error.localizedDescription
        }
        let commitValid=commit.count==40 &&
            commit.utf8.allSatisfy{($0>=48 && $0<=57) ||
                                    ($0>=97 && $0<=102)}
        let onTarget=physicalDevice && osVersion=="16.5.1" &&
            commitValid && stages.count==20 && singleOK && failure==nil
        let timestamp=ISO8601DateFormatter().string(from:now)
        return Report(
            schema:1,appVersion:version,appBuild:build,
            compiledSourceCommit:commit,deviceModel:device,
            osVersion:osVersion,physicalDevice:physicalDevice,
            generatedUTC:timestamp,
            pythonReferenceManifestSHA256:sourceHash,
            originalSourceScope:"5 original grain.py frames x 4 stages; 36-case SciPy tested in CI",
            controlledSeed:8888,
            stageMetricCount:stages.count,stageMetrics:stages,
            singleLayerFlagIgnoredMatchesSource:singleOK,
            failure:failure,passedOnTarget:onTarget,
            status:onTarget ? "controlled_20_grain_stages_pass_on_ios1651" :
                (failure==nil ? "grain_stages_pass_non_target_or_wrong_binary" :
                    "grain_source_parity_failed"),
            fullPythonOriginalCertified:false,
            limitations:[
                "5 small controlled Python grain fixtures; not default unseeded multiworker Numba prange",
                "Single-layer source flag branch tests reproducible SciPy output but not all default source parameters",
                "Does not measure 13MP original rendering RSS, RAW or end-to-end ICC/EXIF/XMP parity"
            ]
        )
    }
    static func write(_ report:Report,documents:URL)throws->URL {
        let folder=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true)
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true)
        let file=folder.appendingPathComponent(
            "Build104-device-grain-"+UUID().uuidString+".json")
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:file,options:.atomic)
        return file
    }
}
