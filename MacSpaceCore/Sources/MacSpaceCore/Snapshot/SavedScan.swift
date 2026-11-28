import Foundation

/// A finished scan, as saved to disk when it ends and shown at once on the next launch (#33):
/// the tree and the store's side tables, plus what a refresh needs to know about when and how it
/// was taken.
///
/// A store restored from it (`ScanStore.init(saved:…)`) can be browsed and judged, but never
/// moves anything: its `scanFinished` stays false, so `trash` and `trashPreview` answer
/// `.scanInProgress` until a scan or refresh of a new store replaces it.
public struct SavedScan: Sendable {
    /// What was scanned.
    public enum Target: Sendable, Equatable {
        case startupDisk
        /// A chosen folder, by its real path.
        case folder(path: String)
    }

    public var target: Target
    /// Wall clock when the scan started, seconds since 1970.
    public var startedAt: UInt32
    /// Whether MacSpace had Full Disk Access when the scan ran.
    public var hadFullDiskAccess: Bool
    /// Where the change history stood when the scan started; nil when it keeps none.
    public var baseline: ChangeBaseline?

    var tree: FileTree.Storage
    /// `ScanStore.hardLinks`, `countedLink` (as the set of counted links), `installerIDs`,
    /// `unverifiedDirectories` and `scanDevices`.
    var hardLinks: [HardLink]
    var installerIDs: [NodeID]
    var unverifiedDirectories: [NodeID]
    var scanDevices: [Int32]

    /// One multiply-linked file: every link in the tree, in insertion order, and the one that
    /// carries its bytes.
    struct HardLink: Sendable, Equatable {
        var device: Int32
        var inode: UInt64
        var links: [NodeID]
        var counted: NodeID?
    }

    /// How many nodes, directories and bytes of names a tree holds.
    public struct TreeSize: Sendable, Equatable {
        public var nodes: Int
        public var directories: Int
        public var nameBytes: Int
    }

    /// The saved tree's size.
    public var treeSize: TreeSize { tree.size }

    /// The scan root's path, as the tree keeps it.
    public var rootPath: String { tree.rootPath }
    /// The scan root's inode when the scan started (0 when unknown).
    public var rootInode: UInt64 { tree.inodes.first ?? 0 }
    /// The scan root's device when the scan started (0 when unknown).
    public var rootDevice: Int32 { tree.dirDevices.first ?? 0 }
}

extension ScanStore {
    /// This store's scan, to save. Call once the scan finished (`markScanFinished`) and before
    /// anything is moved: a store with nodes moved to the Trash still saves, but its snapshot then
    /// keeps them (as removed) until the next scan.
    public func savedScan(target: SavedScan.Target, startedAt: UInt32, hadFullDiskAccess: Bool) -> SavedScan {
        var links: [SavedScan.HardLink] = []
        for (key, ids) in hardLinks {
            links.append(SavedScan.HardLink(device: key.device, inode: key.inode, links: ids,
                                            counted: ids.first { countedLink[$0] != nil }))
        }
        links.sort { ($0.links.first ?? 0) < ($1.links.first ?? 0) }
        return SavedScan(target: target, startedAt: startedAt, hadFullDiskAccess: hadFullDiskAccess,
                         baseline: changeBaseline, tree: tree.saved(), hardLinks: links, installerIDs: installerIDs,
                         unverifiedDirectories: unverifiedDirectories.sorted(), scanDevices: scanDevices.sorted())
    }

    /// A store showing `saved`, with ages measured from `now`: browsable and judged as a scanned
    /// one, but `trash` and `trashPreview` refuse (`.scanInProgress`): its scan is not this
    /// launch's. `home` and `history` as for `init(rootName:rootPath:…)`.
    public init(saved: SavedScan, home: String = NSHomeDirectory(),
                now: UInt32 = UInt32(clamping: Int64(Date().timeIntervalSince1970)),
                history: any ChangeHistory = SystemChangeHistory()) {
        self.init(tree: FileTree(storage: saved.tree, now: now), home: home, history: history, saved: saved)
    }

    /// How big this store's tree is, for a scan of the same target to reserve (`reserveCapacity`).
    public func treeSize() -> SavedScan.TreeSize { tree.saved().size }

    /// Makes room for a tree of `size`, plus a sixteenth for what was added since, before a refresh
    /// or a full scan of the same target fills this store: the arrays then never double (each
    /// doubling copies them and leaves the old buffer to the allocator's cache).
    public func reserveCapacity(for size: SavedScan.TreeSize) {
        tree.reserveCapacity(nodes: size.nodes + size.nodes / 16,
                             directories: size.directories + size.directories / 16,
                             nameBytes: size.nameBytes + size.nameBytes / 16)
    }

    /// `reserveCapacity(for:)` with `saved`'s size.
    public func reserveCapacity(like saved: SavedScan) { reserveCapacity(for: saved.treeSize) }

    /// The tree's capacity (`FileTree.capacity`), for tests.
    func treeCapacity() -> (nodes: Int, directories: Int, nameBytes: Int) { tree.capacity }

    /// The directory `id`'s device as listed (`FileTree.device(ofDirectory:)`).
    public func device(ofDirectory id: NodeID) -> Int32 { tree.device(ofDirectory: id) }
}

extension FileTree.Storage {
    var size: SavedScan.TreeSize {
        SavedScan.TreeSize(nodes: count, directories: dirDevices.count, nameBytes: nameBytes.count)
    }
}
