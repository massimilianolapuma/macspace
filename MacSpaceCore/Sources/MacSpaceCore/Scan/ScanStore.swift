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
    /// Internal (not private) for the `ScanStore+…` extensions.
    let tree: FileTree
    private let classifier: CategoryClassifier
    /// `(device, inode)` of every multiply-linked file already counted.
    private var seenHardLinks = Set<HardLinkKey>()
    /// Installer files (`dmg pkg mpkg xip`) found so far.
    var installerIDs: [NodeID] = []

    /// What `verdict` judges against; see `setEnvironment`.
    var environment: SafetyEnvironment
    /// Verdicts computed since the tree or the environment last changed, or `invalidateVerdicts` was called.
    var verdictCache: [NodeID: SafetyVerdict] = [:]
    /// How many times `SafetyRules.evaluate` ran (cache misses), for tests.
    var verdictEvaluations = 0

    /// How many installer files the scan has found.
    func installerCount() -> Int { installerIDs.count }

    /// `home` is the user's home folder, for the classifier's `~/Library` rules. The root's own
    /// context comes from `rootPath` (scanning an `.app` bundle directly makes everything App).
    /// `now` (seconds since 1970, by default the scan start) is what ages are measured from.
    /// `rootPath` is kept with runs of `/` collapsed and trailing slashes removed (not resolved).
    /// Verdicts start against `SafetyEnvironment.system(home: home, apps: nil)`: nothing in
    /// `~/Library` is judged until `setEnvironment` brings the apps index.
    public init(rootName: String, rootPath rawRootPath: String, home: String = NSHomeDirectory(),
                now: UInt32 = UInt32(clamping: Int64(Date().timeIntervalSince1970))) {
        let rootPath = Self.canonicalRoot(rawRootPath)
        let classifier = CategoryClassifier(home: home)
        let root = RootContext.resolve(rootPath: rootPath, classifier: classifier)
        self.classifier = classifier
        environment = .system(home: home, apps: nil)
        tree = FileTree(rootName: rootName, rootPath: rootPath, rootCategory: root.context ?? .other,
                        rootFlags: root.flags, now: now)
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
    ///
    /// Sizes and last uses of ancestors move, so cached verdicts are dropped.
    public func insert(_ entries: [DirectoryEntry], under parent: NodeID, parentPath: String,
                       boundary: ScanBoundary) -> Inserted {
        dropVerdicts()
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        let parentContext = tree.context(parent)
        let parentFlags = tree.flags(parent)
        let interior: NodeFlags = parentFlags.isDisjoint(with: [.package, .insidePackage]) ? [] : .insidePackage
        var descend: [(id: NodeID, path: String)] = []
        var bytes: UInt64 = 0
        /// Whether the listing holds a `Cargo.toml`, looked up only once a `target` folder needs it.
        var hasCargoToml: Bool?
        for entry in entries {
            var flags = interior
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
                let id = tree.addChild(of: parent, name: entry.name, kind: entry.kind, allocatedSize: size, flags: flags,
                              category: classifier.category(forFile: entry.name, context: parentContext),
                              lastUsed: Self.lastUse(modification: entry.modificationTime,
                                                     access: entry.accessTime, now: tree.now))
                if classifier.isInstaller(fileName: entry.name) { installerIDs.append(id) }
                continue
            }
            let path = prefix + entry.name
            if hasCargoToml == nil, entry.name == "target" {
                hasCargoToml = entries.contains { $0.kind != .directory && $0.name == "Cargo.toml" }
            }
            let context = classifier.context(forDirectory: entry.name, path: path, parent: parentContext,
                                             siblingHasCargoToml: hasCargoToml ?? false)
            if classifier.isPackage(directoryName: entry.name) { flags.insert(.package) }
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
        dropVerdicts()
    }

    public func rootSize() -> UInt64 { tree.size(FileTree.root) }

    /// `id`'s row, with its safety level.
    public func row(_ id: NodeID) -> NodeRow { stamped(tree.row(id)) }

    /// The largest `limit` children of `id`, by size descending then name, with their safety levels.
    public func rows(childrenOf id: NodeID, limit: Int) -> [NodeRow] {
        tree.largestChildren(of: id, limit: limit).map { stamped(tree.row($0)) }
    }

    /// Bytes per age bucket below `id`, non-zero entries only.
    public func ageTotals(of id: NodeID) -> [AgeBucket: UInt64] { tree.ageTotals(id) }

    /// Bytes per category below `id`, non-zero entries only.
    public func categoryTotals(of id: NodeID) -> [FileCategory: UInt64] { tree.categoryTotals(id) }

    /// Rows from the root down to and including `id`, with their safety levels.
    public func breadcrumb(to id: NodeID) -> [NodeRow] {
        var rows = [stamped(tree.row(id))]
        var cur = id
        while let p = tree.parent(cur) {
            rows.append(stamped(tree.row(p)))
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

    /// Sunburst ring segments below `center`, `depth` rings deep, with their safety levels.
    public func sunburst(center: NodeID, depth: Int) -> [ArcSegment] {
        var segments = SunburstLayout.compute(tree: tree, center: center, depth: depth)
        for i in segments.indices {
            if let node = segments[i].node { segments[i].safety = verdict(node).level }
        }
        return segments
    }

    /// Treemap tiles below `center` in a `width × height` canvas, `depth` levels deep, with their
    /// safety levels.
    public func treemap(center: NodeID, width: Double, height: Double, depth: Int) -> [TreemapTile] {
        var tiles = TreemapLayout.compute(tree: tree, center: center, width: width, height: height, depth: depth)
        for i in tiles.indices {
            if let node = tiles[i].node { tiles[i].safety = verdict(node).level }
        }
        return tiles
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
        /// The verdict of every node in `segments`, `tiles`, `biggest` and `breadcrumb`, whose
        /// `safety` is that verdict's level.
        public var verdicts: [NodeID: SafetyVerdict]
    }

    /// Lays out only the chart `chart` asks for, so the other one costs nothing. Each node's
    /// verdict comes from the cache when it has one, so none is evaluated twice.
    public func snapshot(center: NodeID, chart: ChartRequest, biggestLimit: Int) -> Snapshot {
        var segments: [ArcSegment] = []
        var tiles: [TreemapTile] = []
        switch chart {
        case .sunburst(let depth):
            segments = sunburst(center: center, depth: depth)
        case .treemap(let width, let height, let depth):
            tiles = treemap(center: center, width: width, height: height, depth: depth)
        }
        let biggest = rows(childrenOf: center, limit: biggestLimit)
        let crumbs = breadcrumb(to: center)
        var verdicts: [NodeID: SafetyVerdict] = [:]
        for id in segments.compactMap(\.node) + tiles.compactMap(\.node) + (biggest + crumbs).map(\.id) {
            verdicts[id] = verdict(id)
        }
        return Snapshot(segments: segments, tiles: tiles, biggest: biggest, breadcrumb: crumbs,
                        categoryTotals: categoryTotals(of: center), ageTotals: ageTotals(of: center),
                        verdicts: verdicts)
    }

    private struct HardLinkKey: Hashable {
        let device: Int32
        let inode: UInt64
    }
}
