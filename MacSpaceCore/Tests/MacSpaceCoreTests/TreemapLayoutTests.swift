import Testing
@testable import MacSpaceCore

private func flat(_ sizes: [UInt64]) -> FileTree {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for (i, s) in sizes.enumerated() { t.addChild(of: 0, name: "f\(i)", kind: .file, allocatedSize: s) }
    return t
}

@Test func areasAreProportionalAndInside() {
    let tiles = TreemapLayout.compute(tree: flat([600, 300, 100]), center: 0, width: 400, height: 300)
    #expect(tiles.count == 3)
    let total = tiles.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(tiles[0].width * tiles[0].height / total - 0.6) < 0.05)
    #expect(tiles.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 400.001 && $0.y + $0.height <= 300.001 })
}

@Test func squarifiedKeepsAspectReasonable() {
    let tiles = TreemapLayout.compute(tree: flat(Array(repeating: 10, count: 16)), center: 0, width: 400, height: 400)
    #expect(tiles.allSatisfy { max($0.width / $0.height, $0.height / $0.width) < 2.5 })
}

@Test func nestedChildrenSitInsideParentBelowHeader() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    for i in 0..<4 { t.addChild(of: d, name: "c\(i)", kind: .file, allocatedSize: 100) }
    let tiles = TreemapLayout.compute(tree: t, center: 0, width: 600, height: 400)
    let p = tiles.first { $0.node == d }!, kids = tiles.filter { $0.depth == 2 }
    #expect(p.hasHeader && kids.count == 4)
    #expect(kids.allSatisfy { $0.y >= p.y + 18 && $0.x >= p.x && $0.x + $0.width <= p.x + p.width + 0.001 })
}

@Test func tinySiblingsMergeIntoOtherTile() {
    let tiles = TreemapLayout.compute(tree: flat([1_000_000_000] + Array(repeating: 1, count: 10_000)), center: 0, width: 800, height: 600)
    #expect(tiles.count == 2 && tiles[1].node == nil && tiles[1].otherCount == 10_000)
}

@Test func degenerateRectProducesNoTiles() {
    #expect(TreemapLayout.compute(tree: flat([5, 5]), center: 0, width: 0, height: 300).isEmpty)
    #expect(TreemapLayout.compute(tree: flat([]), center: 0, width: 300, height: 300).isEmpty)
}

@Test func hitTestReturnsDeepest() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "c", kind: .file, allocatedSize: 100)
    let tiles = TreemapLayout.compute(tree: t, center: 0, width: 600, height: 400)
    let c = tiles.first { $0.depth == 2 }!
    #expect(TreemapLayout.hitTest(tiles, x: c.x + c.width / 2, y: c.y + c.height / 2)?.name == "c")
    #expect(TreemapLayout.hitTest(tiles, x: -5, y: -5) == nil)
}

@Test func loneSmallSiblingIsDrawnAsItself() {
    let tiles = TreemapLayout.compute(tree: flat([1_000_000_000, 1]), center: 0, width: 800, height: 600)
    #expect(tiles.count == 2 && tiles[1].node == 2 && tiles[1].otherCount == 0 && tiles[1].id == "2")
}

@Test func otherTileCarriesIdSizeAndLatestUse() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    t.addChild(of: 0, name: "big", kind: .file, allocatedSize: 1_000_000_000)
    t.addChild(of: 0, name: "a", kind: .file, allocatedSize: 2, lastUsed: 50)
    t.addChild(of: 0, name: "b", kind: .file, allocatedSize: 3, lastUsed: 70)
    t.addChild(of: 0, name: "z", kind: .file, allocatedSize: 0, lastUsed: 99)  // empty: not drawn at all
    let tiles = TreemapLayout.compute(tree: t, center: 0, width: 800, height: 600)
    #expect(tiles.count == 2)
    let other = tiles[1]
    #expect(other.id == "other-0-1" && other.size == 5 && other.otherCount == 2 && other.lastUsed == 70)
    #expect(other.category == .other && !other.hasChildren && !other.hasHeader)
}

@Test func filesAndMaxDepthAreNotSubdivided() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d1 = t.addChild(of: 0, name: "d1", kind: .directory, allocatedSize: 0)
    let d2 = t.addChild(of: d1, name: "d2", kind: .directory, allocatedSize: 0)
    t.addChild(of: d2, name: "f", kind: .file, allocatedSize: 100, category: .video)
    let one = TreemapLayout.compute(tree: t, center: 0, width: 600, height: 400, depth: 1)
    #expect(one.count == 1 && !one[0].hasHeader && one[0].hasChildren)
    let deep = TreemapLayout.compute(tree: t, center: 0, width: 600, height: 400, depth: 3)
    #expect(deep.map(\.name) == ["d1", "d2", "f"] && deep.map(\.depth) == [1, 2, 3])
    #expect(deep[2].category == .video && !deep[2].hasHeader)
    #expect(deep[0].category == .video)  // dominant category of the folder
}

@Test func smallParentHasNoHeaderButStillNests() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "a", kind: .file, allocatedSize: 60)
    t.addChild(of: d, name: "b", kind: .file, allocatedSize: 40)
    let tiles = TreemapLayout.compute(tree: t, center: 0, width: 100, height: 50)
    let p = tiles[0]
    #expect(!p.hasHeader && tiles.filter { $0.depth == 2 }.count == 2)
    #expect(tiles.filter { $0.depth == 2 }.allSatisfy { $0.y >= p.y + 1.5 && $0.y + $0.height <= p.y + p.height - 1.5 + 1e-9 })
}

@Test func hitTestIsHalfOpenAndBounded() {
    let tiles = TreemapLayout.compute(tree: flat([600, 300, 100]), center: 0, width: 400, height: 300)
    #expect(TreemapLayout.hitTest(tiles, x: 400, y: 10) == nil)  // right edge is exclusive
    #expect(TreemapLayout.hitTest(tiles, x: 0, y: 0)?.name == "f0")
}

/// SplitMix64: a tiny deterministic generator, so the random-tree test is reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Test(arguments: [(800.0, 600.0), (3000.0, 2.0), (1.5, 900.0), (37.0, 1.0), (4000.0, 2500.0)])
func randomTreeTilesAreFiniteNonNegativeAndNested(width: Double, height: Double) {
    var rng = SeededGenerator(state: 42)
    let t = FileTree(rootName: "r", rootPath: "/r")
    var dirs: [NodeID] = [0]
    for i in 0..<5_000 {
        let parent = dirs[Int.random(in: 0..<dirs.count, using: &rng)]
        if Int.random(in: 0..<5, using: &rng) == 0 {
            dirs.append(t.addChild(of: parent, name: "d\(i)", kind: .directory, allocatedSize: 0))
        } else {
            // Sizes spanning 0 B to ~1 TB, so both huge and empty siblings occur.
            let size = Int.random(in: 0..<4, using: &rng) == 0 ? 0 : UInt64.random(in: 1...(1 << 40), using: &rng) >> Int.random(in: 0..<40, using: &rng)
            t.addChild(of: parent, name: "f\(i)", kind: .file, allocatedSize: size)
        }
    }
    let tiles = TreemapLayout.compute(tree: t, center: 0, width: width, height: height, depth: 4)
    #expect(!tiles.isEmpty)
    #expect(width * height < 1_000_000 || tiles.contains { $0.depth == 4 })  // big canvases do nest
    #expect(Set(tiles.map(\.id)).count == tiles.count)
    let byNode = Dictionary(tiles.compactMap { tile in tile.node.map { ($0, tile) } }, uniquingKeysWith: { a, _ in a })
    for tile in tiles {
        #expect(tile.x.isFinite && tile.y.isFinite && tile.width.isFinite && tile.height.isFinite)
        #expect(tile.width >= 0 && tile.height >= 0 && tile.x >= 0 && tile.y >= 0)
        #expect(tile.x + tile.width <= width + 1e-6 && tile.y + tile.height <= height + 1e-6)
        #expect(tile.size > 0)
        if tile.depth > 1, let parent = byNode[tile.parent] {
            #expect(tile.x >= parent.x - 1e-6 && tile.y >= parent.y - 1e-6)
            #expect(tile.x + tile.width <= parent.x + parent.width + 1e-6)
            #expect(tile.y + tile.height <= parent.y + parent.height + 1e-6)
        }
    }
}

@Test func hugeFolderStaysBounded() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for i in 0..<200_000 { t.addChild(of: 0, name: "f\(i)", kind: .file, allocatedSize: UInt64(i % 1000 + 1)) }
    let tiles = TreemapLayout.compute(tree: t, center: 0, width: 800, height: 600)
    // Every drawn tile but "altri" covers at least minTileArea.
    #expect(tiles.count <= 800 * 600 / 36 + 1)
    #expect(tiles.last?.node == nil && tiles.last!.otherCount > 0)
    #expect(tiles.reduce(0) { $0 + $1.size } == t.size(0))
}
