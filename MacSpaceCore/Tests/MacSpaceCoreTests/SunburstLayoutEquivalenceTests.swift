import Testing
@testable import MacSpaceCore

/// `SunburstLayout.compute` as it was before issue #12, kept verbatim as the reference the
/// one-pass layout must match exactly: it sorts every expanded folder's children in full.
private enum ReferenceSunburstLayout {
    static func compute(tree: FileTree, center: NodeID, depth: Int = 3,
                        minAngle: Double = 0.006) -> [ArcSegment] {
        guard depth > 0, tree.size(center) > 0 else { return [] }
        var result: [ArcSegment] = []
        // Spans queued for expansion; only those >= minAngle that may have visible children.
        var queue: [(node: NodeID, start: Double, end: Double, depth: Int)] = [(center, 0, 2 * .pi, 1)]
        var head = 0
        while head < queue.count {
            let (parent, start, end, ringDepth) = queue[head]
            head += 1
            let parentSize = Double(tree.size(parent))
            guard parentSize > 0 else { continue }
            let span = end - start
            // Summed proportional spans drift by an ulp or so: the last one ends exactly at `end`.
            func snapped(_ angle: Double) -> Double { abs(end - angle) < 1e-9 ? end : angle }
            let children = tree.children(of: parent)
            var cursor = start
            var index = 0
            while index < children.count {
                let child = children[index]
                let size = tree.size(child)
                if size == 0 { break }  // sorted by size descending: the rest are empty too
                let childSpan = span * Double(size) / parentSize
                if childSpan < minAngle { break }  // so are all following siblings
                let childEnd = snapped(cursor + childSpan)
                let row = tree.row(child)
                result.append(ArcSegment(id: "\(child)", node: child, parent: parent, depth: ringDepth,
                                         startAngle: cursor, endAngle: childEnd, size: size,
                                         name: row.name, otherCount: 0, flags: row.flags,
                                         hasChildren: row.hasChildren, category: row.category,
                                         lastUsed: row.lastUsed, ageBucket: row.ageBucket))
                if ringDepth < depth, tree.kind(child) == .directory {
                    queue.append((child, cursor, childEnd, ringDepth + 1))
                }
                cursor = childEnd
                index += 1
            }
            var otherSize: UInt64 = 0
            var otherCount = 0
            var otherLastUsed: UInt32 = 0
            var otherAges = [UInt64](repeating: 0, count: FileTree.ageCount)
            let firstOther = index
            while index < children.count {
                let size = tree.size(children[index])
                if size == 0 { break }
                otherSize &+= size
                otherCount += 1
                otherLastUsed = max(otherLastUsed, tree.lastUsed(children[index]))
                tree.addAgeBytes(of: children[index], to: &otherAges)
                index += 1
            }
            if otherCount == 1 {
                // A lone small sibling is drawn as itself: "altri" only ever stands for two or more.
                let child = children[firstOther]
                let row = tree.row(child)
                result.append(ArcSegment(id: "\(child)", node: child, parent: parent, depth: ringDepth,
                                         startAngle: cursor, endAngle: snapped(cursor + span * Double(otherSize) / parentSize),
                                         size: otherSize, name: row.name, otherCount: 0, flags: row.flags,
                                         hasChildren: row.hasChildren, category: row.category,
                                         lastUsed: row.lastUsed, ageBucket: row.ageBucket))
            } else if otherCount > 1 {
                let otherEnd = snapped(cursor + span * Double(otherSize) / parentSize)
                result.append(ArcSegment(id: "other-\(parent)-\(ringDepth)", node: nil, parent: parent,
                                         depth: ringDepth, startAngle: cursor, endAngle: otherEnd,
                                         size: otherSize, name: "", otherCount: otherCount,
                                         category: .other, lastUsed: otherLastUsed,
                                         ageBucket: FileTree.dominantAgeBucket(otherAges)))
            }
        }
        return result
    }
}

/// SplitMix64: a tiny deterministic generator, so the random trees are reproducible.
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

/// Bit-for-bit equality: `==` on every field, and the angles' bit patterns too (so a -0 or an
/// ulp of drift cannot hide behind a tolerance).
private func expectIdentical(_ new: [ArcSegment], _ reference: [ArcSegment], _ label: String) {
    #expect(new.count == reference.count, "\(label): \(new.count) vs \(reference.count) segments")
    guard new.count == reference.count else { return }
    for (a, b) in zip(new, reference) {
        let same = a == b && a.startAngle.bitPattern == b.startAngle.bitPattern
            && a.endAngle.bitPattern == b.endAngle.bitPattern
        #expect(same, "\(label): \(a) vs \(b)")
        if !same { return }
    }
}

/// Few distinct names, some equal under `String.<` but not byte-equal ("é" precomposed and
/// decomposed), so name ties and the newest-first tie-break both occur.
private let names = ["a", "b", "B", "z", "\u{E9}", "e\u{301}", "\u{E9}t\u{E9}", "x"]

/// A random tree of `count` nodes: folders (some with bytes of their own) and files, sizes from
/// 0 B to ~1 TB on a log scale with many exact ties, last uses spread over every age bucket (and
/// unknown), plus one folder of `crowd` tiny files with tied sizes and names.
private func randomTree(seed: UInt64, count: Int, crowd: Int) -> (tree: FileTree, crowd: NodeID) {
    var rng = SeededGenerator(state: seed)
    let now: UInt32 = 1_800_000_000
    let t = FileTree(rootName: "r", rootPath: "/r", now: now)
    var dirs: [NodeID] = [0]
    func lastUsed() -> UInt32 {
        Int.random(in: 0..<5, using: &rng) == 0 ? 0 : now - UInt32.random(in: 0...(4 * 365 * 86_400), using: &rng)
    }
    for i in 0..<count {
        let parent = dirs[Int.random(in: 0..<dirs.count, using: &rng)]
        let name = names[Int.random(in: 0..<names.count, using: &rng)] + (Bool.random(using: &rng) ? "" : "\(i % 7)")
        let category = FileCategory.allCases[Int.random(in: 0..<FileCategory.allCases.count, using: &rng)]
        if Int.random(in: 0..<5, using: &rng) == 0 {
            let own: UInt64 = Bool.random(using: &rng) ? 0 : UInt64.random(in: 1...4096, using: &rng)
            dirs.append(t.addChild(of: parent, name: name, kind: .directory, allocatedSize: own,
                                   category: category, lastUsed: lastUsed()))
        } else {
            let size: UInt64 = switch Int.random(in: 0..<6, using: &rng) {
            case 0: 0
            case 1: [1, 4096, 1 << 20][Int.random(in: 0..<3, using: &rng)]
            default: UInt64.random(in: 1...(1 << 40), using: &rng) >> Int.random(in: 0..<40, using: &rng)
            }
            t.addChild(of: parent, name: name, kind: .file, allocatedSize: size, category: category,
                       lastUsed: lastUsed())
        }
    }
    let crowded = t.addChild(of: dirs[Int.random(in: 0..<dirs.count, using: &rng)], name: "crowd",
                             kind: .directory, allocatedSize: 0)
    for i in 0..<crowd {
        let size: UInt64 = Int.random(in: 0..<10, using: &rng) == 0 ? 0 : [4096, 8192, 1 << 30][Int.random(in: 0..<3, using: &rng)]
        t.addChild(of: crowded, name: names[i % names.count], kind: .file, allocatedSize: size,
                   lastUsed: lastUsed())
    }
    return (t, crowded)
}

/// One case at a time: the reference sorts in full, which is heavy in a debug build, and the
/// suite has wall-clock bounds (`classifierIsAllocationLight`) that parallel load would stretch.
@Suite(.serialized) struct OnePassSunburstEquivalence {
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6])
    func onePassSunburstMatchesTheFullSortReference(seed: UInt64) {
        let (t, crowd) = randomTree(seed: seed, count: 2_000, crowd: 4_000)
        var rng = SeededGenerator(state: seed &* 31)
        var centers: [NodeID] = [0, crowd]
        for _ in 0..<6 {
            let id = NodeID(Int.random(in: 0..<t.count, using: &rng))
            if t.kind(id) == .directory { centers.append(id) }
        }
        for center in centers {
            for depth in [1, 3, 5] {
                for minAngle in [0.006, 0.0001, 0.05, 0] {
                    expectIdentical(SunburstLayout.compute(tree: t, center: center, depth: depth, minAngle: minAngle),
                                    ReferenceSunburstLayout.compute(tree: t, center: center, depth: depth, minAngle: minAngle),
                                    "seed \(seed) center \(center) depth \(depth) minAngle \(minAngle)")
                }
            }
        }
    }

    /// Every size tied: whether a child is kept or merged is decided for all of them at once, and the
    /// order of the kept ones falls to names and then to the newest node. The counts straddle where
    /// 2π / count crosses the default minAngle (about 1,047).
    @Test(arguments: [2, 3, 166, 167, 168, 1_046, 1_047, 1_048, 5_000])
    func onePassSunburstMatchesTheReferenceOnTiedSiblings(count: Int) {
        let t = FileTree(rootName: "r", rootPath: "/r")
        for i in 0..<count {
            t.addChild(of: 0, name: names[i % names.count], kind: .file, allocatedSize: 4096, lastUsed: UInt32(i))
        }
        expectIdentical(SunburstLayout.compute(tree: t, center: 0),
                        ReferenceSunburstLayout.compute(tree: t, center: 0), "\(count) tied")
    }

    /// The shape behind issue #12: one folder of many tiny files beside a big one, a lone small
    /// sibling, and empty ones.
    @Test func onePassSunburstMatchesTheReferenceOnAHugeFlatFolder() {
        let t = FileTree(rootName: "r", rootPath: "/r")
        let logs = t.addChild(of: 0, name: "logs", kind: .directory, allocatedSize: 0)
        for i in 0..<10_000 {
            t.addChild(of: logs, name: "log\(i % 977)", kind: .file, allocatedSize: UInt64(1 + i % 13) * 512,
                       lastUsed: UInt32(1_700_000_000 + i))
        }
        t.addChild(of: logs, name: "big", kind: .file, allocatedSize: 1 << 30)
        t.addChild(of: logs, name: "empty", kind: .file, allocatedSize: 0)
        t.addChild(of: 0, name: "app", kind: .file, allocatedSize: 3 << 30)
        t.addChild(of: 0, name: "tiny", kind: .file, allocatedSize: 1)
        for depth in [1, 2, 3] {
            let segments = SunburstLayout.compute(tree: t, center: 0, depth: depth)
            #expect(depth == 1 || segments.contains { $0.node == nil && $0.parent == logs })
            expectIdentical(segments, ReferenceSunburstLayout.compute(tree: t, center: 0, depth: depth), "depth \(depth)")
        }
        expectIdentical(SunburstLayout.compute(tree: t, center: logs),
                        ReferenceSunburstLayout.compute(tree: t, center: logs), "logs")
    }
}
