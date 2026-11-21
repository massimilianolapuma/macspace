import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

/// Current process physical footprint in bytes (what Activity Monitor reports).
private func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Opt-in: `MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan`.
/// Thresholds assume Full Disk Access; without it protected folders count as unreadable.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1"))
func startupDiskScan() async throws {
    let store = ScanStore(rootName: "Macintosh HD", rootPath: "/")
    let summary = await Scanner(rootPath: "/", boundary: try .forStartupDisk()).scan(into: store)
    let footprint = physFootprint()
    let seconds = Double(summary.duration.components.seconds)
        + Double(summary.duration.components.attoseconds) / 1e18
    let rootSize = await store.rootSize()
    let values = try URL(fileURLWithPath: "/").resourceValues(
        forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
    let used = UInt64((values.volumeTotalCapacity ?? 0) - (values.volumeAvailableCapacity ?? 0))
    print("""
    BENCH files=\(summary.files) dirs=\(summary.directories) unreadable=\(summary.unreadable) \
    duration=\(String(format: "%.2f", seconds))s files/s=\(Int(Double(summary.files) / seconds)) \
    footprint=\(footprint / 1_048_576)MB rootSize=\(rootSize) usedSpace=\(used)
    """)
    #expect(!summary.wasCancelled)
    #expect(summary.duration < .seconds(90))
    #expect(footprint < 1_000_000_000)
    #expect(rootSize <= used, "scan total above used space implies double counting")
}
