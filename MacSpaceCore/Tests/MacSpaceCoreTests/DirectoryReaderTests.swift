import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

@Test func readsFilesWithAllocatedSize() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("a.bin", bytes: 10_000)
    try fx.dir("sub")
    let listing = try DirectoryReader.read(path: fx.root.path)
    #expect(listing.isComplete)
    let entries = listing.entries
    let a = try #require(entries.first { $0.name == "a.bin" })
    let expected = try #require(try f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
    #expect(a.kind == .file && a.allocatedSize == UInt64(expected))
    #expect(entries.first { $0.name == "sub" }?.kind == .directory)
}
@Test func symlinkIsNotFollowed() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let big = try fx.file("big.bin", bytes: 1_000_000)
    try fx.symlink("link", to: big)
    let link = try #require(try DirectoryReader.read(path: fx.root.path).entries.first { $0.name == "link" })
    #expect(link.kind == .symlink && link.allocatedSize < 1_000_000)
}
@Test func hardLinksShareInode() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("x", bytes: 5000); try fx.hardLink("y", to: f)
    let e = try DirectoryReader.read(path: fx.root.path).entries
    let x = try #require(e.first { $0.name == "x" }), y = try #require(e.first { $0.name == "y" })
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
    let got = Set(try DirectoryReader.read(path: fx.root.path).entries.map(\.name))
    for n in names { #expect(got.contains { $0.precomposedStringWithCanonicalMapping == n.precomposedStringWithCanonicalMapping }) }
}
@Test func manyEntriesBeyondOneBuffer() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    for i in 0..<5000 { try fx.file("f\(i)", bytes: 1) }
    let listing = try DirectoryReader.read(path: fx.root.path)
    #expect(listing.entries.count == 5000 && listing.isComplete)
}

@Test func readsTimestamps() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("t.bin", bytes: 10)
    let past = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: f.path)
    let e = try #require(try DirectoryReader.read(path: fx.root.path).entries.first { $0.name == "t.bin" })
    #expect(e.modificationTime == 1_600_000_000)
    #expect(e.accessTime > 0)
}

@Test func statDescribesFileDirAndSymlink() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("f", bytes: 5000); let d = try fx.dir("d"); try fx.symlink("l", to: d)
    #expect(try DirectoryReader.stat(path: f.path).kind == .file)
    #expect(try DirectoryReader.stat(path: d.path).kind == .directory)
    #expect(try DirectoryReader.stat(path: fx.root.appending(path: "l").path).kind == .symlink)
}

@Test func statReportsTimestamps() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("f", bytes: 1)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: f.path)
    let e = try DirectoryReader.stat(path: f.path)
    #expect(e.modificationTime == 1_600_000_000)
    #expect(e.accessTime > 0)
}

@Test func errnoMapping() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("f", bytes: 1)
    #expect(throws: DirectoryReadError.notFound) { try DirectoryReader.read(path: fx.root.path + "/missing") }
    #expect(throws: DirectoryReadError.notADirectory) { try DirectoryReader.read(path: f.path) }
}

@Test func preCancelledReadReturnsNothing() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    for i in 0..<10 { try fx.file("f\(i)", bytes: 1) }
    // Checks the cancellation check that runs before each batch (here, before the first).
    let listing = try await Task { withUnsafeCurrentTask { $0?.cancel() }; return try DirectoryReader.read(path: fx.root.path) }.value
    #expect(listing.entries.isEmpty && !listing.isComplete)
}

@Test func privateSizeReadIsOptIn() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("x", bytes: 10_000)
    #expect(try DirectoryReader.read(path: fx.root.path).entries.allSatisfy { $0.privateSize == nil })
    #expect(try DirectoryReader.read(path: fx.root.path, includePrivateSize: true).entries.first?.privateSize ?? 0 > 0)
}

// MARK: - Batch parsing (synthetic getattrlistbulk records)

/// One packed record as `getattrlistbulk` returns it for `ATTR_CMN_ERROR | NAME | OBJTYPE`:
/// length, returned set, error, name reference, object type, then the NUL-terminated name,
/// padded to 4 bytes. `length` overrides the length field (0, or past the buffer's end).
private func packedRecord(_ name: String, error: UInt32 = 0, length: UInt32? = nil) -> [UInt8] {
    var bytes: [UInt8] = []
    func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
    let nameBytes = Array(name.utf8) + [0]
    let fixed = 4 + 20 + 4 + 8 + 4   // length, attribute_set_t, error, attrreference_t, objtype
    let total = (fixed + nameBytes.count + 3) & ~3
    put(length ?? UInt32(total))
    put(attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE))
    for _ in 0..<4 { put(0) }       // volattr, dirattr, fileattr, forkattr
    put(error)
    put(12)                         // attr_dataoffset: from the reference (offset 28) to the name (40)
    put(UInt32(nameBytes.count))    // attr_length, NUL included
    put(UInt32(VREG.rawValue))
    bytes += nameBytes
    bytes += [UInt8](repeating: 0, count: total - bytes.count)
    return bytes
}

private func parse(_ records: [[UInt8]], count: Int, padding: Int = 64) -> (entries: [DirectoryEntry], complete: Bool) {
    let buffer = records.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
    return buffer.withUnsafeBytes { DirectoryReader.parseBatch($0, count: count) }
}

@Test func wellFormedBatchIsComplete() {
    let batch = parse([packedRecord("a"), packedRecord("bb")], count: 2)
    #expect(batch.entries.map(\.name) == ["a", "bb"] && batch.complete)
    #expect(batch.entries.allSatisfy { $0.kind == .file })
}

@Test func recordWithAnErrorMakesTheBatchIncomplete() {
    let batch = parse([packedRecord("a"), packedRecord("bad", error: UInt32(EACCES)), packedRecord("c")], count: 3)
    #expect(batch.entries.map(\.name) == ["a", "c"])
    #expect(!batch.complete)
}

@Test func zeroOrOversizedLengthStopsTheBatchIncomplete() {
    let zero = parse([packedRecord("a"), packedRecord("b", length: 0), packedRecord("c")], count: 3)
    #expect(zero.entries.map(\.name) == ["a"] && !zero.complete)
    let past = parse([packedRecord("a"), packedRecord("b", length: 10_000)], count: 2)
    #expect(past.entries.map(\.name) == ["a"] && !past.complete)
    // The call said three records but the buffer holds two, then zeros.
    let short = parse([packedRecord("a"), packedRecord("b")], count: 3)
    #expect(short.entries.map(\.name) == ["a", "b"] && !short.complete)
}

@Test func malformedRecordMakesTheBatchIncomplete() {
    // A length too small for the attributes the record says it holds.
    var cut = packedRecord("abc")
    cut.replaceSubrange(0..<4, with: [24, 0, 0, 0])
    let batch = parse([packedRecord("a"), Array(cut.prefix(24)), packedRecord("c")], count: 3)
    #expect(batch.entries.map(\.name) == ["a", "c"] && !batch.complete)
}
