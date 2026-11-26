import Foundation

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
    private static let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"
    private static let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown"
    private static let commit=Bundle.main.object(forInfoDictionaryKey:"SFSourceCommit") as? String ?? "missing"
    private static var events:[Event]={
        guard let url=try? journalURL(),let data=try? Data(contentsOf:url),
              let old=try? JSONDecoder().decode(Report.self,from:data),
              old.sourceCommit==commit,old.build==build else {return []}
        return Array(old.events.suffix(160))
    }()
    private static func journalURL() throws -> URL {
        guard let docs=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder=docs.appendingPathComponent("SpektraFilm Verification",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        return folder.appendingPathComponent("OPT-Device-Performance-last.json")
    }
    private static func writeLocked() throws -> URL {
        let report=Report(schema:1,version:version,build:build,sourceCommit:commit,
            os:ProcessInfo.processInfo.operatingSystemVersionString,events:events)
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let url=try journalURL()
        try encoder.encode(report).write(to:url,options:.atomic)
        return url
    }
    static func export() throws -> URL {
        lock.lock()
        defer {lock.unlock()}
        return try writeLocked()
    }
    static func mark(_ stage:String,_ details:[String:String]=[:]) {
        lock.lock()
        defer {lock.unlock()}
        guard let run=active else {return}
        events.append(Event(runID:run.id,operation:run.operation,stage:stage,date:Date(),
            elapsedSeconds:ProcessInfo.processInfo.systemUptime-run.started,
            rssBytes:Build133RAWMemoryLadder.resident(),
            physicalFootprintBytes:Build133RAWMemoryLadder.footprint(),
            availableBytes:Build133RAWMemoryLadder.available(),details:details))
        if events.count>160 {events.removeFirst(events.count-160)}
        // Fail open only for telemetry; never affect rendering or numerical gates.
        // Export retries a failed write. Each successful phase is a crash checkpoint.
        _=try? writeLocked()
    }
    static func measure<T>(_ operation:String,queueWait:Double,_ body:() throws -> T) rethrows -> T {
        lock.lock()
        active=Active(id:UUID().uuidString,operation:operation,started:ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        defer {lock.lock();active=nil;lock.unlock()}
        mark("begin",["queueWaitSeconds":String(queueWait)])
        do {
            let value=try body()
            mark("completed")
            return value
        } catch {
            mark(error is CancellationError ? "cancelled" : "failed",
                 ["error":String(error.localizedDescription.prefix(500))])
            throw error
        }
    }
}
