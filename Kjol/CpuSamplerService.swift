import Foundation
import CoreFoundation

struct CpuState: Equatable {
    var perCore: [Double] = []
    var pCoreCount: Int = 0
    var eCoreCount: Int = 0
    var pCoreUsage: Double = 0
    var eCoreUsage: Double = 0
    var overallUsage: Double = 0
    var hasSample = false
}

final class CpuSamplerService {
    private var prevTotal: [UInt32]
    private var prevBusy: [UInt32]
    private var currTotal: [UInt32]
    private var currBusy: [UInt32]
    private let cachedPCoreCount: Int
    private let cachedECoreCount: Int
    private let totalCoreCount: Int

    init() {
        var pCount: Int = 0
        var eCount: Int = 0
        var sz = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel0.logicalcpu", &pCount, &sz, nil, 0)
        sz = MemoryLayout<Int>.size
        sysctlbyname("hw.perflevel1.logicalcpu", &eCount, &sz, nil, 0)
        cachedPCoreCount = pCount
        cachedECoreCount = eCount
        totalCoreCount = max(1, pCount + eCount)

        prevTotal = [UInt32]()
        prevBusy = [UInt32]()
        currTotal = [UInt32]()
        currBusy = [UInt32]()

        prevTotal.reserveCapacity(totalCoreCount)
        prevBusy.reserveCapacity(totalCoreCount)
        currTotal.reserveCapacity(totalCoreCount)
        currBusy.reserveCapacity(totalCoreCount)
    }

    func sample() -> CpuState {
        var state = CpuState()
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUs, &cpuInfo, &numCpuInfo)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return state }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.size))
        }

        let count = Int(numCPUs)
        let loads = UnsafeBufferPointer<processor_cpu_load_info>(
            start: UnsafeRawPointer(info).assumingMemoryBound(to: processor_cpu_load_info.self),
            count: count)

        currTotal.removeAll(keepingCapacity: true)
        currBusy.removeAll(keepingCapacity: true)

        for i in 0..<count {
            let t = loads[i].cpu_ticks
            let u = t.0
            let s = t.1
            let idle = t.2
            let n = t.3
            currTotal.append(u &+ s &+ idle &+ n)
            currBusy.append(u &+ s &+ n)
        }

        if prevTotal.count == count {
            state.perCore.reserveCapacity(count)
            for i in 0..<count {
                let dTot = max(1, Double(currTotal[i] &- prevTotal[i]))
                let dBsy = max(0, Double(currBusy[i] &- prevBusy[i]))
                state.perCore.append(dBsy / dTot)
            }
            state.hasSample = true

            if cachedPCoreCount > 0, state.perCore.count >= cachedPCoreCount {
                let pUsages = state.perCore.prefix(cachedPCoreCount)
                state.pCoreUsage = pUsages.reduce(0, +) / Double(pUsages.count)

                let eUsages = state.perCore.dropFirst(cachedPCoreCount)
                if !eUsages.isEmpty {
                    state.eCoreUsage = eUsages.reduce(0, +) / Double(eUsages.count)
                }
            } else if !state.perCore.isEmpty {
                state.pCoreUsage = state.perCore.reduce(0, +) / Double(state.perCore.count)
            }
            if !state.perCore.isEmpty {
                state.overallUsage = state.perCore.reduce(0, +) / Double(state.perCore.count)
            }
        }
        swap(&prevTotal, &currTotal)
        swap(&prevBusy, &currBusy)

        state.pCoreCount = cachedPCoreCount
        state.eCoreCount = cachedECoreCount
        return state
    }
}
