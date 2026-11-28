import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

/// `SavedScan`'s binary format (#33, Task 2).
private func saved(_ fx: Fixture) async throws -> SavedScan {
    let store = try await scannedStore(fx, partial: ["part"])
    return await store.savedScan(target: .folder(path: fx.root.path), startedAt: 1_700_000_000, hadFullDiskAccess: true)
}

@Test func codingRoundTrips() async throws {
    let fx = try richFixture(); defer { fx.cleanup() }
    var original = try await saved(fx)
    original.baseline = ChangeBaseline(eventID: 42, deviceUUIDs: [7: "UUID-7", -3: "UUID-minus"])
    let decoded = try SavedScan(decoding: original.encoded())
    #expect(decoded.target == original.target)
    #expect(decoded.rootPath == original.rootPath && decoded.rootInode == original.rootInode)
    #expect(decoded.rootDevice == original.rootDevice)
    #expect(decoded.startedAt == 1_700_000_000 && decoded.hadFullDiskAccess)
    #expect(decoded.baseline == original.baseline)
    let now = UInt32(time(nil))
    let a = ScanStore(saved: original, home: fx.root.path, now: now, history: FakeChangeHistory())
    let b = ScanStore(saved: decoded, home: fx.root.path, now: now, history: FakeChangeHistory())
    #expect(await a.factsByPath() == b.factsByPath())
    #expect(await a.unverifiedPaths() == b.unverifiedPaths())
    #expect(await a.hardLinkPaths() == b.hardLinkPaths())
    #expect(await a.installerCount() == b.installerCount())
    #expect(await a.device(ofDirectory: FileTree.root) == b.device(ofDirectory: FileTree.root))
    // The startup disk target, and no baseline, round trip too.
    original.target = .startupDisk
    original.baseline = nil
    let disk = try SavedScan(decoding: original.encoded())
    #expect(disk.target == .startupDisk && disk.baseline == nil)
}

@Test func decodingRejectsDamage() async throws {
    let fx = try richFixture(); defer { fx.cleanup() }
    let original = try await saved(fx)
    let data = original.encoded()
    func error(_ bytes: Data) -> SavedScanError? {
        do { _ = try SavedScan(decoding: bytes); return nil } catch { return error }
    }
    #expect(error(Data()) == .notASnapshot)
    var magic = data
    magic[0] ^= 0xFF
    #expect(error(magic) == .notASnapshot)
    var version = data
    version.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(2).littleEndian) { Data($0) })
    #expect(error(version) == .unsupportedVersion(2))
    var flipped = data
    flipped[data.count / 2] ^= 0x01
    #expect(error(flipped) == .damaged)
    for cut in stride(from: 1, to: data.count, by: max(1, data.count / 10)) {
        let e = error(data.prefix(cut))
        #expect(e == .damaged || e == .notASnapshot, "cut at \(cut)")
    }
    // A consistent checksum over an inconsistent body: the structural checks catch it.
    var broken = original
    broken.tree.parents[1] = 5
    #expect(error(broken.encoded()) == .damaged)
    var cycle = original
    cycle.tree.nextSiblings[1] = 1
    #expect(error(cycle.encoded()) == .damaged)
    var badKind = original
    badKind.tree.kinds = ContiguousArray(badKind.tree.kinds.indices.map { _ in NodeKind.file })
    #expect(error(badKind.encoded()) == .damaged)  // the root (and every directory) must own a slot
    var names = original
    names.tree.nameEnds[names.tree.nameEnds.count - 1] += 1
    #expect(error(names.encoded()) == .damaged)
    var link = original
    link.hardLinks[0].links.append(NodeID(link.tree.count + 10))
    #expect(error(link.encoded()) == .damaged)
}

/// Saving streams the format to the file, with no copy of it in memory: the file holds exactly
/// `encoded()`'s bytes, and decodes back.
@Test func writingStreamsTheSameBytes() async throws {
    let fx = try richFixture(); defer { fx.cleanup() }
    let place = try Fixture(); defer { place.cleanup() }
    var original = try await saved(fx)
    original.baseline = ChangeBaseline(eventID: 9, deviceUUIDs: [1: "U"])
    let file = place.root.appendingPathComponent("s.snapshot")
    try original.write(to: file)
    let bytes = try Data(contentsOf: file)
    #expect(bytes == original.encoded())
    #expect(try SavedScan(decoding: bytes).rootPath == original.rootPath)
}
