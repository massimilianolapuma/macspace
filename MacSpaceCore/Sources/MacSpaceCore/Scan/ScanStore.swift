import Foundation

/// Which chart a `ScanStore.snapshot` should lay out.
public enum ChartRequest: Sendable {
    /// `depth` rings of the sunburst.
    case sunburst(depth: Int)
    /// `depth` levels of the treemap in a `width × height` pt canvas.
    case treemap(width: Double, height: Double, depth: Int)
}

/// Owns the `FileTree` being filled by a scan and answers queries about it.
/// All mutation happens here, so the non-Sendable tree never leaves the actor.
public actor ScanStore {
    private let tree: FileTree
    private let classifier: CategoryClassifier
    /// `(device, inode)` of every multiply-linked file already counted.
    private var seenHardLinks = Set<HardLinkKey>()

    /// `home` is the user's home folder, for the classifier's `~/Library` rules. The root's own
    /// context comes from `rootPath` (scanning an `.app` bundle directly makes everything App).
    /// `now` (seconds since 1970, by default the scan start) is what ages are measured from.
    public init(rootName: String, rootPath: String, home: String = NSHomeDirectory(),
                now: UInt32 = UInt32(clamping: Int64(Date().timeIntervalSince1970))) {
        let classifier = CategoryClassifier(home: home)
        let rootContext = classifier.context(forDirectory: (rootPath as NSString).lastPathComponent,
                                             path: rootPath, parent: nil)
        self.classifier = classifier
        tree = FileTree(rootName: rootName, rootPath: rootPath, rootCategory: rootContext ?? .other, now: now)
    }

    /// What `insert` added.
    public struct Inserted: Sendable {
        /// Child directories to descend into.
        public var descend: [(id: NodeID, path: String)]
        /// Bytes added to the tree (hard-link duplicates count 0), so progress can match `rootSize`.
        public var bytes: UInt64
    }

    /// Adds `entries` as children of `parent` (located at `parentPath`) and returns the child
    /// directories to descend into, per `boundary`, with the bytes counted. Symbolic links and
    /// dataless directories are never descended. A file with `linkCount > 1` is counted once
    /// per `(device, inode)`: later links are added with size 0 and `.hardLinkDuplicate`.
    ///
    /// Each entry is classified under `parent`'s context: a directory stores the context it
    /// imposes, anything else its category. Non-directories record `lastUse(modification:access:now:)`
    /// as their last use (duplicates too, though they add no bytes). A directory's own times are
    /// ignored, since merely listing it can update them: its last use is the latest of its contents.
    public func insert(_ entries: [DirectoryEntry], under parent: NodeID, parentPath: String,
                       boundary: ScanBoundary) -> Inserted {
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        let parentContext = tree.context(parent)
        var descend: [(id: NodeID, path: String)] = []
        var bytes: UInt64 = 0
        /// Whether the listing holds a `Cargo.toml`, looked up only once a `target` folder needs it.
        var hasCargoToml: Bool?
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
            bytes &+= size
            guard entry.kind == .directory else {
                tree.addChild(of: parent, name: entry.name, kind: entry.kind, allocatedSize: size, flags: flags,
                              category: classifier.category(forFile: entry.name, context: parentContext),
                              lastUsed: Self.lastUse(modification: entry.modificationTime,
                                                     access: entry.accessTime, now: tree.now))
                continue
            }
            let path = prefix + entry.name
            if hasCargoToml == nil, entry.name == "target" {
                hasCargoToml = entries.contains { $0.kind != .directory && $0.name == "Cargo.toml" }
            }
            let context = classifier.context(forDirectory: entry.name, path: path, parent: parentContext,
                                             siblingHasCargoToml: hasCargoToml ?? false)
            let id = tree.addChild(of: parent, name: entry.name, kind: entry.kind, allocatedSize: size,
                                   flags: flags, category: context ?? .other)
            guard !entry.isDataless else { continue }
            if boundary.shouldDescend(path: path, device: entry.device, isMountPoint: entry.isMountPoint) {
                descend.append((id: id, path: path))
            }
        }
        return Inserted(descend: descend, bytes: bytes)
    }

    public func markUnreadable(_ id: NodeID) {
        tree.insertFlags(.unreadable, for: id)
    }

    public func rootSize() -> UInt64 { tree.size(FileTree.root) }

    public func row(_ id: NodeID) -> NodeRow { tree.row(id) }

    /// The largest `limit` children of `id`, by size descending then name.
    public func rows(childrenOf id: NodeID, limit: Int) -> [NodeRow] {
        tree.largestChildren(of: id, limit: limit).map(tree.row)
    }

    /// Bytes per age bucket below `id`, non-zero entries only.
    public func ageTotals(of id: NodeID) -> [AgeBucket: UInt64] { tree.ageTotals(id) }

    /// Bytes per category below `id`, non-zero entries only.
    public func categoryTotals(of id: NodeID) -> [FileCategory: UInt64] { tree.categoryTotals(id) }

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

    /// A file's last use: the latest of its modification and access times (0 = unknown). A time
    /// more than `futureTolerance` past `now` (the scan start) is a bogus clock, not a use, and is
    /// ignored; if both are, the last use is unknown.
    public static func lastUse(modification: UInt32, access: UInt32, now: UInt32) -> UInt32 {
        let limit = now.addingReportingOverflow(futureTolerance)
        let latest = limit.overflow ? UInt32.max : limit.partialValue
        func valid(_ t: UInt32) -> UInt32 { t <= latest ? t : 0 }
        return max(valid(modification), valid(access))
    }

    /// How far past the scan start a timestamp may lie (clock skew between machines): one day.
    public static let futureTolerance: UInt32 = 86_400

    /// Sunburst ring segments below `center`, `depth` rings deep.
    public func sunburst(center: NodeID, depth: Int) -> [ArcSegment] {
        SunburstLayout.compute(tree: tree, center: center, depth: depth)
    }

    /// Treemap tiles below `center` in a `width × height` canvas, `depth` levels deep.
    public func treemap(center: NodeID, width: Double, height: Double, depth: Int) -> [TreemapTile] {
        TreemapLayout.compute(tree: tree, center: center, width: width, height: height, depth: depth)
    }

    /// Everything the UI shows around `center`, taken in one actor call so the pieces agree
    /// with each other while a scan keeps inserting.
    public struct Snapshot: Sendable {
        /// Sunburst segments; empty unless the request was `.sunburst`.
        public var segments: [ArcSegment]
        /// Treemap tiles; empty unless the request was `.treemap`.
        public var tiles: [TreemapTile]
        /// The `biggestLimit` largest children of `center`.
        public var biggest: [NodeRow]
        /// From the root down to and including `center`.
        public var breadcrumb: [NodeRow]
        /// Bytes per category below `center`, non-zero entries only.
        public var categoryTotals: [FileCategory: UInt64]
        /// Bytes per age bucket below `center`, non-zero entries only.
        public var ageTotals: [AgeBucket: UInt64]
    }

    /// Lays out only the chart `chart` asks for, so the other one costs nothing.
    public func snapshot(center: NodeID, chart: ChartRequest, biggestLimit: Int) -> Snapshot {
        var segments: [ArcSegment] = []
        var tiles: [TreemapTile] = []
        switch chart {
        case .sunburst(let depth):
            segments = sunburst(center: center, depth: depth)
        case .treemap(let width, let height, let depth):
            tiles = treemap(center: center, width: width, height: height, depth: depth)
        }
        return Snapshot(segments: segments, tiles: tiles,
                        biggest: rows(childrenOf: center, limit: biggestLimit),
                        breadcrumb: breadcrumb(to: center),
                        categoryTotals: categoryTotals(of: center), ageTotals: ageTotals(of: center))
    }

    private struct HardLinkKey: Hashable {
        let device: Int32
        let inode: UInt64
    }
}
