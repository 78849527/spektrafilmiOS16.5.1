import Foundation
#if os(iOS)
import os
#endif

/// Optional on-device appendix. Six sizes are DRY-RUN only; no giant
/// 12/13MP image is allocated as a diagnostic side effect.
/// Reports the CURRENT physical/process budget and one normal FFT
/// versus full-source grain/halation/glare settings, fail-closed.
enum Build91MemoryProductionDiagnostic {
    static func evaluate() throws->String {
        let physical=ProcessInfo.processInfo.physicalMemory
        let free:UInt64?
        #if os(iOS)
        free=UInt64(os_proc_available_memory())
        #else
        free=nil
        #endif
        let sizes=[
            (1000,1000),(1600,1250),(2000,2000),
            (3000,2400),(4000,3000),(5000,2600)
        ]
        var accepted=0,rejected=0,summary=[String]()
        for (w,h) in sizes {
            let plan=try Build91PhysicalMemory.plan(
                width:w,height:h,physicalMemory:physical,
                processAvailable:free
            )
            let outcome:String
            do {
                try Build91PhysicalMemory.validate(plan)
                accepted+=1
                outcome="安全预算允许"
            } catch Build91PhysicalMemory.Failure.invalid(_) {
                rejected+=1
                outcome="安全预算拒绝"
            }
            summary.append(
                "\(Double(w*h)/1_000_000) MP " +
                "\(String(format:"%.0f",plan.peakMB)) MB \(outcome)"
            )
        }
        guard accepted+rejected==6 else {
            throw Build91PhysicalMemory.Failure.invalid(
                "内存矩阵包含未验证尺寸"
            )
        }
        let metal=OriginalMetalIIR.cachedPipelineStats()
        return "Build91 原版内存与 GPU 缓存诊断：" +
            "设备物理内存 \(physical/1_000_000) MB，" +
            "当前可分配 \(free.map{String($0/1_000_000)} ?? "未获取") MB；" +
            "6 档预检 \(accepted) 档允许／\(rejected) 档拒绝。" +
            summary.joined(separator:"；") +
            "。Metal YVV 原地缓存已编译 \(metal.compilations)，" +
            "复用命中 \(metal.hits)。" +
            "【注意】这些是无大图分配的内存预算与缓存计数，" +
            "不是实际 iOS 13MP/FFT RSS 峰值，" +
            "不计入现有 8/8 GPU 数值认证。"
    }
}
