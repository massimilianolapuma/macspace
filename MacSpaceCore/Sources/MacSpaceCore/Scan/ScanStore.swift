/// Owns the `FileTree` being filled by a scan and answers queries about it.
/// All mutation happens here, so the non-Sendable tree never leaves the actor.
public actor ScanStore {
    private let tree: FileTree
    /// `(device, inode)` of every multiply-linked file already counted.
    private var seenHardLinks = Set<HardLinkKey>()

    public init(rootName: String, rootPath: String) {
        tree = FileTree(rootName: rootName, rootPath: rootPath)
    }

    /// Adds `entries` as children of `parent` (located at `parentPath`) and returns the child
    /// directories to descend into, per `boundary`. Symbolic links and dataless directories are
    /// never descended. A file with `linkCount > 1` is counted once per `(device, inode)`:
    /// later links are added with size 0 and `.hardLinkDuplicate`.
    public func insert(_ entries: [DirectoryEntry], under parent: NodeID, parentPath: String,
                       boundary: ScanBoundary) -> [(id: NodeID, path: String)] {
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        var descend: [(id: NodeID, path: String)] = []
        for entry in entries {
            var flags: NodeFlags = []
            if entry.isDataless { flags.insert(.dataless) }
            if entry.isMountPoint { flags.insert(.mountPoint) }
            var size = entry.allocatedSize
            if entry.kind != .directory, entry.linkCount > 1,
               !seenHardLinks.insert(HardLinkKey(device: entry.device, inode: entry.inode)).inserted {
                flags.insert(.hardLinkDuplicate)
                size = 0
            }
            let id = tree.addChild(of: parent, name: entry.name, kind: entry.kind,
                                   allocatedSize: size, flags: flags)
            guard entry.kind == .directory, !entry.isDataless else { continue }
            let path = prefix + entry.name
            if boundary.shouldDescend(path: path, device: entry.device, isMountPoint: entry.isMountPoint) {
                descend.append((id: id, path: path))
            }
        }
        return descend
    }

    public func markUnreadable(_ id: NodeID) {
        tree.insertFlags(.unreadable, for: id)
    }

    public func rootSize() -> UInt64 { tree.size(FileTree.root) }

    public func row(_ id: NodeID) -> NodeRow { tree.row(id) }

    /// The largest `limit` children of `id`, by size descending then name.
    public func rows(childrenOf id: NodeID, limit: Int) -> [NodeRow] {
        tree.children(of: id).prefix(limit).map(tree.row)
    }

    /// Rows from the root down to and including `id`.
    public func breadcrumb(to id: NodeID) -> [NodeRow] {
        var rows = [tree.row(id)]
        var cur = id
        while let p = tree.parent(cur) {
            rows.append(tree.row(p))
            cur = p
        }
        return rows.reversed()
    }

    public func path(of id: NodeID) -> String { tree.path(of: id) }

    /// Sunburst ring segments below `center`, `depth` rings deep.
    public func sunburst(center: NodeID, depth: Int) -> [ArcSegment] {
        SunburstLayout.compute(tree: tree, center: center, depth: depth)
    }

    private struct HardLinkKey: Hashable {
        let device: Int32
        let inode: UInt64
    }
}
