import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

/// `trashPreview`: the checks `trash` runs (steps 1–8), without the move, for the Trash sheet to
/// show what will not move before the user confirms (#29).
private let nothingOpen: @Sendable () -> OpenFileSet = { OpenFileSet(paths: []) }
private let noPackages = FakePackageProbe(packages: [])

private func scanned(_ fx: Fixture, history: FakeChangeHistory) async throws -> ScanStore {
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: UInt32(time(nil)),
                          history: history)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    return store
}

private func node(_ store: ScanStore, _ fx: Fixture, _ rel: String) async throws -> NodeID {
    try #require(await store.node(atPath: fx.root.path + "/" + rel))
}

private func preview(_ store: ScanStore, _ ids: Set<NodeID>, openFiles: @escaping @Sendable () -> OpenFileSet = nothingOpen,
                     contentBudget: Duration = .seconds(10)) async -> [NodeID: TrashSkip] {
    await store.trashPreview(ids, packages: noPackages, openFiles: openFiles, expectedVerdicts: nil,
                             mountPoints: MountTable.current, contentBudget: contentBudget)
}

private func changed(_ fx: Fixture, _ rels: String...) -> FakeChangeHistory {
    FakeChangeHistory(answer: .folders(Set(rels.map { fx.root.path + "/" + $0 })))
}

@Test func previewBlocksContentAddedAfterScan() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a/sub"))
    try fx.file("a/sub/New.photoslibrary/x", bytes: 100)
    let a = try await node(store, fx, "a")
    #expect(await preview(store, [a]) == [a: .containsProtected(.photosLibrary)])
    let row = try #require(await store.row(a))
    #expect(!row.flags.contains(.removed))
}

@Test func previewGivesTrashReasons() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    for rel in ["clean/f", "open/f", "gone/f", "swapped/f"] { try fx.file(rel, bytes: 100) }
    let store = try await scanned(fx, history: changed(fx))
    let ids = [try await node(store, fx, "clean"), try await node(store, fx, "open"),
               try await node(store, fx, "gone"), try await node(store, fx, "swapped")]
    try FileManager.default.removeItem(atPath: fx.root.path + "/gone")
    try FileManager.default.removeItem(atPath: fx.root.path + "/swapped")
    try fx.file("swapped/f", bytes: 100)
    let openPath = fx.root.path + "/open/f"
    let openFiles: @Sendable () -> OpenFileSet = { OpenFileSet(paths: [openPath]) }

    let shown = await preview(store, Set(ids), openFiles: openFiles)
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash(Set(ids), actions: actions, packages: noPackages, openFiles: openFiles,
                                    expectedVerdicts: nil, mountPoints: MountTable.current)
    #expect(shown == Dictionary(uniqueKeysWithValues: outcome.skipped.map { ($0.node, $0.reason) }))
    #expect(shown.count == 3)
    #expect(shown[ids[0]] == nil)
    #expect(outcome.moved.map(\.node) == [ids[0]])
}

@Test func previewMovesNothing() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/f", bytes: 100)
    let store = try await scanned(fx, history: changed(fx))
    let a = try await node(store, fx, "a")
    let before = try #require(await store.row(FileTree.root)).size
    #expect(await preview(store, [a]) == [:])
    let row = try #require(await store.row(a))
    #expect(!row.flags.contains(.removed))
    #expect(try #require(await store.row(FileTree.root)).size == before)
    #expect(await store.node(atPath: fx.root.path + "/a/f") != nil)
}

@Test func trashAfterCleanPreviewStillChecks() async throws {   // Review Focus 5
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a/sub"))
    let a = try await node(store, fx, "a")
    #expect(await preview(store, [a]) == [:])
    try fx.file("a/sub/New.photoslibrary/x", bytes: 100)
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([a], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedVerdicts: nil, mountPoints: MountTable.current)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
    #expect(actions.moved.isEmpty)
}

@Test func previewIncompleteOpenFilesBlocksAll() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/f", bytes: 100)
    try fx.file("b/f", bytes: 100)
    let store = try await scanned(fx, history: changed(fx))
    let a = try await node(store, fx, "a"), b = try await node(store, fx, "b")
    let shown = await preview(store, [a, b], openFiles: { OpenFileSet(paths: [], isComplete: false) })
    #expect(shown == [a: .cannotCheckOpenFiles, b: .cannotCheckOpenFiles])
}

@Test func previewBudgetExhaustedIsUnverified() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/f", bytes: 100)
    let store = try await scanned(fx, history: FakeChangeHistory(answer: .untrusted))
    let a = try await node(store, fx, "a")
    #expect(await preview(store, [a], contentBudget: .zero) == [a: .containsUnverified])
}
