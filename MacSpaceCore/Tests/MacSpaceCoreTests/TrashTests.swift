import Darwin
import Foundation
import Synchronization
import Testing
@testable import MacSpaceCore

/// Test double for `PackageProbe`: exactly `packages` are packages.
struct FakePackageProbe: PackageProbe {
    let packages: Set<String>
    func isPackage(_ path: String) -> Bool { packages.contains(path) }
}

/// Counts calls to the `openFiles` closure.
private final class CallCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func tick() { count.withLock { $0 += 1 } }
}

extension ScanStore {
    /// Plants a (wrong) verdict in the cache, to prove `trash` re-evaluates instead of trusting it.
    func plantVerdict(_ verdict: SafetyVerdict, for id: NodeID) { verdictCache[id] = verdict }
}

private let fixedNow = UInt32(time(nil))
private let noPackages = FakePackageProbe(packages: [])
private let nothingOpen: @Sendable () -> OpenFileSet = { OpenFileSet(paths: []) }

/// Scans `fx` as a home folder, then judges against an empty apps index.
private func scanned(_ fx: Fixture, runningAppPaths: Set<String> = []) async throws -> ScanStore {
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: fixedNow)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty, runningAppPaths: runningAppPaths))
    return store
}

private func node(_ store: ScanStore, _ fx: Fixture, _ rel: String) async throws -> NodeID {
    try #require(await store.node(atPath: fx.root.path + "/" + rel))
}

private func exists(_ path: String) -> Bool {
    var info = Darwin.stat()
    return lstat(path, &info) == 0
}

@Test func movesAndUpdatesTree() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Library/Caches/com.gone.x/a", bytes: 2_000_000)
    try fx.file("Library/Caches/com.gone.x/sub/b", bytes: 10_000)
    try fx.file("Library/Caches/com.kept.y/a", bytes: 30_000)
    try fx.file("Documents/keep.txt", bytes: 50_000)
    let store = try await scanned(fx)
    let target = try await node(store, fx, "Library/Caches/com.gone.x")
    let path = fx.root.path + "/Library/Caches/com.gone.x"
    let before = await store.rootSize()
    let size = await store.row(target).size
    #expect(size >= 2_000_000)

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([target], actions: actions, packages: noPackages, openFiles: nothingOpen)

    #expect(actions.moved == [path])
    #expect(outcome.moved == [TrashOutcome.Moved(node: target, name: "com.gone.x", size: size,
                                                 trashedPath: bin.root.path + "/com.gone.x")])
    #expect(outcome.skipped.isEmpty)
    #expect(!exists(path) && exists(bin.root.path + "/com.gone.x/a"))
    #expect(await store.rootSize() == before - size)
    #expect(await store.row(target).flags.contains(.removed))
    #expect(await store.node(atPath: path) == nil)
    let caches = try await node(store, fx, "Library/Caches")
    #expect(await store.rows(childrenOf: caches, limit: 10).map(\.name) == ["com.kept.y"])

    let fresh = try await scanned(fx)
    #expect(await store.rootSize() == fresh.rootSize())
    #expect(await store.categoryTotals(of: FileTree.root) == fresh.categoryTotals(of: FileTree.root))
    #expect(await store.ageTotals(of: FileTree.root) == fresh.ageTotals(of: FileTree.root))
    #expect(await store.categoryTotals(of: caches) == fresh.categoryTotals(of: try node(fresh, fx, "Library/Caches")))
}

@Test func nestedSelectionTrashesTopMostOnce() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Library/Caches/com.gone.x/sub/file", bytes: 2_000_000)
    let store = try await scanned(fx)
    let folder = try await node(store, fx, "Library/Caches/com.gone.x")
    let inner = try await node(store, fx, "Library/Caches/com.gone.x/sub/file")

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([folder, inner], actions: actions, packages: noPackages, openFiles: nothingOpen)

    #expect(actions.moved == [fx.root.path + "/Library/Caches/com.gone.x"])
    #expect(outcome.moved.map(\.node) == [folder] && outcome.skipped.isEmpty)
}

@Test func topMostDropsNestedRemovedRootAndStaleIDs() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("A/big", bytes: 300_000)
    try fx.file("A/inner/f", bytes: 1_000)
    try fx.file("B/small", bytes: 20_000)
    try fx.file("C/mid", bytes: 100_000)
    let store = try await scanned(fx)
    let a = try await node(store, fx, "A")
    let inner = try await node(store, fx, "A/inner")
    let b = try await node(store, fx, "B")
    let c = try await node(store, fx, "C")
    let stale: Set<NodeID> = [-1, -400, 9_999_999, NodeID.max]
    let top = await store.topMost([a, inner, b, c, FileTree.root].reduce(into: stale) { $0.insert($1) })
    #expect(top == [a, c, b])   // size descending
}

@Test func protectedIsNeverMoved() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Library/Caches/com.gone.x/a", bytes: 2_000_000)
    try fx.file("Library/Keychains/login.keychain-db", bytes: 10_000)
    try fx.file("Foo.app/Contents/Resources/x", bytes: 10_000)
    try fx.file("Pictures/Ph.photoslibrary/database/db", bytes: 10_000)
    let store = try await scanned(fx)
    let library = try await node(store, fx, "Library")
    let caches = try await node(store, fx, "Library/Caches")
    let inBundle = try await node(store, fx, "Foo.app/Contents/Resources/x")
    let actions = RecordingDiskActions(trash: bin.root.path)

    let first = await store.trash([library, caches, inBundle, FileTree.root], actions: actions,
                                  packages: noPackages, openFiles: nothingOpen)
    #expect(first.moved.isEmpty)
    #expect(Dictionary(uniqueKeysWithValues: first.skipped.map { ($0.node, $0.reason) })
            == [library: .refused, inBundle: .protected(.insidePackage)])   // Caches is below Library

    let keychain = try await node(store, fx, "Library/Keychains/login.keychain-db")
    let photos = try await node(store, fx, "Pictures/Ph.photoslibrary")
    // A stale "safe" verdict in the cache must not matter: the store re-evaluates.
    await store.plantVerdict(SafetyVerdict(level: .safe, reason: .leftover), for: inBundle)
    let second = await store.trash([caches, keychain, photos, inBundle], actions: actions,
                                   packages: noPackages, openFiles: nothingOpen)
    #expect(second.moved.isEmpty)
    #expect(Dictionary(uniqueKeysWithValues: second.skipped.map { ($0.node, $0.reason) })
            == [caches: .refused, keychain: .protected(.appleData), photos: .protected(.photosLibrary),
                inBundle: .protected(.insidePackage)])
    #expect(actions.moved.isEmpty)
    #expect(exists(fx.root.path + "/Foo.app/Contents/Resources/x"))
    #expect(exists(fx.root.path + "/Library/Keychains/login.keychain-db"))
}

@Test func missingIsSkipped() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    let file = try fx.file("Projects/a.bin", bytes: 100_000)
    let store = try await scanned(fx)
    let id = try await node(store, fx, "Projects/a.bin")
    let before = await store.rootSize()
    #expect(unlink(file.path) == 0)

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([id], actions: actions, packages: noPackages, openFiles: nothingOpen)
    #expect(outcome.skipped == [TrashOutcome.Skipped(node: id, name: "a.bin", reason: .missing)])
    #expect(outcome.moved.isEmpty && actions.moved.isEmpty)
    #expect(await store.rootSize() == before)
}

@Test func replacedBySymlinkIsSkipped() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/old/f", bytes: 10_000)
    try fx.file("Projects/note.txt", bytes: 10_000)
    let target = try fx.file("Keep/target/t", bytes: 10_000)
    let store = try await scanned(fx)
    let old = try await node(store, fx, "Projects/old")
    let note = try await node(store, fx, "Projects/note.txt")
    try FileManager.default.removeItem(atPath: fx.root.path + "/Projects/old")
    try fx.symlink("Projects/old", to: fx.root.appendingPathComponent("Keep/target"))
    // A file that is now a folder changed too.
    #expect(unlink(fx.root.path + "/Projects/note.txt") == 0)
    try fx.dir("Projects/note.txt")

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([old, note], actions: actions, packages: noPackages, openFiles: nothingOpen)
    #expect(Set(outcome.skipped.map(\.reason)) == [.changed] && outcome.skipped.count == 2)
    #expect(outcome.moved.isEmpty && actions.moved.isEmpty)
    #expect(exists(target.path))
}

@Test func ancestorReplacedBySymlinkIsSkipped() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/sub/item/f", bytes: 10_000)
    try fx.dir("Keep")
    let store = try await scanned(fx)
    let item = try await node(store, fx, "Projects/sub/item")
    // `Projects/sub` now leads elsewhere: `Projects/sub/item` resolves to `Keep/sub2/item`.
    #expect(rename(fx.root.path + "/Projects/sub", fx.root.path + "/Keep/sub2") == 0)
    try fx.symlink("Projects/sub", to: fx.root.appendingPathComponent("Keep/sub2"))

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([item], actions: actions, packages: noPackages, openFiles: nothingOpen)
    #expect(outcome.skipped.map(\.reason) == [.changed])
    #expect(actions.moved.isEmpty && exists(fx.root.path + "/Keep/sub2/item/f"))
}

@Test func openFileIsSkipped() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    let doc = try fx.file("Projects/work/doc.txt", bytes: 10_000)
    let other = try fx.file("Other/open.log", bytes: 10_000)
    let store = try await scanned(fx)
    let work = try await node(store, fx, "Projects/work")
    let log = try await node(store, fx, "Other/open.log")
    let calls = CallCounter()

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([work, log], actions: actions, packages: noPackages, openFiles: {
        calls.tick()
        return OpenFileSet(paths: [doc.path, other.path])
    })
    #expect(Set(outcome.skipped.map(\.node)) == [work, log])
    #expect(outcome.skipped.allSatisfy { $0.reason == .openNow })
    #expect(outcome.moved.isEmpty && actions.moved.isEmpty)
    #expect(calls.value == 1)
}

@Test func incompleteOpenFileListMovesNothing() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/a", bytes: 10_000)
    try fx.file("Library/Caches/com.gone.x/a", bytes: 10_000)
    let store = try await scanned(fx)
    let a = try await node(store, fx, "Projects/a")
    let cache = try await node(store, fx, "Library/Caches/com.gone.x")

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([a, cache], actions: actions, packages: noPackages,
                                    openFiles: { OpenFileSet(paths: [], isComplete: false) })
    #expect(Set(outcome.skipped.map(\.node)) == [a, cache])
    #expect(outcome.skipped.allSatisfy { $0.reason == .cannotCheckOpenFiles })
    #expect(outcome.moved.isEmpty && actions.moved.isEmpty)
}

@Test func unlistedPackageAncestorBlocksTrash() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Weird.thing/inner/f", bytes: 10_000)
    let store = try await scanned(fx)
    let inner = try await node(store, fx, "Weird.thing/inner")

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([inner], actions: actions,
                                    packages: FakePackageProbe(packages: [fx.root.path + "/Weird.thing"]),
                                    openFiles: nothingOpen)
    #expect(outcome.skipped.map(\.reason) == [.insidePackage])
    #expect(outcome.moved.isEmpty && actions.moved.isEmpty)
}

@Test func removedNodeIsSkipped() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/old/deep/f", bytes: 10_000)
    let store = try await scanned(fx)
    let old = try await node(store, fx, "Projects/old")
    let deep = try await node(store, fx, "Projects/old/deep")

    let actions = RecordingDiskActions(trash: bin.root.path)
    let first = await store.trash([old], actions: actions, packages: noPackages, openFiles: nothingOpen)
    #expect(first.moved.map(\.node) == [old])
    let size = await store.rootSize()
    let second = await store.trash([old], actions: actions, packages: noPackages, openFiles: nothingOpen)
    #expect(second.skipped == [TrashOutcome.Skipped(node: old, name: "old", reason: .missing)])
    // A stale id below the removed folder is missing too.
    let third = await store.trash([deep], actions: actions, packages: noPackages, openFiles: nothingOpen)
    #expect(third.skipped.map(\.reason) == [.missing])
    #expect(actions.moved.count == 1)
    #expect(await store.rootSize() == size)
}

@Test func folderHoldingPhotosLibraryIsProtected() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/pics/X.photoslibrary/database/db", bytes: 10_000)
    let store = try await scanned(fx)
    let pics = try await node(store, fx, "Projects/pics")

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([pics], actions: actions, packages: noPackages, openFiles: nothingOpen)
    #expect(outcome.skipped.map(\.reason) == [.protected(.photosLibrary)])
    #expect(actions.moved.isEmpty)
}

@Test func folderHoldingRunningAppIsProtected() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Apps2/My.app/Contents/MacOS/bin", bytes: 10_000)
    try fx.file("Tools/Late/x", bytes: 10_000)
    // `Tools/Late/New.app` is not in the tree (appeared after the scan) but is running.
    let store = try await scanned(fx, runningAppPaths: [fx.root.path + "/Apps2/My.app",
                                                        fx.root.path + "/Tools/Late/New.app"])
    let apps = try await node(store, fx, "Apps2")
    let tools = try await node(store, fx, "Tools")

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([apps, tools], actions: actions, packages: noPackages, openFiles: nothingOpen)
    #expect(Set(outcome.skipped.map(\.node)) == [apps, tools])
    #expect(outcome.skipped.allSatisfy { $0.reason == .protected(.runningApp) })
    #expect(actions.moved.isEmpty)
}

@Test func failedMoveLeavesTreeAlone() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Projects/a", bytes: 10_000)
    let store = try await scanned(fx)
    let a = try await node(store, fx, "Projects/a")
    let before = await store.rootSize()

    let actions = RecordingDiskActions(trash: fx.root.path + "/no-such-trash")
    let outcome = await store.trash([a], actions: actions, packages: noPackages, openFiles: nothingOpen)
    let skipped = try #require(outcome.skipped.first)
    guard case .failed(let message) = skipped.reason else {
        Issue.record("expected .failed, got \(skipped.reason)")
        return
    }
    #expect(!message.isEmpty && outcome.moved.isEmpty)
    #expect(await store.rootSize() == before)
    #expect(await !store.row(a).flags.contains(.removed))
}

@Test func guardRefusals() {
    for p in ["relative/x", "", "/", "/Users", "/Users/u", "/Users/u/Library", "/Users/u/a/../b", "/Users/u//x",
              "/x", "/Users/u/./x", "/Users/u/x/", "/USERS/U/library", "/Users/u/Library/Caches",
              "/Users/u/Library/Mobile Documents", "/Users/u/Library/Mobile Documents/com~apple~CloudDocs",
              "/Users/u/Library/CloudStorage/Dropbox", "/Users/u/Documents", "/Applications"] {
        #expect(TrashGuard.refusal(path: p, home: "/Users/u") != nil, "\(p)")
    }
    for p in ["/Users/u/Downloads/a.dmg", "/Users/u/Library/Caches/com.gone.x",
              "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/report.pdf", "/Users/other/x"] {
        #expect(TrashGuard.refusal(path: p, home: "/Users/u") == nil, "\(p)")
    }
    #expect(TrashGuard.refusal(path: "/Users/u/Downloads/a.dmg", home: "/Users/u/") == nil)
    #expect(TrashGuard.refusal(path: "/Users/u/Library", home: "/Users/u/") != nil)
}
