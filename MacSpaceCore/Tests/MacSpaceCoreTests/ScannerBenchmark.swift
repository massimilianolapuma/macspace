import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

/// Footprint of the whole test process (runner included, not just the scanner), in bytes.
/// `peak` is the lifetime high-water mark (`ledger_phys_footprint_peak`); `current` is "now".
private func footprint() -> (current: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (info.phys_footprint, UInt64(max(info.ledger_phys_footprint_peak, 0)))
}

/// Opt-in: `MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan`.
/// Thresholds assume Full Disk Access; without it protected folders count as unreadable.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1"))
func startupDiskScan() async throws {
    let store = ScanStore(rootName: "Macintosh HD", rootPath: "/")
    let summary = await Scanner(rootPath: "/", boundary: try .forStartupDisk()).scan(into: store)
    let mem = footprint()
    let seconds = max(Double(summary.duration.components.seconds)
        + Double(summary.duration.components.attoseconds) / 1e18, 0.001)
    let rootSize = await store.rootSize()
    let values = try URL(fileURLWithPath: "/").resourceValues(
        forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
    let total = try #require(values.volumeTotalCapacity)
    let available = try #require(values.volumeAvailableCapacity)
    let used = UInt64(max(total - available, 0))
    let mb = { (b: UInt64) in b / 1_000_000 }
    print("""
    BENCH files=\(summary.files) dirs=\(summary.directories) unreadable=\(summary.unreadable) \
    duration=\(String(format: "%.2f", seconds))s files/s=\(Int(Double(summary.files) / seconds)) \
    footprintPeak=\(mb(mem.peak))MB footprintCurrent=\(mb(mem.current))MB \
    rootSize=\(mb(rootSize))MB usedSpace=\(mb(used))MB
    """)
    #expect(!summary.wasCancelled)
    #expect(summary.duration < .seconds(90))
    #expect(mem.peak < 1_000_000_000)
    // Not a strict bound: APFS clones report full size each while sharing storage.
    #expect(rootSize <= used + used / 10,
            "scan total far above used space: firmlink double counting, or APFS clones/compression")
}
