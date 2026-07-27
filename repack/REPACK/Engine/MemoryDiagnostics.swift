#if DEBUG
import Darwin
import Foundation
import Metal

nonisolated enum MemoryDiagnostics {
    static func log(_ label: String) {
        let info = taskMemoryInfo()
        let available = UInt64(os_proc_available_memory())
        let estimatedLimit = info.map { $0.phys_footprint + available }
        let metalAllocated = MTLCreateSystemDefaultDevice().map { UInt64($0.currentAllocatedSize) }

        print(
            """
            [REPACK][Memory] \(label)
              Physical footprint: \(format(info?.phys_footprint))
              Peak footprint: \(format(info?.ledger_phys_footprint_peak))
              Available to process: \(format(available))
              Estimated process limit: \(format(estimatedLimit))
              Graphics footprint: \(format(info?.ledger_tag_graphics_footprint))
              Metal allocated: \(format(metalAllocated))
            """
        )
    }

    private static func taskMemoryInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }

        return result == KERN_SUCCESS ? info : nil
    }

    private static func format<T: BinaryInteger>(_ bytes: T?) -> String {
        guard let bytes, bytes >= 0 else { return "unavailable" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }
}
#else
nonisolated enum MemoryDiagnostics {
    static func log(_ label: String) {}
}
#endif
