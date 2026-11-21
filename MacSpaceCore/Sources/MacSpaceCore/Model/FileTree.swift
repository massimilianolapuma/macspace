/// Compact struct-of-arrays tree for millions of nodes. Not thread-safe; owned by a single actor.
public final class FileTree {
    public static let root: NodeID = 0

    private var parents = ContiguousArray<Int32>()
    private var firstChildren = ContiguousArray<Int32>()
    private var nextSiblings = ContiguousArray<Int32>()
    private var sizes = ContiguousArray<UInt64>()
    private var kinds = ContiguousArray<NodeKind>()
    private var flagsStore = ContiguousArray<NodeFlags>()
    private var names: [String] = []
    private let rootPath: String

    public init(rootName: String, rootPath: String) {
        self.rootPath = rootPath
        parents.append(-1)
        firstChildren.append(-1)
        nextSiblings.append(-1)
        sizes.append(0)
        kinds.append(.directory)
        flagsStore.append([])
        names.append(rootName)
    }

    public var count: Int { names.count }

    /// Adds a node and adds its size to `parent` and every ancestor. O(depth).
    @discardableResult
    public func addChild(of parent: NodeID, name: String, kind: NodeKind,
                         allocatedSize: UInt64, flags: NodeFlags = []) -> NodeID {
        let id = NodeID(names.count)
        parents.append(parent)
        firstChildren.append(-1)
        nextSiblings.append(firstChildren[Int(parent)])
        firstChildren[Int(parent)] = id
        sizes.append(allocatedSize)
        kinds.append(kind)
        flagsStore.append(flags)
        names.append(name)
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

    public func name(_ id: NodeID) -> String { names[Int(id)] }
    public func kind(_ id: NodeID) -> NodeKind { kinds[Int(id)] }
    public func size(_ id: NodeID) -> UInt64 { sizes[Int(id)] }
    public func flags(_ id: NodeID) -> NodeFlags { flagsStore[Int(id)] }

    public func parent(_ id: NodeID) -> NodeID? {
        let p = parents[Int(id)]
        return p < 0 ? nil : p
    }

    public func path(of id: NodeID) -> String {
        var components: [String] = []
        var cur = id
        while cur != Self.root {
            components.append(names[Int(cur)])
            cur = parents[Int(cur)]
        }
        guard !components.isEmpty else { return rootPath }
        let base = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return base + "/" + components.reversed().joined(separator: "/")
    }

    /// Children sorted by size descending, then name ascending.
    public func children(of id: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var c = firstChildren[Int(id)]
        while c >= 0 {
            result.append(c)
            c = nextSiblings[Int(c)]
        }
        result.sort {
            let (sa, sb) = (sizes[Int($0)], sizes[Int($1)])
            return sa != sb ? sa > sb : names[Int($0)] < names[Int($1)]
        }
        return result
    }

    public func row(_ id: NodeID) -> NodeRow {
        NodeRow(id: id, name: names[Int(id)], size: sizes[Int(id)], kind: kinds[Int(id)],
                flags: flagsStore[Int(id)], hasChildren: firstChildren[Int(id)] >= 0)
    }
}
