import Testing
@testable import MacSpaceCore

private func tree(_ sizes: [UInt64]) -> FileTree {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for (i, s) in sizes.enumerated() { t.addChild(of: 0, name: "f\(i)", kind: .file, allocatedSize: s) }
    return t
}

@Test func ringOneCoversFullCircleProportionally() throws {
    let segs = SunburstLayout.compute(tree: tree([300, 100]), center: 0)
    #expect(segs.count == 2)
    #expect(abs(segs[0].endAngle - segs[0].startAngle - 1.5 * .pi) < 1e-9)
    #expect(abs(try #require(segs.last).endAngle - 2 * .pi) < 1e-9)
}

@Test func childrenNestInsideParentSpan() throws {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "a", kind: .file, allocatedSize: 50)
    t.addChild(of: d, name: "b", kind: .file, allocatedSize: 50)
    t.addChild(of: 0, name: "c", kind: .file, allocatedSize: 100)
    let segs = SunburstLayout.compute(tree: t, center: 0)
    let parent = try #require(segs.first { $0.node == d })
    let kids = segs.filter { $0.depth == 2 }
    #expect(kids.count == 2 && kids.allSatisfy { $0.startAngle >= parent.startAngle && $0.endAngle <= parent.endAngle + 1e-9 })
}

@Test func tinySiblingsMergeIntoOther() {
    let segs = SunburstLayout.compute(tree: tree([1_000_000_000] + Array(repeating: 1, count: 10_000)), center: 0)
    #expect(segs.count == 2)
    #expect(segs[1].node == nil && segs[1].otherCount == 10_000)
}

@Test func emptyCenterHasNoSegments() { #expect(SunburstLayout.compute(tree: tree([]), center: 0).isEmpty) }

@Test func hitTestFindsSegment() {
    let segs = SunburstLayout.compute(tree: tree([300, 100]), center: 0)
    #expect(SunburstLayout.hitTest(segs, angle: 0.1, depth: 1)?.name == "f0")
    #expect(SunburstLayout.hitTest(segs, angle: 1.9 * .pi, depth: 1)?.name == "f1")
    #expect(SunburstLayout.hitTest(segs, angle: 0.1, depth: 2) == nil)
}

@Test func hitTestNormalizesAngles() {
    let segs = SunburstLayout.compute(tree: tree([300, 100]), center: 0)
    #expect(SunburstLayout.hitTest(segs, angle: 0.1 + 2 * .pi, depth: 1)?.name == "f0")
    #expect(SunburstLayout.hitTest(segs, angle: -0.1, depth: 1)?.name == "f1")
}

@Test func otherSegmentIsNeverSubdividedAndDepthIsLimited() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let big = t.addChild(of: 0, name: "big", kind: .directory, allocatedSize: 0)
    let mid = t.addChild(of: big, name: "mid", kind: .directory, allocatedSize: 0)
    let deep = t.addChild(of: mid, name: "deep", kind: .directory, allocatedSize: 0)
    t.addChild(of: deep, name: "leaf", kind: .file, allocatedSize: 1_000_000)
    let tiny = t.addChild(of: 0, name: "tiny", kind: .directory, allocatedSize: 0)
    t.addChild(of: tiny, name: "x", kind: .file, allocatedSize: 1)
    t.addChild(of: 0, name: "tiny2", kind: .file, allocatedSize: 1)  // "altri" needs two or more
    let segs = SunburstLayout.compute(tree: t, center: 0, depth: 3)
    #expect(segs.map(\.depth).max() == 3)
    #expect(segs.contains { $0.node == nil && $0.depth == 1 })
    #expect(!segs.contains { $0.parent == tiny })
}

@Test func segmentsCarryFlagsAndWhetherTheyHaveChildren() throws {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let full = t.addChild(of: 0, name: "full", kind: .directory, allocatedSize: 0)
    t.addChild(of: full, name: "a", kind: .file, allocatedSize: 100)
    let locked = t.addChild(of: 0, name: "locked", kind: .directory, allocatedSize: 50)
    t.insertFlags(.unreadable, for: locked)
    let segs = SunburstLayout.compute(tree: t, center: 0)
    let fullSeg = try #require(segs.first { $0.node == full })
    let lockedSeg = try #require(segs.first { $0.node == locked })
    #expect(fullSeg.hasChildren && fullSeg.flags.isEmpty)
    #expect(!lockedSeg.hasChildren && lockedSeg.flags.contains(.unreadable))
    #expect(segs.first { $0.depth == 2 }?.hasChildren == false)
}

@Test func loneTinySiblingIsNotMergedIntoOther() throws {
    let segs = SunburstLayout.compute(tree: tree([1_000_000_000, 1]), center: 0)
    #expect(segs.count == 2)
    #expect(segs.allSatisfy { $0.node != nil && $0.otherCount == 0 })
    #expect(abs(try #require(segs.last).endAngle - 2 * .pi) < 1e-9)
}

@Test func loneTinySiblingFollowedByEmptyOnesIsNotMergedIntoOther() {
    let segs = SunburstLayout.compute(tree: tree([1_000_000_000, 1, 0]), center: 0)
    #expect(!segs.contains { $0.node == nil })
    #expect(segs.count == 2)
}

@Test func lastSegmentEndsExactlyAtItsParentsEnd() throws {
    // Summing proportional spans drifts by an ulp: 875+98 falls short of 2π, 843+358 overshoots.
    for sizes: [UInt64] in [[875, 98], [843, 358]] {
        let segs = SunburstLayout.compute(tree: tree(sizes), center: 0)
        #expect(segs.last?.endAngle == 2 * .pi, "\(sizes)")
    }
    let t = FileTree(rootName: "r", rootPath: "/r")
    t.addChild(of: 0, name: "big", kind: .file, allocatedSize: 1000)
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "a", kind: .file, allocatedSize: 875)
    t.addChild(of: d, name: "b", kind: .file, allocatedSize: 98)
    let segs = SunburstLayout.compute(tree: t, center: 0)
    let parent = try #require(segs.first { $0.node == d })
    #expect(segs.filter { $0.depth == 2 }.last?.endAngle == parent.endAngle)
}

@Test func hitTestCoversTheTwelveOClockSeam() {
    let segs = SunburstLayout.compute(tree: tree([875, 98]), center: 0)
    // atan2 just left of 12 o'clock gives a tiny negative angle; just right of it, a tiny positive one.
    #expect(SunburstLayout.hitTest(segs, angle: -1e-17, depth: 1)?.name == "f0")
    #expect(SunburstLayout.hitTest(segs, angle: (2 * .pi).nextDown, depth: 1)?.name == "f1")
    #expect(SunburstLayout.hitTest(segs, angle: 1e-17, depth: 1)?.name == "f0")
    #expect(SunburstLayout.normalizedAngle(-1e-17) == 0)
    #expect(SunburstLayout.normalizedAngle(2 * .pi) == 0)
    #expect(SunburstLayout.normalizedAngle(-.pi / 2) == 1.5 * .pi)
}

@Test func segmentsCarryDominantCategoryAndLastUse() throws {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "a.mov", kind: .file, allocatedSize: 600, category: .video, lastUsed: 40)
    t.addChild(of: d, name: "b.pdf", kind: .file, allocatedSize: 300, category: .document, lastUsed: 70)
    t.addChild(of: 0, name: "c.mp3", kind: .file, allocatedSize: 500, category: .music, lastUsed: 20)
    let segs = SunburstLayout.compute(tree: t, center: 0)
    #expect(segs.count == 4)
    for seg in segs {
        let node = try #require(seg.node)
        #expect(seg.category == t.dominantCategory(node) && seg.lastUsed == t.lastUsed(node), "\(seg.name)")
    }
    #expect(segs.first { $0.node == d }?.category == .video)
}

@Test func mergedOtherIsOtherCategoryWithTheLatestUse() throws {
    let t = FileTree(rootName: "r", rootPath: "/r")
    t.addChild(of: 0, name: "big.mov", kind: .file, allocatedSize: 1_000_000_000, category: .video, lastUsed: 5)
    for i in 0..<100 {
        t.addChild(of: 0, name: "s\(i).pdf", kind: .file, allocatedSize: 1, category: .document, lastUsed: UInt32(100 + i))
    }
    let segs = SunburstLayout.compute(tree: t, center: 0)
    let other = try #require(segs.first { $0.node == nil })
    #expect(other.otherCount == 100 && other.category == .other && other.lastUsed == 199)
}
