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
    let classifier: CategoryClassifier
    /// Where `trash` learns which folders changed since the scan started (S4).
    nonisolated let history: any ChangeHistory
    /// The history's position when the scan started (`markScanStarted`); nil for a store filled by
    /// hand, or a volume without history: `trash` then re-reads every folder it moves.
    var changeBaseline: ChangeBaseline?
    /// Every link of each multiply-linked file (`linkCount > 1`) in the tree, in insertion (ID)
    /// order. Only one of them carries the file's bytes: the one in `countedLink`.
    var hardLinks: [HardLinkKey: [NodeID]] = [:]
    /// The link carrying each multiply-linked file's bytes; the others have size 0 and
    /// `.hardLinkDuplicate`. `trash` hands the bytes to another link when this one leaves the tree.
    var countedLink: [NodeID: HardLinkKey] = [:]
    /// Installer files (`dmg pkg mpkg xip`) found so far.
    var installerIDs: [NodeID] = []

    /// What `verdict` judges against; see `setEnvironment`.
    var environment: SafetyEnvironment
    /// Verdicts computed since the tree or the environment last changed, or `invalidateVerdicts` was called.
    var verdictCache: [NodeID: SafetyVerdict] = [:]
    /// How many times `SafetyRules.evaluate` ran (cache misses), for tests.
    var verdictEvaluations = 0

    /// Whether the scan filling this store has ended (normally or cancelled); `trash` waits for it.
    var scanFinished = false
    /// Devices the scan was allowed on; items found on another device at Trash time have changed.
    var scanDevices: Set<Int32> = []
    /// Directories whose contents are unknown: not descended by the boundary (excluded, or on
    /// another device) or dataless (only in the cloud), never listed by a cancelled scan, or listed
    /// only in part (cancelled meanwhile, or an entry the file system reported an error for was left
    /// out).
    var unverifiedDirectories: Set<NodeID> = []

    /// Called by `Scanner.scan(into:)` when it ends, normally or cancelled (tests that fill a store
    /// by hand call it themselves): records the devices the scan was confined to and the
    /// directories whose contents it did not fully list (added to those `insert` did not descend),
    /// and allows `trash`.
    public func markScanFinished(allowedDevices: Set<Int32> = [], unverifiedDirectories: [NodeID] = []) {
        scanFinished = true
        scanDevices = allowedDevices
        self.unverifiedDirectories.formUnion(unverifiedDirectories)
    }

    /// Called by `Scanner.scan(into:)` before it reads anything: records the scan root's inode
    /// (0 when it could not be read), so `trash` can tell the root folder from one put in its place,
    /// and where the change history stood (`history.baseline`), so `trash` can ask what changed since.
    /// `rootDevice` (0 when unknown) is kept with the tree, for a refresh to compare folders by.
    public func markScanStarted(rootInode: UInt64, rootDevice: Int32 = 0, baseline: ChangeBaseline?) {
        tree.setInode(rootInode, for: FileTree.root)
        tree.setDevice(rootDevice, forDirectory: FileTree.root)
        changeBaseline = baseline
    }

    /// How many installer files the scan has found.
    func installerCount() -> Int { installerIDs.count }

    /// `home` is the user's home folder, for the classifier's `~/Library` rules. The root's own
    /// context comes from `rootPath` (scanning an `.app` bundle directly makes everything App).
    /// `now` (seconds since 1970, by default the scan start) is what ages are measured from.
    /// `rootPath` is kept with runs of `/` collapsed and trailing slashes removed (not resolved).
    /// Verdicts start against `SafetyEnvironment.system(home: home, apps: nil)`: nothing in
    /// `~/Library` is judged until `setEnvironment` brings the apps index. `history` tells `trash`
    /// what changed on disk since the scan started.
    public init(rootName: String, rootPath rawRootPath: String, home: String = NSHomeDirectory(),
                now: UInt32 = UInt32(clamping: Int64(Date().timeIntervalSince1970)),
                history: any ChangeHistory = SystemChangeHistory()) {
        let rootPath = Self.canonicalRoot(rawRootPath)
        let classifier = CategoryClassifier(home: home)
        let root = RootContext.resolve(rootPath: rootPath, classifier: classifier)
        self.init(tree: FileTree(rootName: rootName, rootPath: rootPath, rootCategory: root.context ?? .other,
                                 rootFlags: root.flags, now: now),
                  home: home, history: history)
    }

    /// A store over `tree`, with the side tables of `saved` when restoring one (`init(saved:…)`):
    /// verdicts start as for `init(rootName:…)`.
    init(tree: FileTree, home: String, history: any ChangeHistory, saved: SavedScan? = nil) {
        self.history = history
        classifier = CategoryClassifier(home: home)
        environment = .system(home: home, apps: nil)
        self.tree = tree
        guard let saved else { return }
        changeBaseline = saved.baseline
        for link in saved.hardLinks {
            let key = HardLinkKey(device: link.device, inode: link.inode)
            hardLinks[key] = link.links
            if let counted = link.counted { countedLink[counted] = key }
        }
        installerIDs = saved.installerIDs
        unverifiedDirectories = Set(saved.unverifiedDirectories)
        scanDevices = Set(saved.scanDevices)
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
    /// dataless directories are never descended; a dataless directory, like one the boundary does
    /// not descend (a mount point aside), joins `unverifiedDirectories`, since its contents are
    /// never seen: `trash` skips it, and any folder holding it, as `.containsUnverified`. A file
    /// with `linkCount > 1` is counted once per `(device, inode)`: later links are added with size 0
    /// and `.hardLinkDuplicate` (all are kept in `hardLinks`, so `trash` can move the bytes).
    ///
    /// Each entry is classified under `parent`'s context: a directory stores the context it
    /// imposes, anything else its category. Non-directories record `lastUse(modification:access:now:)`
    /// as their last use (duplicates too, though they add no bytes). A directory's own times are
    /// ignored, since merely listing it can update them: its last use is the latest of its contents.
    ///
    /// Sizes and last uses of ancestors move, so cached verdicts are dropped. Adds nothing under a
    /// `parent` that was moved to the Trash.
    public func insert(_ entries: [DirectoryEntry], under parent: NodeID, parentPath: String,
                       boundary: ScanBoundary) -> Inserted {
        // Moved to the Trash meanwhile: its contents are gone, adding them would corrupt the totals.
        guard !tree.flags(parent).contains(.removed) else { return Inserted(descend: [], bytes: 0) }
        dropVerdicts()
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        let parentContext = tree.context(parent)
        let parentFlags = tree.flags(parent)
        var descend: [(id: NodeID, path: String)] = []
        var bytes: UInt64 = 0
        for entry in entries {
            let path = entry.kind == .directory ? prefix + entry.name : nil
            let (category, classified) = classify(entry, path: path, parentContext: parentContext,
                                                  parentFlags: parentFlags, siblings: entries)
            var flags = classified
            var size = entry.allocatedSize
            let linkKey = entry.kind != .directory && entry.linkCount > 1
                ? HardLinkKey(device: entry.device, inode: entry.inode) : nil
            let isCounted = linkKey.map { hardLinks[$0] == nil } ?? true
            if !isCounted {
                flags.insert(.hardLinkDuplicate)
                size = 0
            }
            bytes &+= size
            guard let path else {
                let id = tree.addChild(of: parent, name: entry.name, kind: entry.kind, allocatedSize: size, flags: flags,
                              category: category,
                              lastUsed: Self.lastUse(modification: entry.modificationTime,
                                                     access: entry.accessTime, now: tree.now),
                              inode: entry.inode)
                if let linkKey {
                    hardLinks[linkKey, default: []].append(id)
                    if isCounted { countedLink[id] = linkKey }
                }
                if classifier.isInstaller(fileName: entry.name) { installerIDs.append(id) }
                continue
            }
            let id = tree.addChild(of: parent, name: entry.name, kind: entry.kind, allocatedSize: size,
                                   flags: flags, category: category, inode: entry.inode, device: entry.device)
            // Only in the cloud: its contents are never listed, so they are unknown (fail closed).
            guard !entry.isDataless else {
                unverifiedDirectories.insert(id)
                continue
            }
            if boundary.shouldDescend(path: path, device: entry.device, isMountPoint: entry.isMountPoint) {
                descend.append((id: id, path: path))
            } else if !entry.isMountPoint {
                // Excluded or on another device: its contents are never seen (mount points are flagged).
                unverifiedDirectories.insert(id)
            }
        }
        return Inserted(descend: descend, bytes: bytes)
    }

    /// How the scan classifies `entry`, listed with `siblings` in a folder whose context is
    /// `parentContext` and whose flags are `parentFlags`: its category (for a directory, the context
    /// it imposes, `.other` for none) and its flags (`.insidePackage` below a package, `.dataless`,
    /// `.mountPoint`, `.package`). `path` is the entry's path, needed for a directory (nil for
    /// anything else). `insert` and the content check of `trash` both use it, so new content is
    /// judged as a scan would have seen it.
    func classify(_ entry: DirectoryEntry, path: String?, parentContext: FileCategory?, parentFlags: NodeFlags,
                  siblings: [DirectoryEntry]) -> (category: FileCategory, flags: NodeFlags) {
        var flags: NodeFlags = parentFlags.isDisjoint(with: [.package, .insidePackage]) ? [] : .insidePackage
        if entry.isDataless { flags.insert(.dataless) }
        if entry.isMountPoint { flags.insert(.mountPoint) }
        guard entry.kind == .directory else {
            return (classifier.category(forFile: entry.name, context: parentContext), flags)
        }
        let hasCargoToml = entry.name == "target"
            && siblings.contains { $0.kind != .directory && $0.name == "Cargo.toml" }
        let context = classifier.context(forDirectory: entry.name, path: path ?? entry.name, parent: parentContext,
                                         siblingHasCargoToml: hasCargoToml)
        if classifier.isPackage(directoryName: entry.name) { flags.insert(.package) }
        return (context ?? .other, flags)
    }

    public func markUnreadable(_ id: NodeID) {
        tree.insertFlags(.unreadable, for: id)
        dropVerdicts()
    }

    public func rootSize() -> UInt64 { tree.size(FileTree.root) }

    /// `id`'s row, with its safety level; nil for an ID that is not in this tree (`contains`).
    public func row(_ id: NodeID) -> NodeRow? { contains(id) ? stamped(tree.row(id)) : nil }

    /// Whether `id` names a node of this store's tree. IDs are per store: one kept from an earlier
    /// scan's store may be out of range here (every other query traps on it) or name another node.
    public func contains(_ id: NodeID) -> Bool { id >= 0 && Int(id) < tree.count }

    /// The largest `limit` children of `id`, by size descending then name, with their safety levels;
    /// none for an ID that is not in this tree.
    public func rows(childrenOf id: NodeID, limit: Int) -> [NodeRow] {
        guard contains(id) else { return [] }
        return tree.largestChildren(of: id, limit: limit).map { stamped(tree.row($0)) }
    }

    /// Bytes per age bucket below `id`, non-zero entries only.
    public func ageTotals(of id: NodeID) -> [AgeBucket: UInt64] { tree.ageTotals(id) }

    /// Bytes per category below `id`, non-zero entries only.
    public func categoryTotals(of id: NodeID) -> [FileCategory: UInt64] { tree.categoryTotals(id) }

    /// Rows from the root down to and including `id`, with their safety levels; none for an ID that
    /// is not in this tree.
    public func breadcrumb(to id: NodeID) -> [NodeRow] {
        guard contains(id) else { return [] }
        var rows = [stamped(tree.row(id))]
        var cur = id
        while let p = tree.parent(cur) {
            rows.append(stamped(tree.row(p)))
            cur = p
        }
        return rows.reversed()
    }

    /// `id`'s absolute path; nil for an ID that is not in this tree.
    public func path(of id: NodeID) -> String? { contains(id) ? tree.path(of: id) : nil }

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
            if let node = segments[i].node { segments[i].safety = judged(node).level }
        }
        return segments
    }

    /// Treemap tiles below `center` in a `width × height` canvas, `depth` levels deep, with their
    /// safety levels.
    public func treemap(center: NodeID, width: Double, height: Double, depth: Int) -> [TreemapTile] {
        var tiles = TreemapLayout.compute(tree: tree, center: center, width: width, height: height, depth: depth)
        for i in tiles.indices {
            if let node = tiles[i].node { tiles[i].safety = judged(node).level }
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
    /// verdict comes from the cache when it has one, so none is evaluated twice. Called from a task
    /// that is already cancelled (a request superseded while it queued on this actor), it does none
    /// of that and returns an empty snapshot, which its caller discards.
    public func snapshot(center: NodeID, chart: ChartRequest, biggestLimit: Int) -> Snapshot {
        // A request superseded while it queued on this actor (cancelled) skips the work: its caller
        // discards the result. A center from another store (a stale request racing a new scan)
        // shows nothing.
        guard !Task.isCancelled, contains(center) else {
            return Snapshot(segments: [], tiles: [], biggest: [], breadcrumb: [], categoryTotals: [:], ageTotals: [:],
                            verdicts: [:])
        }
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
            verdicts[id] = judged(id)
        }
        return Snapshot(segments: segments, tiles: tiles, biggest: biggest, breadcrumb: crumbs,
                        categoryTotals: categoryTotals(of: center), ageTotals: ageTotals(of: center),
                        verdicts: verdicts)
    }

    struct HardLinkKey: Hashable {
        let device: Int32
        let inode: UInt64
    }
}
