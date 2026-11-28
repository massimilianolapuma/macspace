import AppKit
import Darwin
import Foundation
import Synchronization
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

/// Every benchmark gated by `MACSPACE_BENCH`, in one serialized suite (here, in `DrillBenchmark.swift`
/// and in `AppsIndexTests.swift`), so no two can run at once (two full-disk scans, or a scan beside a
/// timing gate) and skew each other's timings, whatever the flags (`--no-parallel` or not).
@Suite(.serialized) struct Benchmarks {}

extension Benchmarks {
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
}

extension Benchmarks {
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
}

/// The highest footprint seen while `body` runs, sampled every 10 ms (the lifetime peak cannot be
/// reset between phases).
private func sampledPeak<T>(_ body: () async throws -> T) async rethrows -> (T, UInt64) {
    let highest = Mutex<UInt64>(footprint().current)
    let running = Atomic<Bool>(true)
    let sampler = Thread {
        while running.load(ordering: .relaxed) {
            let now = footprint().current
            highest.withLock { $0 = max($0, now) }
            usleep(10_000)
        }
    }
    sampler.start()
    let value = try await body()
    running.store(false, ordering: .relaxed)
    let now = footprint().current
    return (value, highest.withLock { max($0, now) })
}

/// Where the snapshot benchmarks keep the startup disk's snapshot between their two processes.
private var benchSnapshots: SnapshotFolder? {
    ProcessInfo.processInfo.environment["MACSPACE_SNAPSHOTS"].map { SnapshotFolder(url: URL(filePath: $0)) }
}

private func seconds(_ d: Duration) -> String {
    String(format: "%.2fs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

extension Benchmarks {
    /// Opt-in, the first of two processes (#33):
    /// `MACSPACE_BENCH=1 MACSPACE_SNAPSHOTS=<dir> swift test -c release --filter snapshotSaveOfStartupDisk`.
    /// Scans the startup disk and saves it, as a scan's end does (the scanned store still alive).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1" && benchSnapshots != nil))
    func snapshotSaveOfStartupDisk() async throws {
        let folder = try #require(benchSnapshots)
        let store = ScanStore(rootName: "Macintosh HD", rootPath: "/")
        let startedAt = UInt32(time(nil))
        let (files, scanPeak) = await sampledPeak {
            await Scanner(rootPath: "/", boundary: try! .forStartupDisk()).scan(into: store).files
        }
        let clock = ContinuousClock(), t = clock.now
        let ((), savePeak) = try await sampledPeak {
            let saved = await store.savedScan(target: .startupDisk, startedAt: startedAt, hadFullDiskAccess: true)
            try folder.save(saved)
        }
        let saveTime = clock.now - t
        let size = try FileManager.default.attributesOfItem(
            atPath: folder.url.appendingPathComponent("startup-disk.snapshot").path)[.size] as? UInt64 ?? 0
        print("""
        BENCH save files=\(files) fileSize=\(size / 1_000_000)MB save=\(seconds(saveTime)) \
        scanPeak=\(scanPeak / 1_000_000)MB savePeak=\(savePeak / 1_000_000)MB \
        savePeakBytesPerFile=\(savePeak / UInt64(max(files, 1)))
        """)
    }

    /// Opt-in, the second process, after `snapshotSaveOfStartupDisk`:
    /// `MACSPACE_BENCH=1 MACSPACE_SNAPSHOTS=<dir> swift test -c release --filter snapshotLaunchOfStartupDisk`.
    /// What a launch does: read and decode the file, restore the store, lay out the first chart;
    /// then refresh through the real history while the restored store stays shown.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1" && benchSnapshots != nil))
    func snapshotLaunchOfStartupDisk() async throws {
        let folder = try #require(benchSnapshots)
        let clock = ContinuousClock()
        let before = footprint().current
        var t = clock.now
        let (shown, launchPeak) = try await sampledPeak { () async throws -> (SavedScan, ScanStore) in
            let loaded = try #require(folder.load(.startupDisk))
            let restored = ScanStore(saved: loaded)
            _ = await restored.snapshot(center: FileTree.root, chart: .sunburst(depth: 3), biggestLimit: 20)
            return (loaded, restored)
        }
        let launchTime = clock.now - t
        let (loaded, restored) = shown
        t = clock.now
        let plan = loaded.refreshPlan(now: UInt32(time(nil)), rootInode: loaded.rootInode, hasFullDiskAccess: true,
                                      history: SystemChangeHistory(timeout: .seconds(30)))
        let planTime = clock.now - t
        guard case let .incremental(changed) = plan else {
            Issue.record("no incremental refresh: \(plan)")
            return
        }
        let read = Mutex(0)
        let reader = loaded.listingReader(changed: changed, disk: { request throws(DirectoryReadError) in
            read.withLock { $0 += 1 }
            return try DirectoryReader.read(path: request.path)
        })
        let refreshed = ScanStore(rootName: "Macintosh HD", rootPath: "/")
        t = clock.now
        let (files, refreshPeak) = await sampledPeak {
            await Scanner(rootPath: "/", boundary: try! .forStartupDisk(), listing: reader).scan(into: refreshed).files
        }
        let refreshTime = clock.now - t
        _ = await restored.rootSize()   // the restored store stays alive (shown) through the refresh
        print("""
        BENCH launch files=\(files) start=\(before / 1_000_000)MB launch=\(seconds(launchTime)) \
        launchPeak=\(launchPeak / 1_000_000)MB
        BENCH refresh plan=\(seconds(planTime)) changedFolders=\(changed.count) readFromDisk=\(read.withLock { $0 }) \
        refresh=\(seconds(refreshTime)) refreshPeak=\(refreshPeak / 1_000_000)MB \
        refreshPeakBytesPerFile=\(refreshPeak / UInt64(max(files, 1)))
        """)
        #expect(launchTime < .seconds(1))
    }
}
