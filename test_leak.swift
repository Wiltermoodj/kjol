import Foundation

var numCPUs: natural_t = 0
var cpuInfo: processor_info_array_t?
var numCpuInfo: mach_msg_type_number_t = 0
let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                             &numCPUs, &cpuInfo, &numCpuInfo)

if kr == KERN_SUCCESS, let info = cpuInfo {
    print("numCPUs: \(numCPUs), numCpuInfo: \(numCpuInfo)")
    print("MemoryLayout<integer_t>.size: \(MemoryLayout<integer_t>.size)")
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCpuInfo * UInt32(MemoryLayout<integer_t>.size)))
}
