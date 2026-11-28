import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

/// Contents added after the scan (S4): `trash` re-reads what the history says changed, or
/// everything when it cannot say, and judges what is new with the scan's rules.
private let nothingOpen: @Sendable () -> OpenFileSet = { OpenFileSet(paths: []) }
private let noPackages = FakePackageProbe(packages: [])

private func scanned(_ fx: Fixture, history: FakeChangeHistory,
                     runningAppPaths: Set<String> = []) async throws -> ScanStore {
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, now: UInt32(time(nil)),
                          history: history)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty, runningAppPaths: runningAppPaths))
    return store
}

/// Trashes `fx/a` and returns the outcome and what was moved.
private func trashA(_ store: ScanStore, _ fx: Fixture, _ bin: Fixture,
                    contentBudget: Duration = .seconds(10)) async throws -> (TrashOutcome, [String]) {
    let a = try #require(await store.node(atPath: fx.root.path + "/a"))
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([a], actions: actions, packages: noPackages, openFiles: nothingOpen,
                                    expectedVerdicts: nil, mountPoints: MountTable.current,
                                    contentBudget: contentBudget)
    return (outcome, actions.moved)
}

private func changed(_ fx: Fixture, _ rels: String...) -> FakeChangeHistory {
    FakeChangeHistory(answer: .folders(Set(rels.map { fx.root.path + "/" + $0 })))
}

@Test func newPhotosLibraryInsideIsProtected() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a/sub"))
    try fx.file("a/sub/New.photoslibrary/database/x", bytes: 100)
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
    #expect(moved.isEmpty)
}

@Test func newTrashesFolderIsProtected() async throws {   // Review Focus 3: the item itself changed
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/old.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a"))
    try fx.file("a/.Trashes/x", bytes: 100)
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.trash)])
    #expect(moved.isEmpty)
}

@Test func newPlainFilesMove() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a/sub"))
    try fx.file("a/sub/new.txt", bytes: 100)
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.isEmpty)
    #expect(moved == [fx.root.path + "/a"])
    #expect(FileManager.default.fileExists(atPath: bin.root.path + "/a/sub/new.txt"))
}

@Test func newRunningAppIsProtected() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/old.txt", bytes: 100)
    let app = fx.root.path + "/a/Tool.app"
    let store = try await scanned(fx, history: changed(fx, "a"), runningAppPaths: [app])
    try fx.plist("a/Tool.app/Contents/Info.plist", ["CFBundleIdentifier": "com.example.tool"])
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.runningApp)])
    #expect(moved.isEmpty)
}

@Test func unlistableChangedFolderIsUnverified() async throws {   // Review Focus 2
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a/sub"))
    let sub = fx.root.path + "/a/sub"
    #expect(chmod(sub, 0) == 0)
    defer { chmod(sub, 0o755) }
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.map(\.reason) == [.containsUnverified])
    #expect(moved.isEmpty)
}

@Test func goneChangedFolderIsFine() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    try fx.file("a/keep.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a/sub", "a"))
    try FileManager.default.removeItem(atPath: fx.root.path + "/a/sub")
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.isEmpty)
    #expect(moved == [fx.root.path + "/a"])
}

@Test func untrustedWalksEverything() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/deep/er/old.txt", bytes: 100)
    let store = try await scanned(fx, history: FakeChangeHistory(answer: .untrusted))
    try fx.file("a/deep/er/New.photoslibrary/x", bytes: 100)
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
    #expect(moved.isEmpty)
}

@Test func noBaselineWalksEverything() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/deep/er/old.txt", bytes: 100)
    // A history that reports nothing changed, but had no baseline to compare with.
    let store = try await scanned(fx, history: FakeChangeHistory(start: nil, answer: .folders([])))
    try fx.file("a/deep/er/New.photoslibrary/x", bytes: 100)
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
    #expect(moved.isEmpty)
}

@Test func budgetExhaustedIsUnverified() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/old.txt", bytes: 100)
    let store = try await scanned(fx, history: FakeChangeHistory(answer: .untrusted))
    let (outcome, moved) = try await trashA(store, fx, bin, contentBudget: .zero)
    #expect(outcome.skipped.map(\.reason) == [.containsUnverified])
    #expect(moved.isEmpty)
}

@Test func replacedEntryIsNewContent() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a"))
    // Same name, another folder (new inode): only `a`'s listing changed, `sub` must be read whole.
    try FileManager.default.removeItem(atPath: fx.root.path + "/a/sub")
    try fx.file("a/sub/Old.photoslibrary/x", bytes: 100)
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
    #expect(moved.isEmpty)
}

/// A changed folder the history spells with other bytes than the tree (case here) is not in the
/// tree as spelled: it is judged from disk, not skipped (fail closed).
@Test func changedFolderSpelledOtherwiseIsJudged() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let store = try await scanned(fx, history: changed(fx, "a/SUB"))
    try fx.file("a/sub/New.photoslibrary/x", bytes: 100)
    let (outcome, moved) = try await trashA(store, fx, bin)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
    #expect(moved.isEmpty)
}
