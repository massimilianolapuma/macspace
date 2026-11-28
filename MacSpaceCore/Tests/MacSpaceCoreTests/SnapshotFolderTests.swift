import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

/// `SnapshotFolder`: the startup disk's and the last folder's snapshots (#33, Task 5).
private func saved(_ target: SavedScan.Target) async throws -> SavedScan {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/f", bytes: 10)
    let store = try await scannedStore(fx)
    return await store.savedScan(target: target, startedAt: 123, hadFullDiskAccess: true)
}

private func files(_ url: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
}

@Test func saveThenLoad() async throws {
    let place = try Fixture(); defer { place.cleanup() }
    let folder = SnapshotFolder(url: place.root.appendingPathComponent("Snapshots"))
    try folder.save(try await saved(.startupDisk))
    try folder.save(try await saved(.folder(path: "/tmp/one")))
    #expect(folder.load(.startupDisk)?.target == .startupDisk)
    #expect(folder.load(.folder(path: "/tmp/one"))?.startedAt == 123)
    #expect(files(place.root.appendingPathComponent("Snapshots")) == ["startup-disk.snapshot", "folder.snapshot"])
    // Another folder replaces the last one.
    try folder.save(try await saved(.folder(path: "/tmp/two")))
    #expect(folder.load(.folder(path: "/tmp/two")) != nil)
    #expect(folder.load(.startupDisk) != nil)
}

@Test func loadDeletesInvalidAndForeign() async throws {   // Review Focus 2
    let place = try Fixture(); defer { place.cleanup() }
    let url = place.root.appendingPathComponent("Snapshots")
    let folder = SnapshotFolder(url: url)
    #expect(folder.load(.startupDisk) == nil)                       // missing
    try folder.save(try await saved(.folder(path: "/tmp/one")))
    #expect(folder.load(.folder(path: "/tmp/other")) == nil)        // another folder's
    #expect(!files(url).contains("folder.snapshot"))
    try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: url.appendingPathComponent("startup-disk.snapshot"))
    #expect(folder.load(.startupDisk) == nil)                       // random bytes
    #expect(!files(url).contains("startup-disk.snapshot"))
    try folder.save(try await saved(.folder(path: "/tmp/one")))
    folder.forgetFolder()
    #expect(folder.load(.folder(path: "/tmp/one")) == nil)
}

@Test func saveIsAtomic() async throws {
    let place = try Fixture(); defer { place.cleanup() }
    let url = place.root.appendingPathComponent("Snapshots")
    let folder = SnapshotFolder(url: url)
    try folder.save(try await saved(.startupDisk))
    try folder.save(try await saved(.startupDisk))
    #expect(files(url) == ["startup-disk.snapshot"])
}

@Test func standardFolderIsInTheAppsCaches() {
    #expect(SnapshotFolder.standard.url.path.hasSuffix("/Library/Caches/com.massilp.macspace/Snapshots"))
}
