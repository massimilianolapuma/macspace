import Darwin
import Foundation
import Synchronization
import Testing
@testable import MacSpaceCore

/// The incremental refresh: its plan from the history, and the saved-listing reader (#33, Task 4).
private func save(_ store: ScanStore, _ fx: Fixture, startedAt: UInt32 = UInt32(time(nil)),
                  fullDiskAccess: Bool = true) async -> SavedScan {
    await store.savedScan(target: .folder(path: fx.root.path), startedAt: startedAt, hadFullDiskAccess: fullDiskAccess)
}

/// Rebuilds `fx` from `saved`, reading from disk the folders in `changed` (relative; "" is the
/// root) and whatever cannot be vouched for. Returns the store and the folders read from disk.
private func refresh(_ fx: Fixture, _ saved: SavedScan, changed: [String],
                     history: any ChangeHistory = FakeChangeHistory()) async throws -> (ScanStore, Set<String>) {
    let read = Mutex<Set<String>>([])
    let disk: ListingReader = { request throws(DirectoryReadError) in
        read.withLock { _ = $0.insert(request.path) }
        return try DirectoryReader.read(path: request.path)
    }
    let paths = Set(changed.map { $0.isEmpty ? fx.root.path : fx.root.path + "/" + $0 })
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: UInt32(time(nil)),
                          history: history)
    let scanner = Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path), maxConcurrency: 1,
                          listing: saved.listingReader(changed: paths, disk: disk))
    _ = await scanner.scan(into: store)
    let relative = read.withLock { $0 }.map { $0 == fx.root.path ? "" : String($0.dropFirst(fx.root.path.count + 1)) }
    return (store, Set(relative))
}

private func expectEqualTrees(_ a: ScanStore, _ b: ScanStore, _ root: String) async {
    let x = await a.factsByPath(), y = await b.factsByPath()
    #expect(x == y)
    if x != y {
        for path in Set(x.keys).union(y.keys).sorted() where x[path] != y[path] {
            Issue.record("\(path): refreshed \(x[path].map(String.init(describing:)) ?? "-") scanned \(y[path].map(String.init(describing:)) ?? "-")")
        }
    }
    #expect(await a.unverifiedPaths() == b.unverifiedPaths())
    #expect(await a.hardLinkPaths() == b.hardLinkPaths())
    #expect(await a.installerCount() == b.installerCount())
    let s = await a.totals(at: root), t = await b.totals(at: root)
    #expect(s?.categories == t?.categories && s?.ages == t?.ages)
}

@Test func refreshEqualsRescan() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/f", bytes: 100)
    try fx.file("a/keep/k", bytes: 200)
    try fx.file("b/g", bytes: 300)
    try fx.file("r/inside/x", bytes: 400)
    try fx.file("u/v/w", bytes: 500)
    try fx.file("u/y.dmg", bytes: 600)
    let saved = await save(try await scannedStore(fx), fx)
    try fx.file("a/new.txt", bytes: 1000)
    try FileManager.default.removeItem(atPath: fx.root.path + "/a/f")
    let g = try FileHandle(forWritingTo: fx.root.appendingPathComponent("b/g"))
    try g.seekToEnd()
    try g.write(contentsOf: Data(repeating: 1, count: 70_000))
    try g.close()
    try fx.file("c/d/e.txt", bytes: 50)
    try FileManager.default.moveItem(atPath: fx.root.path + "/r", toPath: fx.root.path + "/r2")
    let (refreshed, read) = try await refresh(fx, saved, changed: ["", "a", "b"])
    await expectEqualTrees(refreshed, try await scannedStore(fx), fx.root.path)
    #expect(read == ["", "a", "b", "c", "c/d", "r2", "r2/inside"])
}

@Test func refreshReadsReplacedFolderFromDisk() async throws {   // Review Focus 1
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("A/old.txt", bytes: 100)
    try fx.file("B/New.photoslibrary/x", bytes: 100)
    let saved = await save(try await scannedStore(fx), fx)
    try FileManager.default.removeItem(atPath: fx.root.path + "/A")
    try FileManager.default.moveItem(atPath: fx.root.path + "/B", toPath: fx.root.path + "/A")
    let (store, read) = try await refresh(fx, saved, changed: [""])
    #expect(read.contains("A"))
    #expect(await store.node(atPath: fx.root.path + "/A/old.txt") == nil)
    let a = try #require(await store.node(atPath: fx.root.path + "/A"))
    #expect(await store.node(atPath: fx.root.path + "/A/New.photoslibrary/x") != nil)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    let shown = await store.trashPreview([a], packages: FakePackageProbe(packages: []),
                                         openFiles: { OpenFileSet(paths: []) }, expectedVerdicts: nil,
                                         mountPoints: MountTable.current)
    #expect(shown == [a: .containsProtected(.photosLibrary)])
}

@Test func refreshRereadsUnreadableAndPartial() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("locked/secret", bytes: 10)
    try fx.file("part/p", bytes: 10)
    try fx.file("plain/q", bytes: 10)
    chmod(fx.root.path + "/locked", 0o000)
    let saved = await save(try await scannedStore(fx, partial: ["part"]), fx)
    chmod(fx.root.path + "/locked", 0o755)
    let (store, read) = try await refresh(fx, saved, changed: [])
    #expect(read == ["locked", "part"])
    #expect(await store.node(atPath: fx.root.path + "/locked/secret") != nil)
}

@Test func hardLinkAddedSinceSnapshotIsCountedAgain() async throws {   // documented residual
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("a/f", bytes: 8192)
    try fx.file("b/other", bytes: 0)
    let saved = await save(try await scannedStore(fx), fx)
    try fx.hardLink("b/l", to: f)
    let (refreshed, _) = try await refresh(fx, saved, changed: ["b"])
    let scanned = try await scannedStore(fx)
    // A full scan counts the file once, on whichever link it meets first.
    let once = await scanned.rootSize()
    #expect(once >= 8192 && once < 2 * 8192)
    #expect(await refreshed.rootSize() == once * 2)
}

@Test func trashAfterRefreshUsesItsBaseline() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let saved = await save(try await scannedStore(fx), fx)
    let history = FakeChangeHistory(answer: .folders([fx.root.path + "/a/sub"]))
    let (store, _) = try await refresh(fx, saved, changed: [], history: history)
    try fx.file("a/sub/New.photoslibrary/x", bytes: 100)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    let a = try #require(await store.node(atPath: fx.root.path + "/a"))
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([a], actions: actions, packages: FakePackageProbe(packages: []),
                                    openFiles: { OpenFileSet(paths: []) }, expectedVerdicts: nil,
                                    mountPoints: MountTable.current)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
    #expect(actions.moved.isEmpty)
}

// MARK: - The plan

private func plan(_ saved: SavedScan, now: UInt32? = nil, rootInode: UInt64? = nil, access: Bool = true,
                  history: any ChangeHistory = FakeChangeHistory(answer: .folders(["/x"]))) -> RefreshPlan {
    saved.refreshPlan(now: now ?? saved.startedAt + 60, rootInode: rootInode ?? saved.rootInode,
                      hasFullDiskAccess: access, history: history)
}

@Test func planFallsBack() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/f", bytes: 10)
    let store = try await scannedStore(fx)
    let saved = await save(store, fx, startedAt: 1_000_000)
    #expect(plan(saved, now: 1_000_000 + SavedScan.maxRefreshAge + 1) == .fullScan(.tooOld))
    #expect(plan(saved, now: 1_000_000 + SavedScan.maxRefreshAge) == .incremental(changed: ["/x"]))
    #expect(plan(saved, rootInode: saved.rootInode + 1) == .fullScan(.rootReplaced))
    #expect(plan(saved, access: false) == .fullScan(.fullDiskAccessLost))
    #expect(plan(saved, history: FakeChangeHistory(answer: .untrusted)) == .fullScan(.historyUntrusted))
    let bare = try await scannedStore(fx, history: FakeChangeHistory(start: nil))
    #expect(plan(await save(bare, fx, startedAt: 1_000_000)) == .fullScan(.noBaseline))
}

@Test func planIsIncremental() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/f", bytes: 10)
    let store = try await scannedStore(fx)
    let changed: Set<String> = [fx.root.path + "/a"]
    let history = FakeChangeHistory(answer: .folders(changed))
    #expect(plan(await save(store, fx), history: history) == .incremental(changed: changed))
    // Granted since: nothing was hidden from the history then.
    #expect(plan(await save(store, fx, fullDiskAccess: false), history: history) == .incremental(changed: changed))
}
