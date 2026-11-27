import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Local-only, bounded diagnostic journal. Never stores raw pixels, paths,
/// hashes or rendered photos. Error text may contain a filename.
enum OPTDeviceFeedback {
    struct Event: Codable {
        let runID:String
        let operation:String
        let stage:String
        let date:Date
        let elapsedSeconds:Double
        let rssBytes:UInt64?
        let physicalFootprintBytes:UInt64?
        let availableBytes:UInt64?
        let details:[String:String]
    }
    struct Report: Codable {
        let schema:Int
        let version:String
        let build:String
        let sourceCommit:String
        let os:String
        let events:[Event]
    }
    private struct Active {
        let id:String
        let operation:String
        let started:Double
    }
    private static let lock=NSLock()
    private static var active:Active?
    // Keep complete recent runs, not only the last 160 stage events.
    // The current run has its own atomic crash checkpoint, so a long
    // history is not re-encoded for every individual grain phase.
    private static let historyLimit=4096
    private static var currentEvents=[Event]()
    #if canImport(UIKit)
    private static var screenOwner:String?
    private static var previousIdleTimerDisabled=false
    private static var lifecycleObservers=[NSObjectProtocol]()
    #endif
    private static let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"
    private static let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown"
    private static let commit=Bundle.main.object(forInfoDictionaryKey:"SFSourceCommit") as? String ?? "missing"
    private static var events:[Event]={
        var recovered=[Event]()
        for activeCheckpoint in [false,true] {
            guard let url=try? journalURL(activeCheckpoint:activeCheckpoint),
                  let data=try? Data(contentsOf:url),
                  let old=try? JSONDecoder().decode(Report.self,from:data),
                  old.sourceCommit==commit,old.build==build else {continue}
            for event in old.events where !recovered.contains(where:{
                $0.runID==event.runID && $0.date==event.date && $0.stage==event.stage
            }) {recovered.append(event)}
        }
        recovered.sort{$0.date<$1.date}
        return Array(recovered.suffix(historyLimit))
    }()
    private static func journalURL(activeCheckpoint:Bool=false) throws -> URL {
        guard let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder=docs.appendingPathComponent("SpektraFilm Verification",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return folder.appendingPathComponent(activeCheckpoint
            ? "OPT-Device-Performance-active.json" : "OPT-Device-Performance-last.json")
    }
    private static func writeLocked(activeCheckpoint:Bool=false) throws -> URL {
        let payload=activeCheckpoint ? currentEvents : events+currentEvents
        let report=Report(schema:2,version:version,build:build,sourceCommit:commit,
            os:ProcessInfo.processInfo.operatingSystemVersionString,events:payload)
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let url=try journalURL(activeCheckpoint:activeCheckpoint)
        try encoder.encode(report).write(to:url,options:.atomic)
        return url
    }
    static func export() throws -> URL {
        lock.lock()
        defer {lock.unlock()}
        return try writeLocked()
    }
    static func recordStandalone(operation:String,stage:String,details:[String:String]) {
        lock.lock()
        defer {lock.unlock()}
        events.append(Event(runID:UUID().uuidString,operation:operation,stage:stage,date:Date(),
            elapsedSeconds:0,rssBytes:Build133RAWMemoryLadder.resident(),
            physicalFootprintBytes:Build133RAWMemoryLadder.footprint(),
            availableBytes:Build133RAWMemoryLadder.available(),details:details))
        while events.count>historyLimit,let oldest=events.first?.runID {
            events.removeAll{$0.runID==oldest}
        }
        _=try? writeLocked()
    }

    static func mark(_ stage:String,_ details:[String:String]=[:]) {
        markForRun(stage,details,runID:nil)
    }

    private static func markForRun(_ stage:String,_ details:[String:String],runID:String?) {
        lock.lock()
        defer {lock.unlock()}
        guard let run=active,runID==nil || run.id==runID else {return}
        currentEvents.append(Event(runID:run.id,operation:run.operation,stage:stage,date:Date(),
            elapsedSeconds:ProcessInfo.processInfo.systemUptime-run.started,
            rssBytes:Build133RAWMemoryLadder.resident(),
            physicalFootprintBytes:Build133RAWMemoryLadder.footprint(),
            availableBytes:Build133RAWMemoryLadder.available(),details:details))
        // Keep the entire current run under normal diagnostic workloads.
        // A separate bound prevents unexpected unlimited telemetry growth.
        if currentEvents.count>historyLimit {currentEvents.removeFirst(currentEvents.count-historyLimit)}
        _=try? writeLocked(activeCheckpoint:true)
    }

    #if canImport(UIKit)
    private static func keepScreenAwake(runID:String) {
        DispatchQueue.main.async {
            if screenOwner==nil {
                previousIdleTimerDisabled=UIApplication.shared.isIdleTimerDisabled
            }
            screenOwner=runID
            UIApplication.shared.isIdleTimerDisabled=true
            for token in lifecycleObservers {NotificationCenter.default.removeObserver(token)}
            lifecycleObservers=[]
            let notices:[(Notification.Name,String)]=[
                (UIApplication.willResignActiveNotification,"app_will_resign_active"),
                (UIApplication.didEnterBackgroundNotification,"app_entered_background"),
                (UIApplication.willEnterForegroundNotification,"app_will_enter_foreground"),
                (UIApplication.didBecomeActiveNotification,"app_became_active")]
            for (name,stage) in notices {
                lifecycleObservers.append(NotificationCenter.default.addObserver(
                    forName:name,object:nil,queue:.main) { _ in
                        markForRun(stage,["thermalState":String(ProcessInfo.processInfo.thermalState.rawValue)],
                                   runID:runID)
                    })
            }
            markForRun("idle_timer_disabled",["appState":String(UIApplication.shared.applicationState.rawValue),
                "previousIdleTimerDisabled":String(previousIdleTimerDisabled)],runID:runID)
        }
    }
    private static func restoreScreenIdleTimer(runID:String) {
        DispatchQueue.main.async {
            guard screenOwner==runID else {return}
            UIApplication.shared.isIdleTimerDisabled=previousIdleTimerDisabled
            for token in lifecycleObservers {NotificationCenter.default.removeObserver(token)}
            lifecycleObservers=[]
            screenOwner=nil
        }
    }
    #endif
    static func measure<T>(_ operation:String,queueWait:Double,_ body:() throws -> T) rethrows -> T {
        let runID=UUID().uuidString
        lock.lock()
        // Force lazy crash recovery before the first active checkpoint
        // overwrites a prior interrupted run.
        _=events.count
        currentEvents=[]
        active=Active(id:runID,operation:operation,started:ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        #if canImport(UIKit)
        // Editor RAW work is serialized. Main-thread UI access is async
        // to avoid waiting for main while holding the editor work lock.
        keepScreenAwake(runID:runID)
        #endif
        defer {
            lock.lock()
            events.append(contentsOf:currentEvents)
            currentEvents=[]
            // Drop whole oldest runs where possible, preserving complete
            // recent diagnostics and crash recovery.
            while events.count>historyLimit,let oldest=events.first?.runID {
                events.removeAll{$0.runID==oldest}
            }
            active=nil
            if (try? writeLocked()) != nil,
               let url=try? journalURL(activeCheckpoint:true) {
                try? FileManager.default.removeItem(at:url)
            }
            lock.unlock()
            #if canImport(UIKit)
            restoreScreenIdleTimer(runID:runID)
            #endif
        }
        let sampler=Build133RAWMemoryLadder.RSSSampler()
        sampler.start()
        mark("begin",["queueWaitSeconds":String(queueWait),
            "thermalState":String(ProcessInfo.processInfo.thermalState.rawValue)])
        func peakDetails()->[String:String] {
            let result=sampler.finish()
            return [
                "sampledPeakRSSBytes":result.peak.map{String($0)} ?? "not_measured",
                "sampledPeakPhysicalFootprintBytes":result.footprint.map{String($0)} ?? "not_measured",
                "sampledLowestHeadroomBytes":result.lowest.map{String($0)} ?? "not_measured",
                "sampleCount":String(result.count),
                "sampleIntervalMilliseconds":"25",
                "thermalState":String(ProcessInfo.processInfo.thermalState.rawValue),
                "nominalSampleCoverageSeconds":String(Double(result.count)*0.025)
            ]
        }
        do {
            let value=try body()
            mark("completed",peakDetails())
            return value
        } catch {
            var details=peakDetails()
            details["error"]=String(error.localizedDescription.prefix(500))
            mark(error is CancellationError ? "cancelled" : "failed",details)
            throw error
        }
    }
}
