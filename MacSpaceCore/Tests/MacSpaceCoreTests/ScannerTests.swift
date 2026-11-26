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
    let alloc = { (u: URL) in UInt64(try! u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize!) }
    let (store, s) = try await scanFixture(fx)
    #expect(s.files == 2 && s.directories >= 2 && !s.wasCancelled)
    #expect(await store.rootSize() == alloc(a) + alloc(b))
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
    let snapshot = await store.snapshot(center: a, depth: 3, biggestLimit: 1)
    #expect(snapshot.segments == (await store.sunburst(center: a, depth: 3)))
    #expect(snapshot.biggest == (await store.rows(childrenOf: a, limit: 1)))
    #expect(snapshot.breadcrumb == (await store.breadcrumb(to: a)))
    #expect(snapshot.breadcrumb.map(\.name) == ["fx", "a"] && snapshot.biggest.count == 1)
}
