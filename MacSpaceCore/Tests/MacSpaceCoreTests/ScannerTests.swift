import Darwin
import Foundation
import Testing
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
    let task = Task { await Scanner(rootPath: fx.root.path, boundary: try! .forFolder(fx.root.path)).scan(into: store) }
    task.cancel()
    #expect(await task.value.wasCancelled)
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
