import AppKit
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
/// Memory is gated per file, as the spec states it: "well under 1 GB for 3 M files", i.e. a peak
/// of at most 1 GB / 3 M ≈ 333 bytes per file, whatever the disk's file count.
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
    let peakBytesPerFile = mem.peak / UInt64(max(summary.files, 1))
    let maxBytesPerFile: UInt64 = 1_000_000_000 / 3_000_000
    print("""
    BENCH files=\(summary.files) dirs=\(summary.directories) unreadable=\(summary.unreadable) \
    duration=\(String(format: "%.2f", seconds))s files/s=\(Int(Double(summary.files) / seconds)) \
    footprintPeak=\(mb(mem.peak))MB footprintCurrent=\(mb(mem.current))MB \
    peakBytesPerFile=\(peakBytesPerFile) (max \(maxBytesPerFile)) \
    rootSize=\(mb(rootSize))MB usedSpace=\(mb(used))MB
    """)
    let totals = await store.categoryTotals(of: FileTree.root)
    print("BENCH categories " + FileCategory.allCases.filter { totals[$0] != nil }
        .map { "\($0)=\(mb(totals[$0] ?? 0))MB" }.joined(separator: " "))
    #expect(!summary.wasCancelled)
    #expect(summary.duration < .seconds(90))
    #expect(peakBytesPerFile <= maxBytesPerFile)
    // Not a strict bound: APFS clones report full size each while sharing storage.
    #expect(rootSize <= used + used / 10,
            "scan total far above used space: firmlink double counting, or APFS clones/compression")
}

/// Opt-in: `MACSPACE_BENCH=1 swift test -c release --filter librarySnapshotWithVerdicts`.
/// A treemap snapshot of `~/Library` (the app's canvas and depth) with verdicts, the real apps
/// index (with Spotlight) and the apps running now: the first (cold cache) and the median of warm
/// repeats, which must stay under 20 ms.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1"))
func librarySnapshotWithVerdicts() async throws {
    let home = NSHomeDirectory(), library = home + "/Library"
    let store = ScanStore(rootName: "Library", rootPath: library, home: home)
    let summary = await Scanner(rootPath: library, boundary: try .forFolder(library)).scan(into: store)
    let apps = AppsIndex.build(extraAppPaths: AppsIndex.spotlightAppPaths())
    // The apps running now, as the app reads them (every unmatched identifier is checked against them).
    let running = NSWorkspace.shared.runningApplications
    await store.setEnvironment(.system(
        home: home, apps: apps, runningBundleIDs: Set(running.compactMap(\.bundleIdentifier)),
        runningAppPaths: Set(running.compactMap { $0.bundleURL?.path(percentEncoded: false) })))
    let chart = ChartRequest.treemap(width: 1100, height: 700, depth: 3)
    let clock = ContinuousClock()
    let ms = { (d: Duration) in Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }
    let coldStart = clock.now
    let snapshot = await store.snapshot(center: FileTree.root, chart: chart, biggestLimit: 20)
    let cold = clock.now - coldStart
    var warm: [Double] = []
    for _ in 0..<15 {
        let start = clock.now
        _ = await store.snapshot(center: FileTree.root, chart: chart, biggestLimit: 20)
        warm.append(ms(clock.now - start))
    }
    warm.sort()
    // Suggestions judge every node of the tree (cold: the snapshot's verdicts dropped first).
    await store.invalidateVerdicts()
    let suggestionsStart = clock.now
    let suggestions = await store.suggestions()
    let suggestionsTime = clock.now - suggestionsStart
    let median = warm[warm.count / 2]
    let levels = SafetyLevel.allCases.map { level in "\(level)=\(snapshot.tiles.filter { $0.safety == level }.count)" }
    print("""
    BENCH library files=\(summary.files) tiles=\(snapshot.tiles.count) verdicts=\(snapshot.verdicts.count) \
    apps=\(apps.count) running=\(running.count) cold=\(String(format: "%.2f", ms(cold)))ms \
    warmMedian=\(String(format: "%.2f", median))ms warmMax=\(String(format: "%.2f", warm.last ?? 0))ms \
    suggestions=\(suggestions.count) suggestionsCold=\(String(format: "%.1f", ms(suggestionsTime)))ms \
    tiles \(levels.joined(separator: " "))
    """)
    #expect(median < 20)
}
