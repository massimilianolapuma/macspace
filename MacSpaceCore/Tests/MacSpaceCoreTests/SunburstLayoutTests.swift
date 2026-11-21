import Testing
@testable import MacSpaceCore

private func tree(_ sizes: [UInt64]) -> FileTree {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for (i, s) in sizes.enumerated() { t.addChild(of: 0, name: "f\(i)", kind: .file, allocatedSize: s) }
    return t
}

@Test func ringOneCoversFullCircleProportionally() {
    let segs = SunburstLayout.compute(tree: tree([300, 100]), center: 0)
    #expect(segs.count == 2)
    #expect(abs(segs[0].endAngle - segs[0].startAngle - 1.5 * .pi) < 1e-9)
    #expect(abs(segs.last!.endAngle - 2 * .pi) < 1e-9)
}

@Test func childrenNestInsideParentSpan() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "a", kind: .file, allocatedSize: 50)
    t.addChild(of: d, name: "b", kind: .file, allocatedSize: 50)
    t.addChild(of: 0, name: "c", kind: .file, allocatedSize: 100)
    let segs = SunburstLayout.compute(tree: t, center: 0)
    let parent = segs.first { $0.node == d }!
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
    let segs = SunburstLayout.compute(tree: t, center: 0, depth: 3)
    #expect(segs.map(\.depth).max() == 3)
    #expect(segs.contains { $0.node == nil && $0.depth == 1 })
    #expect(!segs.contains { $0.parent == tiny })
}
