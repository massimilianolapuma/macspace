// Opt-in drill benchmarks (issue #12): what a click into a folder costs on the store actor after a
// full startup-disk scan, per part (layouts, verdicts, rows, breadcrumb, totals) and as the whole
// public `snapshot`, cold (verdicts dropped) and warm. Timings are taken inside the actor, so no
// hop cost is mixed in. Thresholds assume Full Disk Access, as `ScannerBenchmark` does.
import AppKit
import Foundation
import Testing
@testable import MacSpaceCore

private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15 }

/// Timings taken inside the actor, so no hop cost is mixed in.
struct DrillTimes: Sendable {
    var sunLayout = 0.0, sunJudge = 0.0, treeLayout = 0.0, treeJudge = 0.0
    var rows = 0.0, crumbs = 0.0, cat = 0.0, age = 0.0, snapJudge = 0.0
    var segs = 0, tiles = 0, verdictCount = 0
}

extension ScanStore {
    func benchParts(center: NodeID) -> DrillTimes {
        let clock = ContinuousClock()
        var t = DrillTimes()
        var s0 = clock.now
        var segments = SunburstLayout.compute(tree: tree, center: center, depth: 3)
        t.sunLayout = ms(clock.now - s0); t.segs = segments.count
        s0 = clock.now
        for i in segments.indices { if let n = segments[i].node { segments[i].safety = judged(n).level } }
        t.sunJudge = ms(clock.now - s0)
        s0 = clock.now
        var tiles = TreemapLayout.compute(tree: tree, center: center, width: 1100, height: 720, depth: 3)
        t.treeLayout = ms(clock.now - s0); t.tiles = tiles.count
        s0 = clock.now
        for i in tiles.indices { if let n = tiles[i].node { tiles[i].safety = judged(n).level } }
        t.treeJudge = ms(clock.now - s0)
        s0 = clock.now
        let biggest = rows(childrenOf: center, limit: 20)
        t.rows = ms(clock.now - s0)
        s0 = clock.now
        let crumbList = breadcrumb(to: center)
        t.crumbs = ms(clock.now - s0)
        s0 = clock.now
        _ = categoryTotals(of: center); t.cat = ms(clock.now - s0)
        s0 = clock.now
        _ = ageTotals(of: center); t.age = ms(clock.now - s0)
        s0 = clock.now
        var v: [NodeID: SafetyVerdict] = [:]
        for id in segments.compactMap(\.node) + tiles.compactMap(\.node) + (biggest + crumbList).map(\.id) { v[id] = judged(id) }
        t.snapJudge = ms(clock.now - s0); t.verdictCount = v.count
        return t
    }
    func evalCount() -> Int { verdictEvaluations }

    /// Children count and sort time of every directory the sunburst expands, worst first.
    func benchExpanded(center: NodeID) -> [String] {
        let clock = ContinuousClock()
        let segments = SunburstLayout.compute(tree: tree, center: center, depth: 3)
        var ids = [center] + segments.filter { $0.depth < 3 }.compactMap(\.node)
        ids = ids.filter { tree.kind($0) == .directory }
        var out: [(Double, String)] = []
        for id in ids {
            var n = 0
            tree.forEachChild(of: id) { _ in n += 1 }
            let s = clock.now
            _ = tree.children(of: id)
            let t = ms(clock.now - s)
            out.append((t, "\(tree.path(of: id)) children=\(n) sort=\(String(format: "%.2f", t))ms"))
        }
        return out.sorted { $0.0 > $1.0 }.prefix(5).map(\.1)
    }
}

/// Opt-in: `MACSPACE_BENCH=1 swift test -c release --filter drillHomeExpanded`. The five folders
/// home's sunburst expands whose full child sort (`children(of:)`) costs most.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1"))
func drillHomeExpanded() async throws {
    let home = NSHomeDirectory()
    let store = ScanStore(rootName: "Macintosh HD", rootPath: "/", home: home)
    _ = await Scanner(rootPath: "/", boundary: try .forStartupDisk()).scan(into: store)
    let id = try #require(await store.node(atPath: home))
    for line in await store.benchExpanded(center: id) { print("DRILL expanded \(line)") }
}

/// Opt-in: `MACSPACE_BENCH=1 swift test -c release --filter drillSnapshotBench`. A warm sunburst
/// snapshot (the median of repeats) must stay under 20 ms for every center.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1"))
func drillSnapshotBench() async throws {
    let home = NSHomeDirectory()
    let store = ScanStore(rootName: "Macintosh HD", rootPath: "/", home: home)
    let summary = await Scanner(rootPath: "/", boundary: try .forStartupDisk()).scan(into: store)
    let scanSeconds = Double(summary.duration.components.seconds)
        + Double(summary.duration.components.attoseconds) / 1e18
    print("""
    DRILL scan files=\(summary.files) dirs=\(summary.directories) unreadable=\(summary.unreadable) \
    duration=\(String(format: "%.2f", scanSeconds))s
    """)
    let clock = ContinuousClock()
    let t0 = clock.now
    let apps = AppsIndex.build(extraAppPaths: AppsIndex.spotlightAppPaths())
    print("DRILL appsIndex build=\(String(format: "%.0f", ms(clock.now - t0)))ms apps=\(apps.count)")
    let running = NSWorkspace.shared.runningApplications
    await store.setEnvironment(.system(
        home: home, apps: apps, runningBundleIDs: Set(running.compactMap(\.bundleIdentifier)),
        runningAppPaths: Set(running.compactMap { $0.bundleURL?.path(percentEncoded: false) })))

    // Post-scan work, as ScanModel.run does it.
    var s = clock.now
    await store.invalidateVerdicts()
    print("DRILL post invalidateVerdicts=\(String(format: "%.3f", ms(clock.now - s)))ms")
    let treeChart = ChartRequest.treemap(width: 1100, height: 720, depth: 3)
    s = clock.now
    _ = await store.snapshot(center: FileTree.root, chart: treeChart, biggestLimit: 20)
    print("DRILL post refreshViews(root treemap, cold)=\(String(format: "%.2f", ms(clock.now - s)))ms")
    s = clock.now
    let sug = await store.suggestions()
    let sugAfterRefresh = ms(clock.now - s)
    s = clock.now
    _ = await store.suggestions()
    let sugWarm = ms(clock.now - s)
    await store.invalidateVerdicts()
    s = clock.now
    _ = await store.suggestions()
    let sugColdFresh = ms(clock.now - s)
    print("DRILL post suggestions groups=\(sug.count) items=\(sug.flatMap(\.items).count) afterRefresh=\(String(format: "%.1f", sugAfterRefresh))ms warm=\(String(format: "%.1f", sugWarm))ms fullyCold=\(String(format: "%.1f", sugColdFresh))ms")

    var paths: [(String, String)] = [("root", "/"), ("/Users", "/Users"), ("home", home),
        ("~/Library", home + "/Library"), ("/Library", "/Library"), ("/Applications", "/Applications"),
        ("/System", "/System"), ("/private", "/private"), ("/opt", "/opt")]
    let homeID = try #require(await store.node(atPath: home))
    for r in await store.rows(childrenOf: homeID, limit: 4) {
        if let p = await store.path(of: r.id) { paths.append(("home/" + r.name, p)) }
    }
    func f(_ x: Double) -> String { String(format: "%.2f", x) }
    for (label, path) in paths {
        guard let id = await store.node(atPath: path) else { print("DRILL \(label) missing"); continue }
        await store.invalidateVerdicts()
        let evBefore = await store.evalCount()
        let cold = await store.benchParts(center: id)
        let evCold = await store.evalCount() - evBefore
        let warm = await store.benchParts(center: id)
        await store.invalidateVerdicts()
        var s1 = clock.now
        _ = await store.snapshot(center: id, chart: .sunburst(depth: 3), biggestLimit: 20)
        let snapSunCold = ms(clock.now - s1)
        var sunWarm: [Double] = []
        for _ in 0..<7 {
            s1 = clock.now
            _ = await store.snapshot(center: id, chart: .sunburst(depth: 3), biggestLimit: 20)
            sunWarm.append(ms(clock.now - s1))
        }
        sunWarm.sort()
        let snapSunWarm = sunWarm[sunWarm.count / 2]
        await store.invalidateVerdicts()
        s1 = clock.now
        _ = await store.snapshot(center: id, chart: treeChart, biggestLimit: 20)
        let snapTreeCold = ms(clock.now - s1)
        s1 = clock.now
        _ = await store.snapshot(center: id, chart: treeChart, biggestLimit: 20)
        let snapTreeWarm = ms(clock.now - s1)
        print("""
        DRILL \(label) segs=\(cold.segs) tiles=\(cold.tiles) verdicts=\(cold.verdictCount) evalsCold=\(evCold) \
        | cold: sunLayout=\(f(cold.sunLayout)) sunJudge=\(f(cold.sunJudge)) treeLayout=\(f(cold.treeLayout)) \
        treeJudge=\(f(cold.treeJudge)) rows=\(f(cold.rows)) crumbs=\(f(cold.crumbs)) cat=\(f(cold.cat)) age=\(f(cold.age)) \
        | warm: sunLayout=\(f(warm.sunLayout)) sunJudge=\(f(warm.sunJudge)) treeLayout=\(f(warm.treeLayout)) \
        treeJudge=\(f(warm.treeJudge)) rows=\(f(warm.rows)) cat=\(f(warm.cat)) age=\(f(warm.age)) \
        | snapshot sunburst cold=\(f(snapSunCold)) warmMedian=\(f(snapSunWarm)) treemap cold=\(f(snapTreeCold)) \
        warm=\(f(snapTreeWarm)) (ms)
        """)
        #expect(snapSunWarm < 20, "\(label): warm sunburst snapshot \(f(snapSunWarm)) ms")
    }
}
