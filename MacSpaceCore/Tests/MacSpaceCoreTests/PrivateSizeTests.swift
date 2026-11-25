import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

@Test func cloneFreesNothing() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let a = try fx.file("a.bin", bytes: 1_000_000)
    #expect(clonefile(a.path, fx.root.path + "/b.bin", 0) == 0)
    #expect(PrivateSize.freed(path: fx.root.path + "/b.bin") < 100_000)
    // Removing both would free the shared blocks, but each clone's private size is ~0, so the
    // directory sum is ~0 too: the estimate is a lower bound when clones are moved together.
    #expect(PrivateSize.freed(path: fx.root.path) < 100_000)
    #expect(try DirectoryReader.stat(path: a.path).allocatedSize >= 1_000_000)
}

@Test func hardLinkFreesNothing() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let a = try fx.file("a.bin", bytes: 100_000); try fx.hardLink("b.bin", to: a)
    #expect(PrivateSize.freed(path: a.path) == 0)
}

@Test func plainFileAndDirectoryFreeTheirBlocks() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("d/sub/a.bin", bytes: 200_000)
    try fx.file("d/b.bin", bytes: 100_000)
    try fx.symlink("d/link", to: f)
    try fx.symlink("outside", to: fx.root.appending(path: "d"))
    let fileFreed = PrivateSize.freed(path: f.path)
    #expect(fileFreed >= 200_000 && fileFreed < 300_000)
    let dirFreed = PrivateSize.freed(path: fx.root.path + "/d")
    #expect(dirFreed >= 300_000 && dirFreed < 400_000)
    // A symlink frees only itself, never its target.
    #expect(PrivateSize.freed(path: fx.root.path + "/outside") < 100_000)
    #expect(PrivateSize.freed(path: fx.root.path + "/missing") == 0)
}

@Test func unreadableSubdirectoryIsSkipped() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("d/a.bin", bytes: 100_000)
    try fx.file("d/locked/b.bin", bytes: 500_000)
    chmod(fx.root.path + "/d/locked", 0)
    let freed = PrivateSize.freed(path: fx.root.path + "/d")
    #expect(freed >= 100_000 && freed < 500_000)
}

@Test func cancelledWalkStopsEarly() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    for i in 0..<5 { try fx.file("d\(i)/a.bin", bytes: 100_000) }
    let freed = await Task { withUnsafeCurrentTask { $0?.cancel() }; return PrivateSize.freed(path: fx.root.path) }.value
    #expect(freed < 100_000)
}
