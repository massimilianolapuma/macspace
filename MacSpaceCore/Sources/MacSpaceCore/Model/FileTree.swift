/// Compact struct-of-arrays tree for millions of nodes. Not thread-safe; owned by a single actor.
///
/// Names live in one UTF-8 arena (`nameBytes`), delimited by `nameEnds`, instead of one `String`
/// per node: most names are longer than the 15 bytes Swift stores inline, so per-node strings
/// would cost a heap allocation each. Strings are built on demand.
///
/// Each node also keeps a category byte and a last-use time. For a file the byte is its
/// `FileCategory`; for a directory it is the context the directory imposes on its contents, with
/// `.other` meaning "none" (the classifier never yields `.other` as a context, so that is lossless).
/// Directories additionally own a slot in `categoryBytes`, a flat table of per-category byte totals
/// kept up to date on insert, O(depth), exactly like `sizes`.
public final class FileTree {
    public static let root: NodeID = 0

    private var parents = ContiguousArray<Int32>()
    private var firstChildren = ContiguousArray<Int32>()
    private var nextSiblings = ContiguousArray<Int32>()
    private var sizes = ContiguousArray<UInt64>()
    private var kinds = ContiguousArray<NodeKind>()
    private var flagsStore = ContiguousArray<NodeFlags>()
    /// UTF-8 bytes of every name, in node order, exactly as given (no normalization).
    private var nameBytes = ContiguousArray<UInt8>()
    /// End offset of node `i`'s name in `nameBytes`; it starts where node `i - 1`'s ends.
    private var nameEnds = ContiguousArray<UInt32>()
    /// `FileCategory.rawValue`: a file's category, or a directory's context (`.other` = none).
    private var categories = ContiguousArray<UInt8>()
    /// A file's own `max(modification, access)` time; for a directory, the max over its subtree.
    private var lastUsedStore = ContiguousArray<UInt32>()
    /// Index of a directory's row in `categoryBytes`, -1 for anything else.
    private var dirSlots = ContiguousArray<Int32>()
    /// `categoryCount` byte totals per directory slot, indexed `slot * categoryCount + rawValue`.
    private var categoryBytes = ContiguousArray<UInt64>()
    private let rootPath: String

    private static let categoryCount = FileCategory.allCases.count

    /// `rootCategory` is the root directory's context, `.other` for none.
    public init(rootName: String, rootPath: String, rootCategory: FileCategory = .other) {
        self.rootPath = rootPath
        parents.append(-1)
        firstChildren.append(-1)
        nextSiblings.append(-1)
        sizes.append(0)
        kinds.append(.directory)
        flagsStore.append([])
        appendName(rootName)
        categories.append(rootCategory.rawValue)
        lastUsedStore.append(0)
        dirSlots.append(0)
        categoryBytes.append(contentsOf: repeatElement(0, count: Self.categoryCount))
    }

    public var count: Int { parents.count }

    /// Bytes held by the name arena.
    var nameArenaByteCount: Int { nameBytes.count }

    /// Adds a node, then adds its size to `parent` and every ancestor, both to their sizes and to
    /// their `category` totals, and raises their last use to at least `lastUsed`. O(depth).
    ///
    /// For a directory `category` is the context it imposes (`.other` for none); for anything else
    /// it is the node's own category. A directory's own size, if any, counts under its context.
    @discardableResult
    public func addChild(of parent: NodeID, name: String, kind: NodeKind,
                         allocatedSize: UInt64, flags: NodeFlags = [],
                         category: FileCategory = .other, lastUsed: UInt32 = 0) -> NodeID {
        let id = NodeID(parents.count)
        parents.append(parent)
        firstChildren.append(-1)
        nextSiblings.append(firstChildren[Int(parent)])
        firstChildren[Int(parent)] = id
        sizes.append(allocatedSize)
        kinds.append(kind)
        flagsStore.append(flags)
        appendName(name)
        categories.append(category.rawValue)
        lastUsedStore.append(lastUsed)
        let column = Int(category.rawValue)
        if kind == .directory {
            let slot = categoryBytes.count / Self.categoryCount
            precondition(slot < Int(Int32.max), "FileTree has too many directories")
            dirSlots.append(Int32(slot))
            categoryBytes.append(contentsOf: repeatElement(0, count: Self.categoryCount))
            categoryBytes[slot * Self.categoryCount + column] = allocatedSize
        } else {
            dirSlots.append(-1)
        }
        guard allocatedSize > 0 || lastUsed > 0 else { return id }
        var p = parent
        while p >= 0 {
            let i = Int(p)
            sizes[i] &+= allocatedSize
            categoryBytes[Int(dirSlots[i]) * Self.categoryCount + column] &+= allocatedSize
            if lastUsedStore[i] < lastUsed { lastUsedStore[i] = lastUsed }
            p = parents[i]
        }
        return id
    }

    public func insertFlags(_ flags: NodeFlags, for id: NodeID) {
        flagsStore[Int(id)].formUnion(flags)
    }

    public func name(_ id: NodeID) -> String {
        nameBytes.withUnsafeBufferPointer { String(decoding: $0[nameRange(id)], as: UTF8.self) }
    }

    public func kind(_ id: NodeID) -> NodeKind { kinds[Int(id)] }
    public func size(_ id: NodeID) -> UInt64 { sizes[Int(id)] }
    public func flags(_ id: NodeID) -> NodeFlags { flagsStore[Int(id)] }

    /// A file's own last use; for a directory, the latest over its subtree (0 if unknown or empty).
    public func lastUsed(_ id: NodeID) -> UInt32 { lastUsedStore[Int(id)] }

    /// The context a directory imposes on its contents, or nil if none (or `id` is not a directory).
    func context(_ id: NodeID) -> FileCategory? {
        guard dirSlots[Int(id)] >= 0 else { return nil }
        let category = Self.category(raw: categories[Int(id)])
        return category == .other ? nil : category
    }

    /// A file's own category; for a directory, the category holding the most bytes below it (ties
    /// go to the lower raw value), or its context while it holds no bytes (`.other` if none).
    public func dominantCategory(_ id: NodeID) -> FileCategory {
        let slot = Int(dirSlots[Int(id)])
        guard slot >= 0 else { return Self.category(raw: categories[Int(id)]) }
        let base = slot * Self.categoryCount
        var best = -1
        var bestBytes: UInt64 = 0
        for column in 0..<Self.categoryCount where categoryBytes[base + column] > bestBytes {
            best = column
            bestBytes = categoryBytes[base + column]
        }
        return best < 0 ? Self.category(raw: categories[Int(id)]) : Self.category(raw: UInt8(best))
    }

    /// Bytes per category below `id` (a file: its own size), non-zero entries only.
    public func categoryTotals(_ id: NodeID) -> [FileCategory: UInt64] {
        let slot = Int(dirSlots[Int(id)])
        guard slot >= 0 else {
            let size = sizes[Int(id)]
            return size > 0 ? [Self.category(raw: categories[Int(id)]): size] : [:]
        }
        var totals: [FileCategory: UInt64] = [:]
        let base = slot * Self.categoryCount
        for column in 0..<Self.categoryCount where categoryBytes[base + column] > 0 {
            totals[Self.category(raw: UInt8(column))] = categoryBytes[base + column]
        }
        return totals
    }

    private static func category(raw: UInt8) -> FileCategory { FileCategory(rawValue: raw) ?? .other }

    public func parent(_ id: NodeID) -> NodeID? {
        let p = parents[Int(id)]
        return p < 0 ? nil : p
    }

    public func path(of id: NodeID) -> String {
        guard id != Self.root else { return rootPath }
        var chain: [NodeID] = []
        var cur = id
        while cur != Self.root {
            chain.append(cur)
            cur = parents[Int(cur)]
        }
        var bytes = Array(rootPath.utf8)
        if bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        nameBytes.withUnsafeBufferPointer { arena in
            for node in chain.reversed() {
                bytes.append(UInt8(ascii: "/"))
                bytes.append(contentsOf: arena[nameRange(node)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Children sorted by size descending, then name ascending (as `String.<` orders them), then
    /// newest node first for names `String.<` considers equal.
    public func children(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var c = firstChildren[Int(id)]
        while c >= 0 {
            result.append(c)
            c = nextSiblings[Int(c)]
        }
        nameBytes.withUnsafeBufferPointer { arena in
            result.sort { precedes($0, $1, arena) }
        }
        return result
    }

    /// Sorts `ids` into `children(of:)` order (size descending, then name), so a caller can pick
    /// a few children in one unsorted pass and sort only those.
    func sortLikeChildren(_ ids: inout [NodeID]) {
        nameBytes.withUnsafeBufferPointer { arena in
            ids.sort { precedes($0, $1, arena) }
        }
    }

    /// Calls `body` on every child of `id`, in no particular order, without sorting or allocating.
    func forEachChild(of id: NodeID, _ body: (NodeID) -> Void) {
        var c = firstChildren[Int(id)]
        while c >= 0 {
            body(c)
            c = nextSiblings[Int(c)]
        }
    }

    /// The first `limit` of `children(of: id)`, in the same order, found by partial selection: a
    /// bounded heap keeps the best `limit` seen so far, O(n log limit), and only those get sorted.
    public func largestChildren(of id: NodeID, limit: Int) -> [NodeID] {
        guard limit > 0 else { return [] }
        return nameBytes.withUnsafeBufferPointer { arena -> [NodeID] in
            // Max-heap on rank: the root is the worst child kept so far.
            var heap: [NodeID] = []
            heap.reserveCapacity(Swift.min(limit, 1024))
            var c = firstChildren[Int(id)]
            while c >= 0 {
                if heap.count < limit {
                    heap.append(c)
                    var i = heap.count - 1
                    while i > 0 {
                        let up = (i - 1) / 2
                        guard precedes(heap[up], heap[i], arena) else { break }
                        heap.swapAt(up, i)
                        i = up
                    }
                } else if precedes(c, heap[0], arena) {
                    heap[0] = c
                    var i = 0
                    while true {
                        let l = 2 * i + 1, r = l + 1
                        var worst = i
                        if l < heap.count, precedes(heap[worst], heap[l], arena) { worst = l }
                        if r < heap.count, precedes(heap[worst], heap[r], arena) { worst = r }
                        if worst == i { break }
                        heap.swapAt(i, worst)
                        i = worst
                    }
                }
                c = nextSiblings[Int(c)]
            }
            heap.sort { precedes($0, $1, arena) }
            return heap
        }
    }

    /// The order of `children(of:)`: a strict total order, so partial selection agrees with it.
    private func precedes(_ a: NodeID, _ b: NodeID, _ arena: UnsafeBufferPointer<UInt8>) -> Bool {
        let (sa, sb) = (sizes[Int(a)], sizes[Int(b)])
        if sa != sb { return sa > sb }
        let (na, nb) = (arena[nameRange(a)], arena[nameRange(b)])
        if Self.nameLess(na, nb) { return true }
        if Self.nameLess(nb, na) { return false }
        return a > b
    }

    public func row(_ id: NodeID) -> NodeRow {
        NodeRow(id: id, name: name(id), size: sizes[Int(id)], kind: kinds[Int(id)],
                flags: flagsStore[Int(id)], hasChildren: firstChildren[Int(id)] >= 0,
                category: dominantCategory(id), lastUsed: lastUsedStore[Int(id)])
    }

    // MARK: Name arena

    private func appendName(_ name: String) {
        nameBytes.append(contentsOf: name.utf8)
        precondition(nameBytes.count <= Int(UInt32.max), "FileTree name arena exceeds 4 GiB")
        nameEnds.append(UInt32(nameBytes.count))
    }

    private func nameRange(_ id: NodeID) -> Range<Int> {
        let i = Int(id)
        return (i == 0 ? 0 : Int(nameEnds[i - 1]))..<Int(nameEnds[i])
    }

    /// `String.<` on two UTF-8 names. ASCII names (the vast majority) compare bytewise without
    /// allocating, which matches `String.<`; anything else defers to it, since it orders by
    /// canonical equivalence.
    private static func nameLess(_ a: Slice<UnsafeBufferPointer<UInt8>>,
                                 _ b: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        if a.allSatisfy({ $0 < 0x80 }) && b.allSatisfy({ $0 < 0x80 }) {
            return a.lexicographicallyPrecedes(b)
        }
        return String(decoding: a, as: UTF8.self) < String(decoding: b, as: UTF8.self)
    }
}
