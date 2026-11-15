import Foundation

/// Small, explicitly keyed source LUT preparation cache. It owns ONLY
/// non-production-preview LUT entries. Full optical Float64 processing
/// never calls this API or silently uses a previously cached table.
final class Build90OriginalLUTCache {
    static let shared=Build90OriginalLUTCache()

    private struct Entry {
        let table:Build90OriginalLUT.Prepared
        let bytes:Int
    }
    private let lock=NSLock()
    private var entries=[Entry]()
    private let maxResidentBytes=48*1024*1024

    /// The source fast pipeline may reuse a LUT ONLY if every source
    /// value, per-channel input bound and revision is identical.
    /// Equality compares actual Double samples, not a hash collision.
    func prepare(
        size:Int,samples:[Double],revision:String,
        minimum:[Double]=[0,0,0],
        maximum:[Double]=[1,1,1]
    )throws->Build90OriginalLUT.Prepared {
        guard size>=1,size<=129,size<=Int.max/size/size/3,
              samples.count==size*size*size*3 else {
            throw Build90OriginalLUT.Failure.invalid(
                "源 LUT 样本尺寸错误，不得缓存旧胶片曲线"
            )
        }
        let n=size
        let n3=n*n*n*3
        let cell=max(0,n-1)
        let cell3=cell*cell*cell*3
        let projected=(n3*4+cell3*2)*8
        guard projected<=maxResidentBytes else {
            throw Build90OriginalLUT.Failure.invalid(
                "源 LUT 计算缓存需 \(projected) bytes，" +
                "超出 48MiB；不会静默降低网格精度"
            )
        }
        lock.lock()
        if let index=entries.firstIndex(where:{
            let t=$0.table
            return t.n==size && t.revision==revision &&
                t.minDomain==minimum && t.maxDomain==maximum &&
                t.values==samples
        }) {
            let entry=entries.remove(at:index)
            entries.append(entry)
            lock.unlock()
            return entry.table
        }
        lock.unlock()

        let prepared=try Build90OriginalLUT.Prepared(
            size:size,values:samples,revision:revision,
            minimum:minimum,maximum:maximum
        )
        lock.lock()
        // A concurrent caller may have built the same revision.
        if let index=entries.firstIndex(where:{
            let t=$0.table
            return t.n==size && t.revision==revision &&
                t.minDomain==minimum && t.maxDomain==maximum &&
                t.values==samples
        }) {
            let existing=entries.remove(at:index)
            entries.append(existing)
            lock.unlock()
            return existing.table
        }
        var resident=entries.reduce(0){$0+$1.bytes}
        while !entries.isEmpty && resident+projected>maxResidentBytes {
            resident-=entries.removeFirst().bytes
        }
        entries.append(Entry(table:prepared,bytes:projected))
        lock.unlock()
        return prepared
    }
    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
    func residentCount()->Int {
        lock.lock()
        defer{lock.unlock()}
        return entries.count
    }
}
