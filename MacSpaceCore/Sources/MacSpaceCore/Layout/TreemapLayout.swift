/// One block of the treemap. Rects are in points, origin top-left, y down.
///
/// A rect is the tile's whole layout slot: siblings' slots abut. Draw each tile inset by
/// `Style.gap / 2` so siblings show a gap; children are laid out inside the parent's slot inset by
/// the same amount (and below its header), so they keep that gap from the parent's drawn edge too.
public struct TreemapTile: Sendable, Hashable, Identifiable {
    /// `"\(node)"`, or `"other-\(parent)-\(depth)"` for a merged "altri" tile.
    public var id: String
    /// `nil` for a merged "altri" tile.
    public var node: NodeID?
    public var parent: NodeID
    /// 1 = children of the center.
    public var depth: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
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
    /// Whether the top `Style.header` points of the tile (below the `gap / 2` inset) are reserved
    /// for a section header; its children sit below it.
    public var hasHeader: Bool
    /// The node's `SafetyVerdict` level, stamped by `ScanStore`; always `.normal` for "altri".
    public var safety: SafetyLevel

    public init(id: String, node: NodeID?, parent: NodeID, depth: Int, x: Double, y: Double,
                width: Double, height: Double, size: UInt64, name: String, otherCount: Int,
                flags: NodeFlags = [], hasChildren: Bool = false, category: FileCategory = .other,
                lastUsed: UInt32 = 0, ageBucket: AgeBucket = .unknown, hasHeader: Bool = false,
                safety: SafetyLevel = .normal) {
        self.id = id
        self.node = node
        self.parent = parent
        self.depth = depth
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.size = size
        self.name = name
        self.otherCount = otherCount
        self.flags = flags
        self.hasChildren = hasChildren
        self.category = category
        self.lastUsed = lastUsed
        self.ageBucket = ageBucket
        self.hasHeader = hasHeader
        self.safety = safety
    }
}

public enum TreemapLayout {
    /// Geometry knobs, in points, and the tile budget. All must be finite and non-negative.
    public struct Style: Sendable {
        /// Space between sibling tiles, and between a parent's drawn edge and its children.
        public var gap: Double
        /// Height of the section header band reserved at the top of large parent tiles.
        public var header: Double
        /// A parent tile gets a header only when at least this wide…
        public var headerMinWidth: Double
        /// …and at least this tall.
        public var headerMinHeight: Double
        /// Siblings whose tile would cover less than this area merge into "altri".
        public var minTileArea: Double
        /// At most this many siblings get tiles of their own: the largest, ties going to the
        /// earliest inserted. The rest merge into "altri".
        public var maxTilesPerFamily: Int
        /// Subdivision stops before the layout would exceed this many tiles (the center's own
        /// children are always laid out, so keep it above `maxTilesPerFamily`).
        public var maxTiles: Int

        public init(gap: Double = 3.0, header: Double = 18.0, headerMinWidth: Double = 120.0,
                    headerMinHeight: Double = 60.0, minTileArea: Double = 36.0,
                    maxTilesPerFamily: Int = 1200, maxTiles: Int = 3000) {
            self.gap = gap
            self.header = header
            self.headerMinWidth = headerMinWidth
            self.headerMinHeight = headerMinHeight
            self.minTileArea = minTileArea
            self.maxTilesPerFamily = maxTilesPerFamily
            self.maxTiles = maxTiles
        }
    }

    private struct Rect {
        var x, y, width, height: Double
    }

    /// Lays out `depth` levels of descendants of `center` in a `width × height` canvas with the
    /// squarified algorithm (Bruls, Huizing, van Wijk 2000). Each tile gets an area proportional
    /// to its size over its parent's (a folder's own bytes leave a little space unused, as in the
    /// sunburst). Siblings whose tile would be smaller than `minTileArea`, or that fall outside
    /// the `maxTilesPerFamily` largest (ties: earliest inserted first), are merged into one
    /// trailing "altri" tile (only two or more non-empty ones; a lone one is kept as itself).
    /// Empty nodes are skipped; files, "altri" and the last level are never subdivided, nor is a
    /// tile whose inner area is under 1 pt on either side. Output is ordered level by level, each
    /// family like `children(of:)` (size descending, then name) with "altri" last, so parents
    /// always precede their children.
    ///
    /// Cost is bounded by the style, not the tree: a family has at most `maxTilesPerFamily + 1`
    /// tiles, and families are laid out breadth-first until the next one would push the total
    /// past `maxTiles`; from then on no tile is subdivided (and none of those has a header). Only
    /// a folder's visible children get sorted; the rest take one unsorted pass.
    public static func compute(tree: FileTree, center: NodeID, width: Double, height: Double,
                               depth: Int = 3, style: Style = .init()) -> [TreemapTile] {
        guard depth > 0, width.isFinite, height.isFinite, width >= 1, height >= 1,
              tree.size(center) > 0 else { return [] }
        var result: [TreemapTile] = []
        // Regions queued for subdivision, each at least 1 × 1 pt, with the index of the parent's
        // own tile in `result` (nil for the center).
        var queue: [(node: NodeID, region: Rect, depth: Int, tile: Int?)] =
            [(center, Rect(x: 0, y: 0, width: width, height: height), 1, nil)]
        var head = 0
        var budgetExhausted = false
        while head < queue.count {
            let (parent, region, level, parentTile) = queue[head]
            head += 1
            if budgetExhausted {
                if let parentTile { result[parentTile].hasHeader = false }
                continue
            }
            let parentSize = tree.size(parent)
            guard parentSize > 0 else { continue }
            let scale = region.width * region.height / Double(parentSize)  // pt² per byte

            // A child gets its own tile when it holds at least `minSize` bytes (enough to cover
            // minTileArea) and is among the family's `maxTilesPerFamily` largest, ranked by size
            // then node id (earliest inserted first), so ties never compare names. The rest is
            // tallied into "altri".
            let threshold = style.minTileArea / scale
            let minSize = threshold >= Double(UInt64.max) ? UInt64.max : UInt64(max(1, threshold.rounded(.up)))
            var otherSize: UInt64 = 0
            var otherCount = 0
            var otherLastUsed: UInt32 = 0
            var otherAges = [UInt64](repeating: 0, count: FileTree.ageCount)
            var lastOther: NodeID = 0
            func addOther(_ child: NodeID, size: UInt64) {
                otherSize &+= size
                otherCount += 1
                otherLastUsed = max(otherLastUsed, tree.lastUsed(child))
                tree.addAgeBytes(of: child, to: &otherAges)
                lastOther = child
            }
            // The one pass over all children: a folder of a million tiny files costs O(n). What
            // passes the area test is bounded by canvas area / minTileArea.
            var members: [NodeID] = []
            tree.forEachChild(of: parent) { child in
                let size = tree.size(child)
                guard size > 0 else { return }
                if size >= minSize { members.append(child) } else { addOther(child, size: size) }
            }
            let familyLimit = max(0, style.maxTilesPerFamily)
            if members.count > familyLimit {
                let candidates = members
                members = []
                // The last member's size is the smallest of the `familyLimit` largest, found with
                // a min-heap of sizes. Of the children that size, the earliest inserted fill the
                // places the larger ones leave.
                var cutoff = UInt64.max
                var lastTie: NodeID = -1
                if familyLimit > 0 {
                    var largest: [UInt64] = []
                    largest.reserveCapacity(familyLimit)
                    for child in candidates {
                        let size = tree.size(child)
                        if largest.count < familyLimit {
                            largest.append(size)
                            siftUp(&largest, from: largest.count - 1)
                        } else if size > largest[0] {
                            largest[0] = size
                            siftDown(&largest, from: 0)
                        }
                    }
                    cutoff = largest[0]
                    var larger = 0
                    var ties: [NodeID] = []
                    for child in candidates {
                        let size = tree.size(child)
                        if size > cutoff { larger += 1 } else if size == cutoff { ties.append(child) }
                    }
                    ties.sort()
                    lastTie = ties[familyLimit - larger - 1]
                }
                for child in candidates {
                    let size = tree.size(child)
                    if size > cutoff || (size == cutoff && child <= lastTie) {
                        members.append(child)
                    } else {
                        addOther(child, size: size)
                    }
                }
            }
            tree.sortLikeChildren(&members)
            // A lone small sibling is drawn as itself: "altri" only ever stands for two or more.
            if otherCount == 1 { members.append(lastOther) }
            let hasOther = otherCount > 1
            let familyCount = members.count + (hasOther ? 1 : 0)
            if let parentTile, result.count + familyCount > style.maxTiles {
                budgetExhausted = true
                result[parentTile].hasHeader = false
                continue
            }

            // Squarify wants areas in descending order. Members already are, but "altri" (merged
            // by the family budget) can outweigh some of them: it goes in at its sorted position,
            // and its rect is mapped back so the output keeps it last.
            var areas = members.map { Double(tree.size($0)) * scale }
            var otherSlot = areas.count
            if hasOther {
                let otherArea = Double(otherSize) * scale
                otherSlot = areas.firstIndex { $0 < otherArea } ?? areas.count
                areas.insert(otherArea, at: otherSlot)
            }
            let rects = squarify(areas, in: region)
            func rect(forMember index: Int) -> Rect? {
                let slot = index < otherSlot ? index : index + 1
                return slot < rects.count ? rects[slot] : nil
            }

            for (index, child) in members.enumerated() {
                guard let rect = rect(forMember: index) else { continue }
                let row = tree.row(child)
                let subdivide = level < depth && row.kind == .directory && row.hasChildren
                let hasHeader = subdivide && rect.width >= style.headerMinWidth
                    && rect.height >= style.headerMinHeight
                result.append(TreemapTile(id: "\(child)", node: child, parent: parent, depth: level,
                                          x: rect.x, y: rect.y, width: rect.width, height: rect.height,
                                          size: row.size, name: row.name, otherCount: 0, flags: row.flags,
                                          hasChildren: row.hasChildren, category: row.category,
                                          lastUsed: row.lastUsed, ageBucket: row.ageBucket, hasHeader: hasHeader))
                guard subdivide else { continue }
                let inset = style.gap / 2
                let top = inset + (hasHeader ? style.header : 0)
                let inner = Rect(x: rect.x + inset, y: rect.y + top,
                                 width: rect.width - 2 * inset, height: rect.height - inset - top)
                if inner.width >= 1, inner.height >= 1 {
                    queue.append((child, inner, level + 1, result.count - 1))
                } else {
                    result[result.count - 1].hasHeader = false
                }
            }
            if hasOther, otherSlot < rects.count {
                let rect = rects[otherSlot]
                result.append(TreemapTile(id: "other-\(parent)-\(level)", node: nil, parent: parent,
                                          depth: level, x: rect.x, y: rect.y, width: rect.width,
                                          height: rect.height, size: otherSize, name: "",
                                          otherCount: otherCount, category: .other,
                                          lastUsed: otherLastUsed,
                                          ageBucket: FileTree.dominantAgeBucket(otherAges)))
            }
        }
        return result
    }

    /// The deepest tile containing the point (edges half-open: left/top in, right/bottom out).
    public static func hitTest(_ tiles: [TreemapTile], x: Double, y: Double) -> TreemapTile? {
        var best: TreemapTile?
        for tile in tiles where x >= tile.x && x < tile.x + tile.width && y >= tile.y && y < tile.y + tile.height {
            if best.map({ tile.depth > $0.depth }) ?? true { best = tile }
        }
        return best
    }

    /// Min-heap helpers on sizes, for picking the largest children without sorting them all.
    private static func siftUp(_ heap: inout [UInt64], from index: Int) {
        var i = index
        while i > 0 {
            let up = (i - 1) / 2
            guard heap[i] < heap[up] else { return }
            heap.swapAt(i, up)
            i = up
        }
    }

    private static func siftDown(_ heap: inout [UInt64], from index: Int) {
        var i = index
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < heap.count, heap[l] < heap[smallest] { smallest = l }
            if r < heap.count, heap[r] < heap[smallest] { smallest = r }
            if smallest == i { return }
            heap.swapAt(i, smallest)
            i = smallest
        }
    }

    /// Squarified rects for `areas` (descending, positive, summing to at most `bounds`' area),
    /// in order. Each row runs along the shorter side of the space left and takes items while that
    /// does not worsen its worst aspect ratio. Rects never leave `bounds` and are never negative;
    /// should float drift exhaust the space, the remaining items get no rect.
    private static func squarify(_ areas: [Double], in bounds: Rect) -> [Rect] {
        var rects: [Rect] = []
        rects.reserveCapacity(areas.count)
        var free = bounds
        var start = 0
        while start < areas.count {
            let vertical = free.width >= free.height  // the row is a column at the left
            let side = vertical ? free.height : free.width
            let depthLeft = vertical ? free.width : free.height
            guard side > 0, depthLeft > 0 else { break }

            // Worst aspect ratio of a row of total `sum` whose largest item is areas[start]
            // and smallest `smallest`: max(s²·max / sum², sum² / (s²·min)).
            let side2 = side * side
            func worst(sum: Double, smallest: Double) -> Double {
                let sum2 = sum * sum
                return max(side2 * areas[start] / sum2, sum2 / (side2 * smallest))
            }
            var end = start + 1
            var sum = areas[start]
            var best = worst(sum: sum, smallest: areas[start])
            while end < areas.count {
                let candidate = worst(sum: sum + areas[end], smallest: areas[end])
                if candidate > best { break }
                best = candidate
                sum += areas[end]
                end += 1
            }

            var thickness = min(sum / side, depthLeft)
            // The last row of a full layout ends exactly at the far edge, despite summing drift.
            if end == areas.count, depthLeft - thickness <= 1e-9 * max(1, depthLeft) { thickness = depthLeft }
            guard thickness > 0 else { break }
            let rowStart = vertical ? free.y : free.x
            let rowEnd = rowStart + side
            var cursor = rowStart
            for index in start..<end {
                let next = index == end - 1 ? rowEnd : min(cursor + areas[index] / thickness, rowEnd)
                rects.append(vertical
                    ? Rect(x: free.x, y: cursor, width: thickness, height: next - cursor)
                    : Rect(x: cursor, y: free.y, width: next - cursor, height: thickness))
                cursor = next
            }
            if vertical {
                free.x += thickness
                free.width = max(0, free.width - thickness)
            } else {
                free.y += thickness
                free.height = max(0, free.height - thickness)
            }
            start = end
        }
        return rects
    }
}
