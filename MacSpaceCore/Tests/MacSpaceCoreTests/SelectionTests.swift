import Foundation
import Testing
@testable import MacSpaceCore

private let fixedNow = UInt32(time(nil))

/// Scans `fx` as a home folder, then judges against an empty apps index.
private func scanned(_ fx: Fixture) async throws -> ScanStore {
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: fixedNow)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    return store
}

private func node(_ store: ScanStore, _ fx: Fixture, _ rel: String) async throws -> NodeID {
    try #require(await store.node(atPath: fx.root.path + "/" + rel))
}

/// Every query the UI sends a node ID to answers "nothing" for an ID that is not in the tree (kept
/// from an earlier scan's store) instead of trapping.
@Test func foreignNodeIDsAreSafeForEveryQuery() async throws {
    let store = ScanStore(rootName: "r", rootPath: "/tmp/macspace-foreign-ids")
    await store.markScanFinished()
    for id: NodeID in [-1, 1, 5_000, NodeID.max] {
        #expect(await store.row(id) == nil)
        #expect(await store.rows(childrenOf: id, limit: 5).isEmpty)
        #expect(await store.breadcrumb(to: id).isEmpty)
        #expect(await store.path(of: id) == nil)
        #expect(await store.verdict(id) == nil)
        #expect(await store.commonFolder(of: [id]) == nil)
    }
    #expect(await store.row(FileTree.root)?.name == "r")
    #expect(await store.path(of: FileTree.root) == "/tmp/macspace-foreign-ids")
    #expect(await store.verdict(FileTree.root) != nil)
    let none = await store.resolveSelection([-1, 1, 5_000, FileTree.root])
    #expect(none.ids.isEmpty && none.total == 0)
}

/// The selection keeps only what may be moved on its own: not the root, nothing protected, nothing
/// inside another selected folder, nothing stale; its total counts each byte once.
@Test func resolvedSelectionIsTopMostAndNeverProtected() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("A/big", bytes: 300_000)
    try fx.file("A/inner/f", bytes: 40_000)
    try fx.file("B/small", bytes: 20_000)
    try fx.file("Library/Keychains/login.keychain-db", bytes: 10_000)
    try fx.file("Foo.app/Contents/Resources/x", bytes: 10_000)
    let store = try await scanned(fx)
    let a = try await node(store, fx, "A")
    let inner = try await node(store, fx, "A/inner")
    let file = try await node(store, fx, "A/inner/f")
    let b = try await node(store, fx, "B")
    let keychains = try await node(store, fx, "Library/Keychains")
    let inBundle = try await node(store, fx, "Foo.app/Contents/Resources/x")
    #expect(await store.verdict(keychains)?.level == .protected)
    #expect(await store.verdict(inBundle)?.level == .protected)

    // Selecting a folder drops what was selected inside it.
    let folder = await store.resolveSelection([inner, file, b, a])
    #expect(folder.ids == [a, b])
    let sizeA = try #require(await store.row(a)).size, sizeB = try #require(await store.row(b)).size
    #expect(folder.total == sizeA + sizeB)

    // Something inside a selected folder adds nothing.
    let nested = await store.resolveSelection([a, file])
    #expect(nested.ids == [a] && nested.total == sizeA)

    // The root, protected items and stale IDs never stay selected.
    let refused = await store.resolveSelection([FileTree.root, keychains, inBundle, -3, 9_999_999, b])
    #expect(refused.ids == [b] && refused.total == sizeB)
}

/// The deepest folder holding every item, strictly above each: where they all show at once.
@Test func commonFolderIsTheDeepestFolderAboveEveryItem() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Library/Caches/x/a", bytes: 1_000)
    try fx.file("Library/Caches/y/b", bytes: 1_000)
    try fx.file("Library/Logs/z", bytes: 1_000)
    let store = try await scanned(fx)
    let library = try await node(store, fx, "Library")
    let caches = try await node(store, fx, "Library/Caches")
    let x = try await node(store, fx, "Library/Caches/x")
    let y = try await node(store, fx, "Library/Caches/y")
    let a = try await node(store, fx, "Library/Caches/x/a")
    let z = try await node(store, fx, "Library/Logs/z")
    #expect(await store.commonFolder(of: [x]) == caches)
    #expect(await store.commonFolder(of: [x, y]) == caches)
    #expect(await store.commonFolder(of: [x, a]) == caches)
    #expect(await store.commonFolder(of: [x, z]) == library)
    #expect(await store.commonFolder(of: [library]) == FileTree.root)
    #expect(await store.commonFolder(of: [x, -1]) == caches)
    #expect(await store.commonFolder(of: []) == nil)
    #expect(await store.commonFolder(of: [FileTree.root]) == nil)
}

/// A protected folder in the request never hides what may be selected inside it: protected items
/// go first, then the top-most rule applies to what is left.
@Test func protectedFolderDoesNotHideSelectableItemsInside() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Library/Caches/com.gone.x/a", bytes: 2_000_000)
    let store = try await scanned(fx)
    let library = try await node(store, fx, "Library")
    let cache = try await node(store, fx, "Library/Caches/com.gone.x")
    #expect(await store.verdict(library)?.level == .protected)
    #expect(await store.verdict(cache)?.level == .safe)
    let resolved = await store.resolveSelection([library, cache])
    #expect(resolved.ids == [cache])
    #expect(resolved.total == (try #require(await store.row(cache))).size)
}
