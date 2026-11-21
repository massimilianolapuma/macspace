import Testing
@testable import MacSpaceCore

private let now: UInt32 = 1_800_000_000
private let day: UInt32 = 86_400

@Test func folderTakesTheBucketHoldingMostBytes() {
    let t = FileTree(rootName: "r", rootPath: "/r", now: now)
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "old.bin", kind: .file, allocatedSize: 90, lastUsed: now - 900 * day)
    t.addChild(of: d, name: "touched.txt", kind: .file, allocatedSize: 10, lastUsed: now - 60)
    #expect(t.dominantAgeBucket(d) == .older)
    #expect(t.lastUsed(d) == now - 60)  // the latest use stays available for the tooltip
    #expect(t.ageTotals(d) == [.older: 90, .lastMonth: 10])
    #expect(t.ageTotals(d).values.reduce(0, +) == t.size(d))
    #expect(t.row(d).ageBucket == .older && t.row(d).lastUsed == now - 60)
}

@Test func ageTotalsSumToTheSizeUpTheTree() {
    let t = FileTree(rootName: "r", rootPath: "/r", now: now)
    let a = t.addChild(of: 0, name: "a", kind: .directory, allocatedSize: 4)  // own size: unknown use
    let b = t.addChild(of: a, name: "b", kind: .directory, allocatedSize: 0)
    t.addChild(of: b, name: "x", kind: .file, allocatedSize: 7, lastUsed: now - 100 * day)
    t.addChild(of: a, name: "y", kind: .file, allocatedSize: 5, lastUsed: now - 300 * day)
    t.addChild(of: 0, name: "z", kind: .file, allocatedSize: 3)  // never used: unknown
    for id in [FileTree.root, a, b] {
        #expect(t.ageTotals(id).values.reduce(0, +) == t.size(id))
    }
    #expect(t.ageTotals(0) == [.unknown: 7, .lastSixMonths: 7, .lastYear: 5])
}

@Test func ageTiesGoToTheMoreRecentBucketAndEmptyIsUnknown() {
    let t = FileTree(rootName: "r", rootPath: "/r", now: now)
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "old", kind: .file, allocatedSize: 50, lastUsed: now - 500 * day)
    t.addChild(of: d, name: "new", kind: .file, allocatedSize: 50, lastUsed: now - 200 * day)
    #expect(t.dominantAgeBucket(d) == .lastYear)
    let empty = t.addChild(of: 0, name: "e", kind: .directory, allocatedSize: 0)
    #expect(t.dominantAgeBucket(empty) == .unknown && t.ageTotals(empty).isEmpty)
    let file = t.addChild(of: 0, name: "f", kind: .file, allocatedSize: 0, lastUsed: now - 40 * day)
    #expect(t.dominantAgeBucket(file) == .lastSixMonths)  // a file: its own bucket, even when empty
}

/// 100 tiny siblings merge into "altri": 70 old bytes, 30 recent ones.
private func treeWithMergedSiblings() -> FileTree {
    let t = FileTree(rootName: "r", rootPath: "/r", now: now)
    t.addChild(of: 0, name: "big", kind: .file, allocatedSize: 1_000_000_000, lastUsed: now)
    for i in 0..<100 {
        let old = i < 70
        t.addChild(of: 0, name: "s\(i)", kind: .file, allocatedSize: 1, lastUsed: old ? now - 1_000 * day : now - day)
    }
    return t
}

@Test func mergedSunburstOtherTakesTheDominantBucketOfItsBytes() throws {
    let other = try #require(SunburstLayout.compute(tree: treeWithMergedSiblings(), center: 0).first { $0.node == nil })
    #expect(other.otherCount == 100 && other.ageBucket == .older && other.lastUsed == now - day)
}

@Test func mergedTreemapOtherTakesTheDominantBucketOfItsBytes() throws {
    let tiles = TreemapLayout.compute(tree: treeWithMergedSiblings(), center: 0, width: 800, height: 600)
    let other = try #require(tiles.first { $0.node == nil })
    #expect(other.otherCount == 100 && other.ageBucket == .older)
}

@Test func segmentsTilesAndSnapshotCarryAgeBuckets() async throws {
    let store = ScanStore(rootName: "r", rootPath: "/r", now: now)
    let file = DirectoryEntry(name: "a.mov", kind: .file, allocatedSize: 500, device: 1, inode: 1, linkCount: 1,
                              isMountPoint: false, isDataless: false,
                              modificationTime: now - 400 * day, accessTime: now - 400 * day)
    _ = await store.insert([file], under: FileTree.root, parentPath: "/r",
                           boundary: ScanBoundary(allowedDevices: [1], excludedPaths: []))
    let snapshot = await store.snapshot(center: FileTree.root, chart: .sunburst(depth: 3), biggestLimit: 5)
    #expect(snapshot.ageTotals == [.oneToTwoYears: 500])
    #expect(snapshot.segments.first?.ageBucket == .oneToTwoYears)
    #expect(snapshot.biggest.first?.ageBucket == .oneToTwoYears)
    let tiles = await store.snapshot(center: FileTree.root, chart: .treemap(width: 400, height: 300, depth: 3),
                                     biggestLimit: 5).tiles
    #expect(tiles.first?.ageBucket == .oneToTwoYears)
}
