import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

@Test func readsFilesWithAllocatedSize() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("a.bin", bytes: 10_000)
    try fx.dir("sub")
    let entries = try DirectoryReader.read(path: fx.root.path)
    let a = try #require(entries.first { $0.name == "a.bin" })
    let expected = try f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize!
    #expect(a.kind == .file && a.allocatedSize == UInt64(expected))
    #expect(entries.first { $0.name == "sub" }?.kind == .directory)
}
@Test func symlinkIsNotFollowed() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let big = try fx.file("big.bin", bytes: 1_000_000)
    try fx.symlink("link", to: big)
    let link = try #require(try DirectoryReader.read(path: fx.root.path).first { $0.name == "link" })
    #expect(link.kind == .symlink && link.allocatedSize < 1_000_000)
}
@Test func hardLinksShareInode() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("x", bytes: 5000); try fx.hardLink("y", to: f)
    let e = try DirectoryReader.read(path: fx.root.path)
    let x = e.first { $0.name == "x" }!, y = e.first { $0.name == "y" }!
    #expect(x.inode == y.inode && x.linkCount == 2)
}
@Test func permissionDeniedThrows() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let d = try fx.dir("locked"); chmod(d.path, 0)
    #expect(throws: DirectoryReadError.permissionDenied) { try DirectoryReader.read(path: d.path) }
}
@Test func oddNamesRoundTrip() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let names = ["📦 pacco", "Caf\u{0065}\u{0301}", "line\nbreak", String(repeating: "x", count: 255)]
    for n in names { try fx.file(n, bytes: 1) }
    let got = Set(try DirectoryReader.read(path: fx.root.path).map(\.name))
    for n in names { #expect(got.contains { $0.precomposedStringWithCanonicalMapping == n.precomposedStringWithCanonicalMapping }) }
}
@Test func manyEntriesBeyondOneBuffer() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    for i in 0..<5000 { try fx.file("f\(i)", bytes: 1) }
    #expect(try DirectoryReader.read(path: fx.root.path).count == 5000)
}
