import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

/// `SavedScan`: a finished store captured and restored (#33, Task 1).
private let day: UInt32 = 86_400

/// Scans `fx` into a fresh store whose ages are measured from `now`; `partial` names folders
/// (relative) whose listing the reader reports incomplete.
func scannedStore(_ fx: Fixture, now: UInt32 = UInt32(time(nil)), partial: Set<String> = [],
                  history: any ChangeHistory = FakeChangeHistory()) async throws -> ScanStore {
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: now, history: history)
    let partialPaths = Set(partial.map { fx.root.path + "/" + $0 })
    let scanner = Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path), maxConcurrency: 1) { path throws(DirectoryReadError) in
        var listing = try DirectoryReader.read(path: path)
        if partialPaths.contains(path) { listing.isComplete = false }
        return listing
    }
    _ = await scanner.scan(into: store)
    return store
}

/// `a/f`, hard links `a/h` + `b/h2`, a symlink, an installer, an app, a locked folder, a partial one.
func richFixture() throws -> Fixture {
    let fx = try Fixture()
    try fx.file("a/f", bytes: 100)
    let h = try fx.file("a/h", bytes: 5000)
    try fx.hardLink("b/h2", to: h)
    try fx.symlink("s", to: fx.root.appendingPathComponent("a"))
    try fx.file("x.dmg", bytes: 300)
    try fx.file("pkg.app/Contents/MacOS/bin", bytes: 700)
    try fx.file("part/p", bytes: 10)
    try fx.file("locked/secret", bytes: 10)
    chmod(fx.root.path + "/locked", 0o000)
    return fx
}

private func expectSameTree(_ a: ScanStore, _ b: ScanStore, _ root: String) async {
    #expect(await a.factsByPath() == b.factsByPath())
    #expect(await a.unverifiedPaths() == b.unverifiedPaths())
    #expect(await a.hardLinkPaths() == b.hardLinkPaths())
    #expect(await a.installerCount() == b.installerCount())
    for path in [root, root + "/a"] {
        let x = await a.totals(at: path), y = await b.totals(at: path)
        #expect(x?.categories == y?.categories && x?.ages == y?.ages, "\(path)")
    }
}

@Test func savedScanRoundTripsTheTree() async throws {
    let fx = try richFixture(); defer { fx.cleanup() }
    let now = UInt32(time(nil))
    let store = try await scannedStore(fx, now: now, partial: ["part"])
    let saved = await store.savedScan(target: .folder(path: fx.root.path), startedAt: now, hadFullDiskAccess: true)
    let restored = ScanStore(saved: saved, home: fx.root.path, now: now, history: FakeChangeHistory())
    await expectSameTree(store, restored, fx.root.path)
    #expect(await restored.unverifiedPaths().contains(fx.root.path + "/part"))
    #expect(await restored.hardLinkPaths().count == 1)
    #expect(saved.target == .folder(path: fx.root.path) && saved.startedAt == now && saved.hadFullDiskAccess)
    #expect(saved.rootPath == fx.root.path)
    #expect(saved.rootInode == (try DirectoryReader.stat(path: fx.root.path)).inode)
}

@Test func restoredAgesMeasureFromNow() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let url = try fx.file("a/old", bytes: 4096)
    let t = UInt32(time(nil))
    var times = [timespec(tv_sec: Int(t - 10 * day), tv_nsec: 0), timespec(tv_sec: Int(t - 10 * day), tv_nsec: 0)]
    #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
    let store = try await scannedStore(fx, now: t)
    let saved = await store.savedScan(target: .folder(path: fx.root.path), startedAt: t, hadFullDiskAccess: true)
    let later = t + 300 * day
    let restored = ScanStore(saved: saved, home: fx.root.path, now: later, history: FakeChangeHistory())
    let facts = await restored.factsByPath()
    let bucket = AgeBucket(lastUsed: t - 10 * day, now: later)
    #expect(bucket == .lastYear)
    #expect(facts[fx.root.path + "/a/old"]?.ageBucket == bucket)
    let rootAges = await restored.totals(at: fx.root.path)?.ages
    #expect(rootAges?[bucket] == facts[fx.root.path + "/a/old"]?.size)
    #expect(rootAges?[.lastMonth, default: 0] == 0)
}

@Test func restoredStoreRefusesTrash() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/f", bytes: 100)
    let store = try await scannedStore(fx)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    let saved = await store.savedScan(target: .folder(path: fx.root.path), startedAt: UInt32(time(nil)), hadFullDiskAccess: true)
    let restored = ScanStore(saved: saved, home: fx.root.path, history: FakeChangeHistory())
    await restored.setEnvironment(.system(home: fx.root.path, apps: .empty))
    let a = try #require(await restored.node(atPath: fx.root.path + "/a"))
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await restored.trash([a], actions: actions, packages: FakePackageProbe(packages: []),
                                       openFiles: { OpenFileSet(paths: []) }, expectedVerdicts: nil,
                                       mountPoints: MountTable.current)
    #expect(outcome.skipped.map(\.reason) == [.scanInProgress])
    #expect(actions.moved.isEmpty)
    let shown = await restored.trashPreview([a], packages: FakePackageProbe(packages: []),
                                            openFiles: { OpenFileSet(paths: []) }, expectedVerdicts: nil,
                                            mountPoints: MountTable.current)
    #expect(shown == [a: .scanInProgress])
}

@Test func directoryDevicesAreRecorded() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/f", bytes: 100)
    let store = try await scannedStore(fx)
    let root = try DirectoryReader.stat(path: fx.root.path).device
    let a = try DirectoryReader.stat(path: fx.root.path + "/a").device
    let aID = try #require(await store.node(atPath: fx.root.path + "/a"))
    #expect(await store.device(ofDirectory: FileTree.root) == root)
    #expect(await store.device(ofDirectory: aID) == a)
    let saved = await store.savedScan(target: .startupDisk, startedAt: 0, hadFullDiskAccess: false)
    let restored = ScanStore(saved: saved, home: fx.root.path, history: FakeChangeHistory())
    #expect(await restored.device(ofDirectory: FileTree.root) == root)
    #expect(await restored.device(ofDirectory: aID) == a)
}

/// A refresh rebuilds a tree whose size the snapshot gives: reserving it up front spares the
/// arrays their doublings (each a copy, and a freed buffer the allocator keeps) (#33).
@Test func storeReservesWhatASavedScanHolds() async throws {
    let fx = try richFixture(); defer { fx.cleanup() }
    let saved = await (try await scannedStore(fx)).savedScan(target: .startupDisk, startedAt: 0, hadFullDiskAccess: true)
    let fresh = ScanStore(rootName: "r", rootPath: fx.root.path, history: FakeChangeHistory())
    await fresh.reserveCapacity(like: saved)
    let capacity = await fresh.treeCapacity()
    let nodes = saved.tree.count, dirs = saved.tree.dirDevices.count, names = saved.tree.nameBytes.count
    #expect(capacity.nodes >= nodes + nodes / 16)
    #expect(capacity.directories >= dirs + dirs / 16)
    #expect(capacity.nameBytes >= names + names / 16)
}

/// A full scan behind a scanned tree reserves that tree's size, as a refresh reserves its
/// snapshot's: both give the same size.
@Test func storeGivesTheSizeItsSnapshotWould() async throws {
    let fx = try richFixture(); defer { fx.cleanup() }
    let store = try await scannedStore(fx)
    let saved = await store.savedScan(target: .startupDisk, startedAt: 0, hadFullDiskAccess: true)
    #expect(await store.treeSize() == saved.treeSize)
    let fresh = ScanStore(rootName: "r", rootPath: fx.root.path, history: FakeChangeHistory())
    await fresh.reserveCapacity(for: await store.treeSize())
    let capacity = await fresh.treeCapacity()
    #expect(capacity.nodes >= saved.treeSize.nodes && capacity.nameBytes >= saved.treeSize.nameBytes)
}
