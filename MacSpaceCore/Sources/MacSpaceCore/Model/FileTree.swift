/// Compact struct-of-arrays tree for millions of nodes. Not thread-safe; owned by a single actor.
///
/// Names live in one UTF-8 arena (`nameBytes`), delimited by `nameEnds`, instead of one `String`
/// per node: most names are longer than the 15 bytes Swift stores inline, so per-node strings
/// would cost a heap allocation each. Strings are built on demand.
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
    private let rootPath: String

    public init(rootName: String, rootPath: String) {
        self.rootPath = rootPath
        parents.append(-1)
        firstChildren.append(-1)
        nextSiblings.append(-1)
        sizes.append(0)
        kinds.append(.directory)
        flagsStore.append([])
        appendName(rootName)
    }

    public var count: Int { parents.count }

    /// Bytes held by the name arena.
    var nameArenaByteCount: Int { nameBytes.count }

    /// Adds a node and adds its size to `parent` and every ancestor. O(depth).
    @discardableResult
    public func addChild(of parent: NodeID, name: String, kind: NodeKind,
                         allocatedSize: UInt64, flags: NodeFlags = []) -> NodeID {
        let id = NodeID(parents.count)
        parents.append(parent)
        firstChildren.append(-1)
        nextSiblings.append(firstChildren[Int(parent)])
        firstChildren[Int(parent)] = id
        sizes.append(allocatedSize)
        kinds.append(kind)
        flagsStore.append(flags)
        appendName(name)
        if allocatedSize > 0 {
            var p = parent
            while p >= 0 {
                sizes[Int(p)] &+= allocatedSize
                p = parents[Int(p)]
            }
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

    /// Children sorted by size descending, then name ascending (as `String.<` orders them).
    public func children(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var c = firstChildren[Int(id)]
        while c >= 0 {
            result.append(c)
            c = nextSiblings[Int(c)]
        }
        nameBytes.withUnsafeBufferPointer { arena in
            result.sort {
                let (sa, sb) = (sizes[Int($0)], sizes[Int($1)])
                return sa != sb ? sa > sb : Self.nameLess(arena[nameRange($0)], arena[nameRange($1)])
            }
        }
        return result
    }

    public func row(_ id: NodeID) -> NodeRow {
        NodeRow(id: id, name: name(id), size: sizes[Int(id)], kind: kinds[Int(id)],
                flags: flagsStore[Int(id)], hasChildren: firstChildren[Int(id)] >= 0)
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
