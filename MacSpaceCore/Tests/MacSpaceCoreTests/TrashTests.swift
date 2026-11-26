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
    /// Adds tree flags, to simulate what the scan would have seen (a mount point).
    func addFlags(_ flags: NodeFlags, to id: NodeID) { tree.insertFlags(flags, for: id) }
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
    let size = try #require(await store.row(target)).size
    #expect(size >= 2_000_000)

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([target], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)

    #expect(actions.moved == [path])
    #expect(outcome.moved == [TrashOutcome.Moved(node: target, name: "com.gone.x", size: size,
                                                 trashedPath: bin.root.path + "/com.gone.x")])
    #expect(outcome.skipped.isEmpty)
    #expect(!exists(path) && exists(bin.root.path + "/com.gone.x/a"))
    #expect(await store.rootSize() == before - size)
    #expect(await store.row(target)?.flags.contains(.removed) == true)
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
    let outcome = await store.trash([folder, inner], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)

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
                                  packages: noPackages, openFiles: nothingOpen, expectedLevels: nil)
    #expect(first.moved.isEmpty)
    #expect(Dictionary(uniqueKeysWithValues: first.skipped.map { ($0.node, $0.reason) })
            == [library: .refused, inBundle: .protected(.insidePackage)])   // Caches is below Library

    let keychain = try await node(store, fx, "Library/Keychains/login.keychain-db")
    let photos = try await node(store, fx, "Pictures/Ph.photoslibrary")
    // A stale "safe" verdict in the cache must not matter: the store re-evaluates.
    await store.plantVerdict(SafetyVerdict(level: .safe, reason: .leftover), for: inBundle)
    let second = await store.trash([caches, keychain, photos, inBundle], actions: actions,
                                   packages: noPackages, openFiles: nothingOpen, expectedLevels: nil)
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
    let outcome = await store.trash([id], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
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
    let outcome = await store.trash([old, note], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
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
    let outcome = await store.trash([item], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
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
    }, expectedLevels: nil)
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
                                    openFiles: { OpenFileSet(paths: [], isComplete: false) }, expectedLevels: nil)
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
                                    openFiles: nothingOpen, expectedLevels: nil)
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
    let first = await store.trash([old], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                  expectedLevels: nil)
    #expect(first.moved.map(\.node) == [old])
    let size = await store.rootSize()
    let second = await store.trash([old], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                   expectedLevels: nil)
    #expect(second.skipped == [TrashOutcome.Skipped(node: old, name: "old", reason: .missing)])
    // A stale id below the removed folder is missing too.
    let third = await store.trash([deep], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                  expectedLevels: nil)
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
    let outcome = await store.trash([pics], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
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
    let outcome = await store.trash([apps, tools], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(Set(outcome.skipped.map(\.node)) == [apps, tools])
    #expect(outcome.skipped.allSatisfy { $0.reason == .containsProtected(.runningApp) })
    #expect(actions.moved.isEmpty)
}

@Test func failedMoveLeavesTreeAlone() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Projects/a", bytes: 10_000)
    let store = try await scanned(fx)
    let a = try await node(store, fx, "Projects/a")
    let before = await store.rootSize()

    let actions = RecordingDiskActions(trash: fx.root.path + "/no-such-trash")
    let outcome = await store.trash([a], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    let skipped = try #require(outcome.skipped.first)
    guard case .failed(let message) = skipped.reason else {
        Issue.record("expected .failed, got \(skipped.reason)")
        return
    }
    #expect(!message.isEmpty && outcome.moved.isEmpty)
    #expect(await store.rootSize() == before)
    #expect(await store.row(a)?.flags.contains(.removed) == false)
}

@Test func guardRefusals() {
    for p in ["relative/x", "", "/", "/Users", "/Users/u", "/Users/u/Library", "/Users/u/a/../b", "/Users/u//x",
              "/x", "/Users/u/./x", "/Users/u/x/", "/USERS/U/library", "/Users/u/Library/Caches",
              "/Users/u/Library/Mobile Documents", "/Users/u/Library/Mobile Documents/com~apple~CloudDocs",
              "/Users/u/Library/CloudStorage/Dropbox", "/Users/u/Documents", "/Applications",
              "/Volumes/USB", "/volumes/Backup", "/Users/Shared", "/Users/other"] {
        #expect(TrashGuard.refusal(path: p, home: "/Users/u") != nil, "\(p)")
    }
    for p in ["/Users/u/Downloads/a.dmg", "/Users/u/Library/Caches/com.gone.x",
              "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/report.pdf", "/Users/other/x",
              "/Volumes/USB/old.dmg", "/Users/Shared/x"] {
        #expect(TrashGuard.refusal(path: p, home: "/Users/u") == nil, "\(p)")
    }
    #expect(TrashGuard.refusal(path: "/Users/u/Downloads/a.dmg", home: "/Users/u/") == nil)
    #expect(TrashGuard.refusal(path: "/Users/u/Library", home: "/Users/u/") != nil)
}

@Test func guardRefusesNamesNotReadExactly() {   // security review: lossy UTF-8 decoding
    // A name the file system returned as invalid UTF-8 is decoded with U+FFFD, so the path may name
    // another item (or none): never moved.
    #expect(TrashGuard.refusal(path: "/Users/u/Downloads/caf\u{FFFD}.txt", home: "/Users/u") != nil)
    #expect(TrashGuard.refusal(path: "/Users/u/\u{FFFD}/a.txt", home: "/Users/u") != nil)
    #expect(TrashGuard.refusal(path: "/Users/u/Downloads/caf\u{E9}\nlinea.txt", home: "/Users/u") == nil)
}

@Test func noTrashWhileScanning() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a.bin", bytes: 10_000)
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: fixedNow)
    let boundary = try ScanBoundary.forFolder(fx.root.path)
    _ = await store.insert(try DirectoryReader.read(path: fx.root.path).entries, under: FileTree.root,
                           parentPath: fx.root.path, boundary: boundary)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    let id = try await node(store, fx, "a.bin")
    let calls = CallCounter()
    let actions = RecordingDiskActions(trash: bin.root.path)

    let during = await store.trash([id], actions: actions, packages: noPackages,
                                   openFiles: { calls.tick(); return OpenFileSet(paths: []) }, expectedLevels: nil)
    #expect(during.skipped == [TrashOutcome.Skipped(node: id, name: "a.bin", reason: .scanInProgress)])
    #expect(during.moved.isEmpty && actions.moved.isEmpty && calls.value == 0)

    await store.markScanFinished(allowedDevices: boundary.allowedDevices)
    let after = await store.trash([id], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                  expectedLevels: nil)
    #expect(after.moved.map(\.node) == [id])
}

@Test func insertUnderRemovedParentAddsNothing() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/old/f", bytes: 10_000)
    try fx.file("Projects/keep", bytes: 20_000)
    let store = try await scanned(fx)
    let old = try await node(store, fx, "Projects/old")
    let actions = RecordingDiskActions(trash: bin.root.path)
    _ = await store.trash([old], actions: actions, packages: noPackages, openFiles: nothingOpen, expectedLevels: nil)
    let size = await store.rootSize()
    let totals = await store.categoryTotals(of: FileTree.root)
    let ages = await store.ageTotals(of: FileTree.root)

    let late = [DirectoryEntry(name: "late.mov", kind: .file, allocatedSize: 5_000_000, device: 1, inode: 9,
                               linkCount: 1, isMountPoint: false, isDataless: false, modificationTime: fixedNow),
                DirectoryEntry(name: "sub", kind: .directory, allocatedSize: 0, device: 1, inode: 10,
                               linkCount: 1, isMountPoint: false, isDataless: false)]
    let inserted = await store.insert(late, under: old, parentPath: fx.root.path + "/Projects/old",
                                      boundary: ScanBoundary(allowedDevices: [1], excludedPaths: []))
    #expect(inserted.bytes == 0 && inserted.descend.isEmpty)
    #expect(await store.rootSize() == size)
    #expect(await store.categoryTotals(of: FileTree.root) == totals)
    #expect(await store.ageTotals(of: FileTree.root) == ages)
    #expect(await store.rows(childrenOf: old, limit: 10).map(\.name) == ["f"])
}

@Test func mountPointIsRefused() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Disks/usb/f", bytes: 10_000)
    let store = try await scanned(fx)
    let usb = try await node(store, fx, "Disks/usb")
    await store.addFlags(.mountPoint, to: usb)

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([usb], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(outcome.skipped.map(\.reason) == [.refused])
    #expect(actions.moved.isEmpty)
}

@Test func folderHoldingMountPointOrUnreadableFolderIsUnverified() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Disks/usb/f", bytes: 10_000)
    try fx.file("Locked/inside/f", bytes: 10_000)
    try fx.file("Partial/sub/f", bytes: 10_000)
    #expect(chmod(fx.root.path + "/Locked/inside", 0) == 0)
    let store = try await scanned(fx)
    let disks = try await node(store, fx, "Disks")
    let locked = try await node(store, fx, "Locked")
    let partial = try await node(store, fx, "Partial")
    let lockedInside = try await node(store, fx, "Locked/inside")
    #expect(await store.row(lockedInside)?.flags.contains(.unreadable) == true)
    await store.addFlags(.mountPoint, to: try node(store, fx, "Disks/usb"))
    // As if a cancelled scan never listed `Partial/sub`.
    await store.markScanFinished(allowedDevices: try ScanBoundary.forFolder(fx.root.path).allowedDevices,
                                 unverifiedDirectories: [try node(store, fx, "Partial/sub")])

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([disks, locked, partial, lockedInside], actions: actions,
                                    packages: noPackages, openFiles: nothingOpen, expectedLevels: nil)
    #expect(Set(outcome.skipped.map(\.node)) == [disks, locked, partial])   // lockedInside is below Locked
    #expect(outcome.skipped.allSatisfy { $0.reason == .containsUnverified })
    let alone = await store.trash([lockedInside], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                  expectedLevels: nil)
    #expect(alone.skipped.map(\.reason) == [.containsUnverified])   // its own contents are unknown
    #expect(actions.moved.isEmpty)
}

@Test func otherDeviceIsChanged() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/a", bytes: 10_000)
    let store = try await scanned(fx)
    let a = try await node(store, fx, "Projects/a")
    let real = try DirectoryReader.stat(path: fx.root.path + "/Projects/a")
    // The scan was confined to some other volume: the item is not where it was scanned.
    await store.markScanFinished(allowedDevices: [real.device &+ 1])

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([a], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(outcome.skipped.map(\.reason) == [.changed])
    #expect(actions.moved.isEmpty)
}

@Test func onDiskChangePredicate() {
    func entry(_ kind: NodeKind, device: Int32 = 7, mount: Bool = false) -> DirectoryEntry {
        DirectoryEntry(name: "x", kind: kind, allocatedSize: 0, device: device, inode: 1, linkCount: 1,
                       isMountPoint: mount, isDataless: false)
    }
    #expect(ScanStore.onDiskChange(entry(.directory), kind: .directory, devices: [7]) == nil)
    #expect(ScanStore.onDiskChange(entry(.file), kind: .file, devices: [3, 7]) == nil)
    #expect(ScanStore.onDiskChange(entry(.symlink), kind: .directory, devices: [7]) == .changed)
    #expect(ScanStore.onDiskChange(entry(.directory, mount: true), kind: .directory, devices: [7]) == .changed)
    #expect(ScanStore.onDiskChange(entry(.directory, device: 8), kind: .directory, devices: [7]) == .changed)
    #expect(ScanStore.onDiskChange(entry(.file), kind: .file, devices: []) == .changed)
}

@Test func onDiskChecksRunLast() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    let file = try fx.file("Projects/a.log", bytes: 10_000)
    let store = try await scanned(fx)
    let id = try await node(store, fx, "Projects/a.log")
    #expect(unlink(file.path) == 0)
    let actions = RecordingDiskActions(trash: bin.root.path)
    // Gone from disk and open: the open check comes first, the disk check right before the move.
    let outcome = await store.trash([id], actions: actions, packages: noPackages,
                                    openFiles: { OpenFileSet(paths: [file.path]) }, expectedLevels: nil)
    #expect(outcome.skipped.map(\.reason) == [.openNow])
}

@Test func folderHoldingTrashesIsProtected() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/disk/.Trashes/501/x", bytes: 10_000)
    let store = try await scanned(fx)
    let disk = try await node(store, fx, "Projects/disk")
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([disk], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.trash)])
    #expect(actions.moved.isEmpty)
}

@Test func packageAndReadOnlyFoldersInsideDoNotBlock() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/mixed/Foo.app/Contents/MacOS/foo", bytes: 10_000)
    try fx.file("Projects/mixed/ro/inner/f", bytes: 10_000)
    #expect(chmod(fx.root.path + "/Projects/mixed/ro", 0o555) == 0)
    let store = try await scanned(fx)
    let mixed = try await node(store, fx, "Projects/mixed")
    let inner = try await node(store, fx, "Projects/mixed/ro/inner")
    #expect(await store.verdict(inner)?.reason == .notWritable)

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([mixed], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(outcome.moved.map(\.node) == [mixed] && outcome.skipped.isEmpty)
    #expect(actions.moved == [fx.root.path + "/Projects/mixed"])
}

@Test func folderHoldingLiveMountIsUnverified() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Data/inner/f", bytes: 10_000)
    try fx.file("Spot/f", bytes: 10_000)
    try fx.file("Other/f", bytes: 10_000)
    let store = try await scanned(fx)
    let data = try await node(store, fx, "Data")
    let spot = try await node(store, fx, "Spot")
    let other = try await node(store, fx, "Other")
    let actions = RecordingDiskActions(trash: bin.root.path)
    // Mounted after the scan: one below `Data`, one exactly at `Spot` (trailing slash); `/` is ignored.
    let mounts = ["/", fx.root.path + "/Data/inner/mnt", fx.root.path + "/Spot/"]

    let outcome = await store.trash([data, spot, other], actions: actions, packages: noPackages,
                                    openFiles: nothingOpen, expectedLevels: nil, mountPoints: { mounts })
    #expect(Set(outcome.skipped.map(\.node)) == [data, spot])
    #expect(outcome.skipped.allSatisfy { $0.reason == .containsUnverified })
    #expect(outcome.moved.map(\.node) == [other])
    #expect(actions.moved == [fx.root.path + "/Other"])
}

@Test func unreadableMountTableMovesNothing() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("A/f", bytes: 10_000)
    try fx.file("B/f", bytes: 10_000)
    let store = try await scanned(fx)
    let a = try await node(store, fx, "A")
    let b = try await node(store, fx, "B")
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([a, b], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil, mountPoints: { nil })
    #expect(Set(outcome.skipped.map(\.node)) == [a, b])
    #expect(outcome.skipped.allSatisfy { $0.reason == .containsUnverified })
    #expect(actions.moved.isEmpty)
}

@Test func mountTableHelpers() throws {
    let live = try #require(MountTable.current())
    #expect(live.contains("/"))
    let canonical = MountTable.canonical(["/", "/Volumes/USB/", "/System/Volumes/Data/Users/u/mnt", "/tmp/m"])
    #expect(canonical == ["/Volumes/USB", "/System/Volumes/Data/Users/u/mnt", "/Users/u/mnt", "/private/tmp/m"])
    #expect(MountTable.hasMount(atOrBelow: "/Users/u", in: canonical))
    #expect(MountTable.hasMount(atOrBelow: "/Users/u/mnt", in: canonical))
    #expect(MountTable.hasMount(atOrBelow: "/tmp", in: canonical))           // /tmp is /private/tmp
    #expect(!MountTable.hasMount(atOrBelow: "/Users/u/mn", in: canonical))    // by component, not by prefix
    #expect(!MountTable.hasMount(atOrBelow: "/Users/u/mnt/x", in: canonical))
}

@Test func folderHoldingUndescendedFolderIsUnverified() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/skip/f", bytes: 10_000)
    try fx.file("Projects/other/f", bytes: 10_000)
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: fixedNow)
    var boundary = try ScanBoundary.forFolder(fx.root.path)
    boundary.excludedPaths = [fx.root.path + "/Projects/skip"]
    _ = await Scanner(rootPath: fx.root.path, boundary: boundary).scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    let projects = try await node(store, fx, "Projects")
    let skip = try await node(store, fx, "Projects/skip")
    let other = try await node(store, fx, "Projects/other")
    #expect(await store.unverifiedDirectories == [skip])

    let actions = RecordingDiskActions(trash: bin.root.path)
    let first = await store.trash([projects], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                  expectedLevels: nil)
    #expect(first.skipped.map(\.reason) == [.containsUnverified])
    let second = await store.trash([skip, other], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                   expectedLevels: nil)
    #expect(second.skipped == [TrashOutcome.Skipped(node: skip, name: "skip", reason: .containsUnverified)])
    #expect(second.moved.map(\.node) == [other])
    #expect(actions.moved == [fx.root.path + "/Projects/other"])
}

@Test func levelChangedSinceConfirmationIsSkipped() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/a.bin", bytes: 100_000)
    try fx.file("Projects/b.bin", bytes: 50_000)
    let store = try await scanned(fx)
    let a = try await node(store, fx, "Projects/a.bin")
    let b = try await node(store, fx, "Projects/b.bin")
    let levelA = try #require(await store.verdict(a)).level
    let levelB = try #require(await store.verdict(b)).level
    let other: SafetyLevel = levelB == .safe ? .caution : .safe

    // The user confirmed `a` at its current level and `b` at another one: only `a` moves.
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([a, b], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: [a: levelA, b: other])
    #expect(outcome.moved.map(\.node) == [a])
    #expect(outcome.skipped == [TrashOutcome.Skipped(node: b, name: "b.bin", reason: .verdictChanged)])
    #expect(actions.moved == [fx.root.path + "/Projects/a.bin"])

    // With a map, an item it has no level for was never confirmed: it fails closed.
    let rest = await store.trash([b], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                 expectedLevels: [:])
    #expect(rest.moved.isEmpty)
    #expect(rest.skipped == [TrashOutcome.Skipped(node: b, name: "b.bin", reason: .verdictChanged)])
    #expect(actions.moved == [fx.root.path + "/Projects/a.bin"])
}

@Test func confirmedLevelIsComparedWithAFreshVerdict() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Library/Caches/com.example.app/blob", bytes: 80_000)
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: fixedNow)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    let apps = AppsIndex(records: [AppRecord(bundleID: "com.example.app", name: "Example", teamID: nil,
                                             path: "/Applications/Example.app")])
    await store.setEnvironment(.system(home: fx.root.path, apps: apps))
    let id = try await node(store, fx, "Library/Caches/com.example.app")
    // What the user saw and confirmed: the cache of an app that is not running.
    let shown = try #require(await store.verdict(id))
    #expect(shown.level == .safe && shown.reason == .cacheOfApp)

    // The app launches before the move; the cache still holds the old verdict.
    await store.setEnvironment(.system(home: fx.root.path, apps: apps, runningBundleIDs: ["com.example.app"]))
    await store.plantVerdict(shown, for: id)

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([id], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: [id: shown.level])
    #expect(outcome.moved.isEmpty && actions.moved.isEmpty)
    #expect(outcome.skipped == [TrashOutcome.Skipped(node: id, name: "com.example.app", reason: .verdictChanged)])
}

@Test func nothingToMoveListsNoOpenFiles() async throws {   // final review minor
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/a", bytes: 10_000)
    let store = try await scanned(fx)
    let calls = CallCounter()
    let actions = RecordingDiskActions(trash: bin.root.path)
    // The root and IDs from no tree: nothing is left after `topMost`.
    let outcome = await store.trash([FileTree.root, 999_999], actions: actions, packages: noPackages,
                                    openFiles: { calls.tick(); return OpenFileSet(paths: []) }, expectedLevels: [:])
    #expect(outcome.moved.isEmpty && outcome.skipped.isEmpty)
    #expect(calls.value == 0)
}

@Test func trashJudgesAgainstTheEnvironmentHandedToIt() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Library/Application Support/com.example.app/data.db", bytes: 80_000)
    try fx.file("Projects/a.bin", bytes: 10_000)
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: fixedNow)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    let apps = AppsIndex(records: [AppRecord(bundleID: "com.example.app", name: "Example", teamID: nil,
                                             path: "/Applications/Example.app")])
    // The store holds an older environment, without the app running.
    await store.setEnvironment(.system(home: fx.root.path, apps: apps))
    let id = try await node(store, fx, "Library/Application Support/com.example.app")
    let other = try await node(store, fx, "Projects/a.bin")
    let shown = try #require(await store.verdict(id))
    #expect(shown == SafetyVerdict(level: .caution, reason: .appData, owner: "Example"))
    let otherLevel = try #require(await store.verdict(other)).level

    // The live environment, handed with the move: the app runs now, so its data is protected.
    let live = SafetyEnvironment.system(home: fx.root.path, apps: apps, runningBundleIDs: ["com.example.app"])
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([id, other], environment: live, actions: actions, packages: noPackages,
                                    openFiles: nothingOpen, expectedLevels: [id: shown.level, other: otherLevel])
    #expect(outcome.skipped == [TrashOutcome.Skipped(node: id, name: "com.example.app",
                                                     reason: .protected(.runningAppData))])
    #expect(outcome.moved.map(\.node) == [other])
    #expect(actions.moved == [fx.root.path + "/Projects/a.bin"])
    // The store keeps judging against the environment it was handed.
    #expect(await store.verdict(id) == SafetyVerdict(level: .protected, reason: .runningAppData, owner: "Example"))
}

@Test func folderWithAnIncompleteListingIsUnverified() async throws {   // audit SEC-02
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/partial/a", bytes: 10_000)
    try fx.file("Projects/whole/b", bytes: 10_000)
    let partialPath = fx.root.path + "/Projects/partial"
    // The file system left an entry of `partial` out (a per-entry error): the listing says so.
    let scanner = Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)) { path throws(DirectoryReadError) in
        var listing = try DirectoryReader.read(path: path)
        if path == partialPath { listing.isComplete = false }
        return listing
    }
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: fixedNow)
    _ = await scanner.scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    let projects = try await node(store, fx, "Projects")
    let partial = try await node(store, fx, "Projects/partial")
    let whole = try await node(store, fx, "Projects/whole")
    #expect(await store.unverifiedDirectories == [partial])

    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([partial], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(outcome.skipped == [TrashOutcome.Skipped(node: partial, name: "partial", reason: .containsUnverified)])
    let above = await store.trash([projects], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                  expectedLevels: nil)
    #expect(above.skipped.map(\.reason) == [.containsUnverified])
    #expect(outcome.moved.isEmpty && above.moved.isEmpty && actions.moved.isEmpty)
    // A sibling listed in full still moves.
    let sibling = await store.trash([whole], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(sibling.moved.map(\.node) == [whole])
}

@Test func datalessFolderAndItsParentAreUnverified() async throws {   // audit SEC-02
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("Projects/cloud/a", bytes: 10_000)
    try fx.file("Projects/local/b", bytes: 10_000)
    let projectsPath = fx.root.path + "/Projects"
    // `cloud` lives only in iCloud (SF_DATALESS): the scan never descends it, so it never sees `a`.
    let scanner = Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)) { path throws(DirectoryReadError) in
        var listing = try DirectoryReader.read(path: path)
        if path == projectsPath {
            listing.entries = listing.entries.map { e in
                e.name != "cloud" ? e : DirectoryEntry(
                    name: e.name, kind: e.kind, allocatedSize: e.allocatedSize, device: e.device, inode: e.inode,
                    linkCount: e.linkCount, isMountPoint: e.isMountPoint, isDataless: true,
                    modificationTime: e.modificationTime, accessTime: e.accessTime)
            }
        }
        return listing
    }
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: fixedNow)
    _ = await scanner.scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    let projects = try await node(store, fx, "Projects")
    let cloud = try await node(store, fx, "Projects/cloud")
    let local = try await node(store, fx, "Projects/local")
    #expect(await store.row(cloud)?.flags.contains(.dataless) == true)
    #expect(await store.node(atPath: fx.root.path + "/Projects/cloud/a") == nil)
    #expect(await store.unverifiedDirectories == [cloud])

    let actions = RecordingDiskActions(trash: bin.root.path)
    let itself = await store.trash([cloud], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                   expectedLevels: nil)
    #expect(itself.skipped == [TrashOutcome.Skipped(node: cloud, name: "cloud", reason: .containsUnverified)])
    let above = await store.trash([projects], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                  expectedLevels: nil)
    #expect(above.skipped == [TrashOutcome.Skipped(node: projects, name: "Projects", reason: .containsUnverified)])
    #expect(itself.moved.isEmpty && above.moved.isEmpty && actions.moved.isEmpty)
    let sibling = await store.trash([local], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedLevels: nil)
    #expect(sibling.moved.map(\.node) == [local])
}
