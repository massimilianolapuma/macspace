/// One ring segment of the sunburst. Angles are radians, 0 = 12 o'clock, clockwise.
public struct ArcSegment: Sendable, Hashable, Identifiable {
    /// `"\(node)"`, or `"other-\(parent)-\(depth)"` for a merged "altri" segment.
    public var id: String
    /// `nil` for a merged "altri" segment.
    public var node: NodeID?
    public var parent: NodeID
    /// 1 = innermost ring.
    public var depth: Int
    public var startAngle: Double
    public var endAngle: Double
    public var size: UInt64
    public var name: String
    /// Number of merged siblings; > 0 only for "altri".
    public var otherCount: Int
    public var flags: NodeFlags
    /// Whether the node has children to drill into; always false for "altri".
    public var hasChildren: Bool
    /// The node's dominant category; `.other` for "altri".
    public var category: FileCategory
    /// The node's last use (0 = unknown); for "altri", the latest of the merged siblings.
    public var lastUsed: UInt32
    /// The node's age bucket by bytes (`FileTree.dominantAgeBucket`); for "altri", the bucket
    /// holding most of the merged siblings' bytes.
    public var ageBucket: AgeBucket

    public init(id: String, node: NodeID?, parent: NodeID, depth: Int, startAngle: Double,
                endAngle: Double, size: UInt64, name: String, otherCount: Int,
                flags: NodeFlags = [], hasChildren: Bool = false,
                category: FileCategory = .other, lastUsed: UInt32 = 0, ageBucket: AgeBucket = .unknown) {
        self.id = id
        self.node = node
        self.parent = parent
        self.depth = depth
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.size = size
        self.name = name
        self.otherCount = otherCount
        self.flags = flags
        self.hasChildren = hasChildren
        self.category = category
        self.lastUsed = lastUsed
        self.ageBucket = ageBucket
    }
}

public enum SunburstLayout {
    /// Lays out `depth` rings of descendants of `center`. Each segment's children subdivide its
    /// span proportionally to size. Siblings narrower than `minAngle` are merged into one
    /// trailing "altri" segment (only two or more non-empty ones; a lone one is kept as itself), which is
    /// never subdivided. Output is ordered ring by ring.
    public static func compute(tree: FileTree, center: NodeID, depth: Int = 3,
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

    /// The segment at `depth` containing `angle` (any real value; normalized into [0, 2π)).
    public static func hitTest(_ segments: [ArcSegment], angle: Double, depth: Int) -> ArcSegment? {
        let a = normalizedAngle(angle)
        return segments.first { $0.depth == depth && a >= $0.startAngle && a < $0.endAngle }
    }

    /// `angle` folded into [0, 2π). A tiny negative angle (just left of 12 o'clock) would
    /// round to exactly 2π when shifted up, past the end of every segment: it maps to 0.
    public static func normalizedAngle(_ angle: Double) -> Double {
        let full = 2 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: full)
        if a < 0 { a += full }
        return a >= full ? 0 : a
    }
}
