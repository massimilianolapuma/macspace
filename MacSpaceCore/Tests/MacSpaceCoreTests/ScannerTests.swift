import Darwin
import Foundation
import Testing
import Synchronization
@testable import MacSpaceCore

func scanFixture(_ fx: Fixture) async throws -> (ScanStore, ScanSummary) {
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path)
    let s = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    return (store, s)
}
@Test func totalsMatchFixture() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let a = try fx.file("d1/a", bytes: 10_000), b = try fx.file("d1/d2/b", bytes: 50_000)
    let alloc = { (u: URL) throws -> UInt64 in
        let size = try #require(try u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
        return UInt64(size)
    }
    let (store, s) = try await scanFixture(fx)
    #expect(s.files == 2 && s.directories >= 2 && !s.wasCancelled)
    #expect(await store.rootSize() == (try alloc(a)) + (try alloc(b)))
}
@Test func hardLinkCountedOnce() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("x/big", bytes: 200_000); try fx.hardLink("y/big", to: f)
    let (store, _) = try await scanFixture(fx)
    #expect(await store.rootSize() < 2 * 200_000)
    var links: [NodeRow] = []
    for dir in await store.rows(childrenOf: FileTree.root, limit: 10) {
        links += await store.rows(childrenOf: dir.id, limit: 10).filter { $0.name == "big" }
    }
    try #require(links.count == 2)
    let counted = links.filter { $0.size > 0 }, duplicates = links.filter { $0.size == 0 }
    #expect(counted.count == 1 && !counted[0].flags.contains(.hardLinkDuplicate))
    #expect(duplicates.count == 1 && duplicates[0].flags.contains(.hardLinkDuplicate))
}
@Test func insertJoinsRootPathAndAppliesBoundary() async throws {
    func dir(_ name: String, mountPoint: Bool = false) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .directory, allocatedSize: 0, device: 1, inode: 0,
                       linkCount: 1, isMountPoint: mountPoint, isDataless: false)
    }
    let boundary = ScanBoundary(allowedDevices: [1], excludedPaths: ["/System/Volumes/Data"])
    let store = ScanStore(rootName: "Macintosh HD", rootPath: "/")
    let top = await store.insert([dir("System"), dir("Users")], under: FileTree.root,
                                 parentPath: "/", boundary: boundary).descend
    #expect(Set(top.map(\.path)) == ["/System", "/Users"])
    for child in top { #expect(await store.path(of: child.id) == child.path) }
    let system = try #require(top.first { $0.path == "/System" })
    let volumes = await store.insert([dir("Volumes")], under: system.id,
                                     parentPath: "/System", boundary: boundary).descend
    #expect(volumes.map(\.path) == ["/System/Volumes"])
    let data = await store.insert([dir("Data", mountPoint: true)], under: volumes[0].id,
                                  parentPath: "/System/Volumes", boundary: boundary).descend
    #expect(data.isEmpty)
}
@Test func rootIsReadEvenWhenTheBoundaryWouldRejectIt() async throws {
    // The root may itself be a mount point (e.g. a chosen /Volumes/USB): only children are gated.
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("f", bytes: 4096); try fx.file("d/g", bytes: 4096)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path)
    let rejectAll = ScanBoundary(allowedDevices: [], excludedPaths: [fx.root.path])
    let s = await Scanner(rootPath: fx.root.path, boundary: rejectAll).scan(into: store)
    #expect(s.files == 1 && s.directories == 1 && s.unreadable == 0)
    let d = try #require(await store.rows(childrenOf: FileTree.root, limit: 10).first { $0.name == "d" })
    #expect(!d.hasChildren)
}
@Test func symlinkToDirectoryIsNotDescended() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let target = try Fixture(); defer { target.cleanup() }
    try target.file("big", bytes: 1_000_000)
    try fx.symlink("link", to: target.root)
    let (store, s) = try await scanFixture(fx)
    #expect(await store.rootSize() < 1_000_000 && s.files == 1 && s.unreadable == 0)
    let link = try #require(await store.rows(childrenOf: FileTree.root, limit: 10).first { $0.name == "link" })
    #expect(link.kind == .symlink && !link.hasChildren && link.size < 1_000_000)
}
@Test func unreadableDirectoryIsMarkedAndScanContinues() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("ok/f", bytes: 4096); let l = try fx.dir("locked"); try fx.file("locked/f", bytes: 1); chmod(l.path, 0)
    let (store, s) = try await scanFixture(fx)
    #expect(s.unreadable == 1)
    let rows = await store.rows(childrenOf: FileTree.root, limit: 10)
    #expect(rows.first { $0.name == "locked" }?.flags.contains(.unreadable) == true)
    #expect(rows.contains { $0.name == "ok" && $0.size > 0 })
}
@Test func cancelledBeforeStartReportsCancelled() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/b", bytes: 1)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path)
    let scanner = Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path))
    // Cancelled from inside the task before the scan starts, so the outcome never depends on timing.
    let summary = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await scanner.scan(into: store)
    }.value
    #expect(summary.wasCancelled && summary.files == 0 && summary.directories == 0)
    #expect(await store.rootSize() == 0)
    // A cancelled scan still finishes the store, with the root's contents marked unverified.
    #expect(await store.scanFinished)
    #expect(await store.unverifiedDirectories == [FileTree.root])
}

@Test func completedScanFinishesStoreWithItsDevices() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/b", bytes: 1)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path)
    let boundary = try ScanBoundary.forFolder(fx.root.path)
    #expect(await !store.scanFinished)
    _ = await Scanner(rootPath: fx.root.path, boundary: boundary).scan(into: store)
    #expect(await store.scanFinished)
    #expect(await store.scanDevices == boundary.allowedDevices)
    #expect(await store.unverifiedDirectories.isEmpty)
}
@Test func pathTooLongIsMarkedUnreadable() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    var rel = ""; for _ in 0..<12 { rel += String(repeating: "d", count: 100) + "/" }  // > PATH_MAX (1024)
    _ = try? fx.dir(rel)   // creation via relative mkdir loop inside Fixture.dir
    let (_, s) = try await scanFixture(fx)
    #expect(!s.wasCancelled)   // must finish without crashing; deep dirs counted as unreadable if unreachable
    #expect(s.unreadable >= 1)
}
@Test func breadcrumbFromRoot() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/b/c", bytes: 1)
    let (store, _) = try await scanFixture(fx)
    let a = await store.rows(childrenOf: FileTree.root, limit: 1)[0].id
    let b = await store.rows(childrenOf: a, limit: 1)[0].id
    #expect(await store.breadcrumb(to: b).map(\.name) == ["fx", "a", "b"])
}
@Test func finalProgressAgreesWithTreeTotals() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("x/big", bytes: 200_000); try fx.hardLink("y/big", to: f)
    _ = try fx.file("x/small", bytes: 10_000)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path)
    let reports = Mutex<[ScanProgress]>([])
    let summary = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path))
        .scan(into: store) { p in reports.withLock { $0.append(p) } }
    let last = try #require(reports.withLock { $0.last })
    #expect(last.bytesSeen == (await store.rootSize()))
    #expect(last.filesSeen == summary.files && last.directoriesPending == 0)
}
@Test func defaultConcurrencyLeavesTwoCoresForTheUI() {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    #expect(Scanner.defaultConcurrency == max(1, cores - 2))
    #expect(Scanner(rootPath: "/", boundary: ScanBoundary(allowedDevices: [], excludedPaths: [])).maxConcurrency
            == Scanner.defaultConcurrency)
}
@Test func snapshotMatchesTheSeparateQueries() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/b/c", bytes: 30_000); try fx.file("a/d", bytes: 10_000); try fx.file("e", bytes: 5_000)
    let (store, _) = try await scanFixture(fx)
    let a = await store.rows(childrenOf: FileTree.root, limit: 1)[0].id
    let snapshot = await store.snapshot(center: a, chart: .sunburst(depth: 3), biggestLimit: 1)
    #expect(!snapshot.segments.isEmpty && snapshot.tiles.isEmpty)
    #expect(snapshot.segments == (await store.sunburst(center: a, depth: 3)))
    #expect(snapshot.biggest == (await store.rows(childrenOf: a, limit: 1)))
    #expect(snapshot.breadcrumb == (await store.breadcrumb(to: a)))
    #expect(snapshot.categoryTotals == (await store.categoryTotals(of: a)) && !snapshot.categoryTotals.isEmpty)
    #expect(snapshot.breadcrumb.map(\.name) == ["fx", "a"] && snapshot.biggest.count == 1)
    let treemap = await store.snapshot(center: a, chart: .treemap(width: 400, height: 300, depth: 3), biggestLimit: 1)
    #expect(!treemap.tiles.isEmpty && treemap.segments.isEmpty)
    #expect(treemap.tiles == (await store.treemap(center: a, width: 400, height: 300, depth: 3)))
    #expect(treemap.biggest == snapshot.biggest && treemap.breadcrumb == snapshot.breadcrumb)
}
@Test func aSnapshotTakenInACancelledTaskIsEmptyAndDoesNoWork() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/b/c", bytes: 30_000); try fx.file("e", bytes: 5_000)
    let (store, _) = try await scanFixture(fx)
    let a = await store.rows(childrenOf: FileTree.root, limit: 1)[0].id
    let cancelled = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await store.snapshot(center: a, chart: .sunburst(depth: 3), biggestLimit: 5)
    }.value
    #expect(cancelled.segments.isEmpty && cancelled.tiles.isEmpty && cancelled.biggest.isEmpty
            && cancelled.breadcrumb.isEmpty && cancelled.verdicts.isEmpty)
    // Not cancelled: the same request is answered.
    let live = await store.snapshot(center: a, chart: .sunburst(depth: 3), biggestLimit: 5)
    #expect(!live.segments.isEmpty && !live.breadcrumb.isEmpty)
}
@Test func scanClassifiesWithContext() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("node_modules/x/big.js", bytes: 200_000); try fx.file("film.mov", bytes: 100_000)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path, home: "/nonexistent")
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    let totals = await store.categoryTotals(of: FileTree.root)
    #expect(totals[.development, default: 0] >= 200_000 && totals[.video, default: 0] >= 100_000)
    let rows = await store.rows(childrenOf: FileTree.root, limit: 10)
    #expect(rows.first { $0.name == "node_modules" }?.category == .development)
    #expect(rows.allSatisfy { $0.lastUsed > 0 })
}
@Test func insertUsesRootContextTimesAndHardLinkDuplicates() async {
    func file(_ name: String, size: UInt64, links: UInt32 = 1, mtime: UInt32, atime: UInt32) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .file, allocatedSize: size, device: 1, inode: 42, linkCount: links,
                       isMountPoint: false, isDataless: false, modificationTime: mtime, accessTime: atime)
    }
    let boundary = ScanBoundary(allowedDevices: [1], excludedPaths: [])
    // Scanning an app bundle directly: everything inside is App, whatever its extension.
    let app = ScanStore(rootName: "Xcode", rootPath: "/Applications/Xcode.app", home: "/nonexistent")
    _ = await app.insert([file("clip.mov", size: 4096, mtime: 5, atime: 9)], under: FileTree.root,
                         parentPath: "/Applications/Xcode.app", boundary: boundary)
    #expect(await app.categoryTotals(of: FileTree.root) == [.app: 4096])
    #expect(await app.row(FileTree.root)?.lastUsed == 9)
    // A hard-link duplicate adds no bytes but still raises the last use.
    let store = ScanStore(rootName: "fx", rootPath: "/fx", home: "/nonexistent")
    _ = await store.insert([file("a.mov", size: 4096, links: 2, mtime: 10, atime: 20)], under: FileTree.root,
                           parentPath: "/fx", boundary: boundary)
    let dup = await store.insert([file("b.mov", size: 4096, links: 2, mtime: 30, atime: 25)], under: FileTree.root,
                                 parentPath: "/fx", boundary: boundary)
    #expect(dup.bytes == 0)
    #expect(await store.categoryTotals(of: FileTree.root) == [.video: 4096])
    #expect(await store.row(FileTree.root)?.lastUsed == 30)
}

@Test func cargoTargetIsClassifiedFromItsSiblings() async throws {
    func entry(_ name: String, _ kind: NodeKind) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: kind, allocatedSize: 0, device: 1, inode: 0, linkCount: 1,
                       isMountPoint: false, isDataless: false)
    }
    let boundary = ScanBoundary(allowedDevices: [1], excludedPaths: [])
    let store = ScanStore(rootName: "p", rootPath: "/p", home: "/Users/me")
    let crates = await store.insert([entry("rust", .directory), entry("web", .directory)], under: FileTree.root,
                                    parentPath: "/p", boundary: boundary).descend
    let rust = try #require(crates.first { $0.path == "/p/rust" })
    let web = try #require(crates.first { $0.path == "/p/web" })
    let rustTarget = try #require(await store.insert([entry("Cargo.toml", .file), entry("target", .directory)],
                                                     under: rust.id, parentPath: rust.path, boundary: boundary)
        .descend.first)
    let webTarget = try #require(await store.insert([entry("target", .directory)], under: web.id,
                                                    parentPath: web.path, boundary: boundary).descend.first)
    #expect(await store.row(rustTarget.id)?.category == .development)
    #expect(await store.row(webTarget.id)?.category == .other)
}

@Test func packagesFlagTheirInterior() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Foo.app/Contents/MacOS/foo", bytes: 10_000); try fx.file("Lib.photoslibrary/db", bytes: 10)
    try fx.file("Setup.DMG", bytes: 1_000); try fx.file("plain/x.txt", bytes: 10)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path, home: "/nonexistent")
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    let rows = await store.rows(childrenOf: FileTree.root, limit: 10)
    let app = try #require(rows.first { $0.name == "Foo.app" })
    #expect(app.flags.contains(.package) && !app.flags.contains(.insidePackage))
    let inner = await store.rows(childrenOf: app.id, limit: 10)
    try #require(!inner.isEmpty)
    #expect(inner.allSatisfy { $0.flags.contains(.insidePackage) })
    let contents = try #require(inner.first { $0.name == "Contents" })
    let deeper = await store.rows(childrenOf: contents.id, limit: 10)
    try #require(!deeper.isEmpty)
    #expect(deeper.allSatisfy { $0.flags.contains(.insidePackage) })
    let lib = try #require(rows.first { $0.name == "Lib.photoslibrary" })
    #expect(lib.flags.contains(.package) && !lib.flags.contains(.insidePackage))
    let libKids = await store.rows(childrenOf: lib.id, limit: 10)
    let db = try #require(libKids.first { $0.name == "db" })
    #expect(db.flags.contains(.insidePackage))
    #expect(rows.first { $0.name == "plain" }?.flags.isDisjoint(with: [.package, .insidePackage]) == true)
    #expect(await store.installerCount() == 1)
}

@Test func scanOfBundleInteriorMarksEverything() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Foo.app/Contents/Resources/a.png", bytes: 100)
    let root = fx.root.appendingPathComponent("Foo.app/Contents").path
    let store = ScanStore(rootName: "Contents", rootPath: root, home: "/nonexistent")
    _ = await Scanner(rootPath: root, boundary: try .forFolder(root)).scan(into: store)
    #expect(await store.row(FileTree.root)?.flags.contains(.insidePackage) == true)
    #expect(await store.categoryTotals(of: FileTree.root).keys.allSatisfy { $0 == .app })
}

@Test func nestedPackageIsPackageAndInsidePackage() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Foo.app/Contents/PlugIns/Bar.appex/x", bytes: 10)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path, home: "/nonexistent")
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    var row = try #require(await store.rows(childrenOf: FileTree.root, limit: 10).first)
    for name in ["Contents", "PlugIns", "Bar.appex"] {
        row = try #require(await store.rows(childrenOf: row.id, limit: 10).first { $0.name == name })
    }
    #expect(row.flags.contains(.package) && row.flags.contains(.insidePackage))
}

// MARK: - Safety verdicts

/// Sets a file's access and modification times to `seconds` since 1970.
private func setTimes(_ url: URL, _ seconds: Int) throws {
    var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
    guard utimes(url.path, &times) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// A home folder with a leftover cache (`com.gone.app`) and an installer in Downloads, scanned.
private func scanLeftoverHome(_ fx: Fixture) async throws -> ScanStore {
    let home = fx.root.path
    try fx.file("Library/Caches/com.gone.app/blob", bytes: 50_000); try fx.file("Downloads/Setup.dmg", bytes: 5_000)
    let store = ScanStore(rootName: "fx", rootPath: home, home: home)
    _ = await Scanner(rootPath: home, boundary: try .forFolder(home)).scan(into: store)
    return store
}

@Test func snapshotCarriesVerdicts() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let home = fx.root.path
    let store = try await scanLeftoverHome(fx)
    await store.setEnvironment(.system(home: home, apps: .empty, runningBundleIDs: [], runningAppPaths: []))
    let caches = try #require(await store.node(atPath: home + "/Library/Caches"))
    let snap = await store.snapshot(center: caches, chart: .sunburst(depth: 3), biggestLimit: 5)
    let seg = try #require(snap.segments.first { $0.name == "com.gone.app" })
    let segNode = try #require(seg.node)
    #expect(seg.safety == .safe && snap.verdicts[segNode]?.reason == .leftover)
    #expect(snap.breadcrumb.last?.safety == .protected)        // Library/Caches is essential
    // Every element is stamped with its verdict's level, and every node has a verdict.
    #expect(snap.breadcrumb.first?.safety == .protected && snap.verdicts[FileTree.root]?.reason == .scanRoot)
    for s in snap.segments {
        let node = try #require(s.node)
        #expect(s.safety == snap.verdicts[node]?.level)
    }
    for row in snap.biggest + snap.breadcrumb { #expect(row.safety == snap.verdicts[row.id]?.level) }
    // `com.gone.app` is a package by its extension: it moves as a whole, its contents never alone.
    let blob = try #require(snap.segments.first { $0.name == "blob" })
    let blobNode = try #require(blob.node)
    #expect(blob.safety == .protected && snap.verdicts[blobNode]?.reason == .insidePackage)
    // Treemap tiles and list rows outside the chart's center.
    let downloads = try #require(await store.node(atPath: home + "/Downloads"))
    let tilesSnap = await store.snapshot(center: downloads, chart: .treemap(width: 400, height: 300, depth: 2),
                                         biggestLimit: 5)
    let dmg = try #require(tilesSnap.tiles.first { $0.name == "Setup.dmg" })
    let dmgNode = try #require(dmg.node)
    #expect(dmg.safety == .safe && tilesSnap.verdicts[dmgNode]?.reason == .installer)
    #expect(tilesSnap.biggest.first?.safety == .safe && tilesSnap.segments.isEmpty)
    #expect(await store.rows(childrenOf: caches, limit: 5).first?.safety == .safe)
    #expect(await store.verdict(dmgNode)?.level == .safe)
}

@Test func noAppsIndexMeansNoLeftovers() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let home = fx.root.path
    try fx.file("Library/Application Support/com.gone.editor/data/old.bin", bytes: 10_000)
    let store = try await scanLeftoverHome(fx)
    let caches = try #require(await store.node(atPath: home + "/Library/Caches"))
    let snap = await store.snapshot(center: caches, chart: .sunburst(depth: 3), biggestLimit: 5)
    let seg = try #require(snap.segments.first { $0.name == "com.gone.app" })
    let segNode = try #require(seg.node)
    #expect(seg.safety == .normal && snap.verdicts[segNode]?.reason == .analysisPending)
    #expect(!snap.segments.contains { $0.safety == .safe } && !snap.biggest.contains { $0.safety == .safe })
    // Deeper items of other locations wait too.
    let support = home + "/Library/Application Support/com.gone.editor"
    for path in [support, support + "/data", support + "/data/old.bin"] {
        let id = try #require(await store.node(atPath: path))
        #expect(await store.verdict(id) == SafetyVerdict(level: .normal, reason: .analysisPending))
    }
    // Once the index is ready, the cached pending verdicts are replaced.
    await store.setEnvironment(.system(home: home, apps: .empty))
    #expect(await store.verdict(segNode)?.reason == .leftover)
}

@Test func deepFileInRecentlyUsedLeftoverIsCaution() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let home = fx.root.path
    let old = Int(Date().timeIntervalSince1970) - 400 * 86_400
    let deep = try fx.file("Library/Application Support/com.gone.editor/sub/old.bin", bytes: 10_000)
    try fx.file("Library/Application Support/com.gone.editor/recent.txt", bytes: 100)
    let control = try fx.file("Library/Application Support/com.old.editor/sub/old.bin", bytes: 10_000)
    try setTimes(deep, old); try setTimes(control, old)
    let store = ScanStore(rootName: "fx", rootPath: home, home: home)
    _ = await Scanner(rootPath: home, boundary: try .forFolder(home)).scan(into: store)
    await store.setEnvironment(.system(home: home, apps: .empty))
    let support = home + "/Library/Application Support"
    let deepID = try #require(await store.node(atPath: support + "/com.gone.editor/sub/old.bin"))
    let subID = try #require(await store.node(atPath: support + "/com.gone.editor/sub"))
    #expect(await store.verdict(deepID) == SafetyVerdict(level: .caution, reason: .recentLeftover))
    #expect(await store.verdict(subID) == SafetyVerdict(level: .caution, reason: .recentLeftover))
    // The same layout with nothing recent is a leftover all the way down.
    let controlID = try #require(await store.node(atPath: support + "/com.old.editor/sub/old.bin"))
    #expect(await store.verdict(controlID) == SafetyVerdict(level: .safe, reason: .leftover))
}

@Test func leftoverAboveTheScanRootIsNotTakenAsOld() async throws {
    // Scanning inside a leftover: the folder's other contents are unknown, so its last use is too.
    let fx = try Fixture(); defer { fx.cleanup() }
    let home = fx.root.path
    let file = try fx.file("Library/Application Support/com.gone.editor/sub/old.bin", bytes: 10_000)
    try setTimes(file, Int(Date().timeIntervalSince1970) - 400 * 86_400)
    let root = home + "/Library/Application Support/com.gone.editor/sub"
    let store = ScanStore(rootName: "sub", rootPath: root, home: home)
    _ = await Scanner(rootPath: root, boundary: try .forFolder(root)).scan(into: store)
    await store.setEnvironment(.system(home: home, apps: .empty))
    let id = try #require(await store.node(atPath: root + "/old.bin"))
    #expect(await store.verdict(id) == SafetyVerdict(level: .caution, reason: .recentLeftover))
}

@Test func rootPathIsCanonicalized() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let home = fx.root.path
    try fx.file("Downloads/Setup.dmg", bytes: 5_000)
    for raw in [home + "/", home + "//", home.replacingOccurrences(of: "/", with: "//") + "///"] {
        let store = ScanStore(rootName: "fx", rootPath: raw, home: home)
        _ = await Scanner(rootPath: home, boundary: try .forFolder(home)).scan(into: store)
        #expect(await store.path(of: FileTree.root) == home)
        let dmg = try #require(await store.node(atPath: home + "/Downloads/Setup.dmg"))
        #expect(await store.path(of: dmg) == home + "/Downloads/Setup.dmg")
        await store.setEnvironment(.system(home: home, apps: .empty))
        #expect(await store.verdict(dmg) == SafetyVerdict(level: .safe, reason: .installer))
    }
    #expect(await ScanStore(rootName: "/", rootPath: "/").path(of: FileTree.root) == "/")
    #expect(await ScanStore(rootName: "/", rootPath: "///").path(of: FileTree.root) == "/")
}

@Test func verdictsAreCachedUntilTheTreeOrEnvironmentChanges() async throws {
    func file(_ name: String, time: UInt32) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .file, allocatedSize: 4096, device: 1, inode: 0, linkCount: 1,
                       isMountPoint: false, isDataless: false, modificationTime: time, accessTime: time)
    }
    func dir(_ name: String) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .directory, allocatedSize: 0, device: 1, inode: 0, linkCount: 1,
                       isMountPoint: false, isDataless: false)
    }
    let home = "/Users/u", boundary = ScanBoundary(allowedDevices: [1], excludedPaths: [])
    let now = UInt32(Date().timeIntervalSince1970)
    let store = ScanStore(rootName: "u", rootPath: home, home: home, now: now)
    // The folders exist only in the tree: write access comes from a switch the test flips.
    let writable = Mutex(true)
    await store.setEnvironment(SafetyEnvironment(home: home, apps: .empty, runningBundleIDs: [], runningAppPaths: [],
                                                 now: now, isWritable: { _ in writable.withLock { $0 } }))
    let lib = try #require(await store.insert([dir("Library")], under: FileTree.root, parentPath: home,
                                              boundary: boundary).descend.first)
    let loc = try #require(await store.insert([dir("Application Support")], under: lib.id, parentPath: lib.path,
                                              boundary: boundary).descend.first)
    let app = try #require(await store.insert([dir("com.gone.editor")], under: loc.id, parentPath: loc.path,
                                              boundary: boundary).descend.first)
    _ = await store.insert([file("old", time: now - 400 * 86_400)], under: app.id, parentPath: app.path,
                           boundary: boundary)
    let before = await store.verdictEvaluations
    let snap = await store.snapshot(center: loc.id, chart: .sunburst(depth: 2), biggestLimit: 5)
    #expect(snap.verdicts[app.id] == SafetyVerdict(level: .safe, reason: .leftover))
    let evaluated = await store.verdictEvaluations - before
    #expect(evaluated == snap.verdicts.count)                  // each node evaluated once
    _ = await store.snapshot(center: loc.id, chart: .treemap(width: 300, height: 200, depth: 2), biggestLimit: 5)
    #expect(await store.verdictEvaluations - before == evaluated)   // all cached
    // A change outside the tree is not seen until the cache is invalidated.
    writable.withLock { $0 = false }
    #expect(await store.verdict(app.id)?.reason == .leftover)
    await store.invalidateVerdicts()
    #expect(await store.verdict(app.id)?.reason == .notWritable)
    // A recent file arriving during the scan is seen at once: inserting drops the cache.
    writable.withLock { $0 = true }
    await store.invalidateVerdicts()
    #expect(await store.verdict(app.id)?.reason == .leftover)
    _ = await store.insert([file("new", time: now)], under: app.id, parentPath: app.path, boundary: boundary)
    #expect(await store.verdict(app.id) == SafetyVerdict(level: .caution, reason: .recentLeftover))
}

@Test func mergedElementsStayNormal() async throws {
    // A big installer and many tiny ones in Downloads: the tiny ones merge into "altri".
    func file(_ name: String, size: UInt64) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: .file, allocatedSize: size, device: 1, inode: 0, linkCount: 1,
                       isMountPoint: false, isDataless: false)
    }
    let home = "/Users/u", boundary = ScanBoundary(allowedDevices: [1], excludedPaths: [])
    let store = ScanStore(rootName: "u", rootPath: home, home: home)
    await store.setEnvironment(SafetyEnvironment(home: home, apps: .empty, runningBundleIDs: [], runningAppPaths: [],
                                                 now: 0, isWritable: { _ in true }))
    let downloads = try #require(await store.insert([DirectoryEntry(
        name: "Downloads", kind: .directory, allocatedSize: 0, device: 1, inode: 0, linkCount: 1,
        isMountPoint: false, isDataless: false)], under: FileTree.root, parentPath: home, boundary: boundary)
        .descend.first)
    _ = await store.insert([file("Big.dmg", size: 100_000_000)] + (0..<300).map { file("s\($0).dmg", size: 4096) },
                           under: downloads.id, parentPath: downloads.path, boundary: boundary)
    let sun = await store.snapshot(center: downloads.id, chart: .sunburst(depth: 1), biggestLimit: 5)
    let tree = await store.snapshot(center: downloads.id, chart: .treemap(width: 200, height: 100, depth: 1),
                                    biggestLimit: 5)
    let mergedSegment = try #require(sun.segments.first { $0.node == nil })
    let mergedTile = try #require(tree.tiles.first { $0.node == nil })
    #expect(mergedSegment.safety == .normal && mergedTile.safety == .normal)
    #expect(sun.segments.first { $0.name == "Big.dmg" }?.safety == .safe)
    #expect(tree.tiles.first { $0.name == "Big.dmg" }?.safety == .safe)
}

/// A node ID kept from another scan's store is recognised as foreign rather than trapping: the app
/// checks `contains` before asking about it, and a snapshot centred on it is empty.
@Test func foreignNodeIDsAreRejected() async throws {
    let store = ScanStore(rootName: "r", rootPath: "/tmp/macspace-foreign-ids")
    await store.markScanFinished()
    #expect(await store.contains(FileTree.root))
    for id: NodeID in [-1, 1, 5_000] { #expect(await !store.contains(id)) }
    let snap = await store.snapshot(center: 5_000, chart: .sunburst(depth: 3), biggestLimit: 5)
    #expect(snap.segments.isEmpty && snap.biggest.isEmpty && snap.breadcrumb.isEmpty && snap.verdicts.isEmpty)
    let tiles = await store.snapshot(center: 5_000, chart: .treemap(width: 100, height: 100, depth: 2),
                                     biggestLimit: 5)
    #expect(tiles.tiles.isEmpty)
}

@Test func partlyReadCountsIncompleteListings() async throws {
    func entry(_ name: String, _ kind: NodeKind) -> DirectoryEntry {
        DirectoryEntry(name: name, kind: kind, allocatedSize: kind == .file ? 100 : 0, device: 1, inode: 0,
                       linkCount: 1, isMountPoint: false, isDataless: false)
    }
    let listings: [String: DirectoryListing] = [
        "/x": DirectoryListing(entries: [entry("a", .directory), entry("b", .directory)], isComplete: true),
        "/x/a": DirectoryListing(entries: [entry("f", .file)], isComplete: false),
        "/x/b": DirectoryListing(entries: [entry("g", .file)], isComplete: true),
    ]
    let scanner = Scanner(rootPath: "/x", boundary: ScanBoundary(allowedDevices: [1], excludedPaths: [])) {
        path throws(DirectoryReadError) in
        guard let listing = listings[path] else { throw .notFound }
        return listing
    }
    let store = ScanStore(rootName: "x", rootPath: "/x", history: FakeChangeHistory(start: nil))
    let summary = await scanner.scan(into: store)
    #expect(summary.partlyRead == 1)
    #expect(summary.unreadable == 0)
    #expect(!summary.wasCancelled)
}

@Test func appNamedLibraryFolderIsNotAppCategory() async throws {   // seen live: com.usebruno.app
    // A bundle-ID folder ending in ".app" in a `~/Library` location: its category comes from the
    // location (App data), not its name; its contents stay protected as inside a package.
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Library/Caches/com.example.app/data.bin", bytes: 50_000)
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    let caches = fx.root.path + "/Library/Caches"
    let folder = try #require(await store.node(atPath: caches + "/com.example.app"))
    let data = try #require(await store.node(atPath: caches + "/com.example.app/data.bin"))
    #expect(await store.categoryTotals(of: folder).keys.sorted { $0.rawValue < $1.rawValue } == [.appData])
    #expect(await store.row(data)?.flags.contains(.insidePackage) == true)
}
