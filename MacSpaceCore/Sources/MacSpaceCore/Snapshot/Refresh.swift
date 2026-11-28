import Foundation
import Synchronization

/// How to bring a saved scan up to date (#33).
public enum RefreshPlan: Sendable, Equatable {
    /// Rebuild through the scanner, reading from disk only these folders (paths in the tree's
    /// spelling) and whatever the snapshot cannot vouch for (`SavedScan.listingReader`).
    case incremental(changed: Set<String>)
    /// Scan everything again.
    case fullScan(FullScanReason)
}

/// Why a saved scan cannot be refreshed and is scanned again in full.
public enum FullScanReason: Sendable, Equatable {
    /// Older than `SavedScan.maxRefreshAge`: history purged without a trace, and hard links
    /// changed since, are bounded by it.
    case tooOld
    /// The root folder is another one (another inode).
    case rootReplaced
    /// Full Disk Access was granted when the scan ran and is not now: changes inside protected
    /// folders may then be hidden from the history.
    case fullDiskAccessLost
    /// The scan's volume kept no history.
    case noBaseline
    /// The history cannot vouch for what changed (events dropped, another volume UUID, a timeout).
    case historyUntrusted
}

extension SavedScan {
    /// Seven days.
    public static let maxRefreshAge: UInt32 = 7 * 86_400

    /// How to refresh this scan now. The reasons are checked in `FullScanReason`'s order, and the
    /// history is asked (once, about the root) only when none applies. `rootInode` is the root's
    /// inode now.
    public func refreshPlan(now: UInt32, rootInode: UInt64, hasFullDiskAccess: Bool,
                            history: any ChangeHistory) -> RefreshPlan {
        if now > startedAt, now - startedAt > Self.maxRefreshAge { return .fullScan(.tooOld) }
        guard rootInode == self.rootInode else { return .fullScan(.rootReplaced) }
        guard hasFullDiskAccess || !hadFullDiskAccess else { return .fullScan(.fullDiskAccessLost) }
        guard let baseline else { return .fullScan(.noBaseline) }
        let answers = history.changes(since: baseline, under: [rootPath], devices: [rootPath: rootDevice])
        guard case let .folders(changed) = answers[rootPath] ?? .untrusted else { return .fullScan(.historyUntrusted) }
        return .incremental(changed: changed)
    }

    /// The reader of an incremental refresh. A folder's saved listing is used when the folder
    ///   - is not in `changed`;
    ///   - is in the snapshot, reached through its parent's listing, with the request's device and
    ///     inode (a folder replaced by another at the same path differs, and only its parent was
    ///     reported changed);
    ///   - was neither unreadable nor unverified (partial, never listed) there.
    /// Everything else is read by `disk`. A saved listing gives each entry as the scan read it:
    /// a hard-link duplicate with its counted link's size, links with `linkCount` 2, a file's last
    /// use as its modification time.
    ///
    /// Folders are found by path: the reader remembers, for every subfolder of a listing it gave,
    /// which saved node it is (nil: not in the snapshot), and forgets it once that folder is asked
    /// for, so it holds only the folders still waiting to be read.
    public func listingReader(changed: Set<String>,
                              disk: @escaping ListingReader = { request throws(DirectoryReadError) in
                                  try DirectoryReader.read(path: request.path)
                              }) -> ListingReader {
        let index = SavedListings(self)
        return { request throws(DirectoryReadError) in
            let node = index.take(request.path)
            if !changed.contains(request.path), let node, index.vouches(for: node, request) {
                let listing = index.listing(of: node)
                index.remember(children: listing.directories, under: request.path)
                return listing.listing
            }
            let listing = try disk(request)
            index.remember(entries: listing, under: request.path, savedParent: node)
            return listing
        }
    }
}

/// What `listingReader` reads saved listings from; shared by the scan's concurrent reads.
private final class SavedListings: Sendable {
    let tree: FileTree.Storage
    /// Saved node per folder path still waiting to be read (nil: not in the snapshot).
    let waiting: Mutex<[String: NodeID?]>
    /// The bytes each multiply-linked node's file carries (its counted link's size).
    let linkedSize: [NodeID: UInt64]
    let unverified: Set<NodeID>

    init(_ saved: SavedScan) {
        tree = saved.tree
        var sizes: [NodeID: UInt64] = [:]
        for link in saved.hardLinks {
            let bytes = link.counted.map { saved.tree.sizes[Int($0)] } ?? 0
            for id in link.links { sizes[id] = bytes }
        }
        linkedSize = sizes
        unverified = Set(saved.unverifiedDirectories)
        waiting = Mutex([saved.rootPath: FileTree.root])
    }

    /// The saved node at `path`, if its parent's listing named one; forgotten from now on.
    func take(_ path: String) -> NodeID? {
        waiting.withLock { $0.removeValue(forKey: path) ?? nil }
    }

    /// Whether `node`'s saved listing can stand for the folder `request` names.
    func vouches(for node: NodeID, _ request: DirectoryRequest) -> Bool {
        let i = Int(node)
        let slot = tree.dirSlots[i]
        return slot >= 0 && tree.flags[i].isDisjoint(with: [.unreadable, .removed]) && !unverified.contains(node)
            && tree.inodes[i] == request.inode && tree.dirDevices[Int(slot)] == request.device
    }

    /// `node`'s saved listing, and its subfolders by name.
    func listing(of node: NodeID) -> (listing: DirectoryListing, directories: [(name: String, id: NodeID)]) {
        let device = tree.dirDevices[Int(tree.dirSlots[Int(node)])]
        var entries: [DirectoryEntry] = []
        var directories: [(name: String, id: NodeID)] = []
        var child = tree.firstChildren[Int(node)]
        while child >= 0 {
            let i = Int(child)
            defer { child = tree.nextSiblings[i] }
            guard !tree.flags[i].contains(.removed) else { continue }
            let name = self.name(i)
            let kind = tree.kinds[i]
            let flags = tree.flags[i]
            let slot = tree.dirSlots[i]
            let linked = linkedSize[child]
            entries.append(DirectoryEntry(
                name: name, kind: kind, allocatedSize: kind == .directory ? 0 : linked ?? tree.sizes[i],
                device: slot >= 0 ? tree.dirDevices[Int(slot)] : device, inode: tree.inodes[i],
                linkCount: linked == nil ? 1 : 2, isMountPoint: flags.contains(.mountPoint),
                isDataless: flags.contains(.dataless), modificationTime: kind == .directory ? 0 : tree.lastUsed[i]))
            if kind == .directory { directories.append((name, child)) }
        }
        // The disk's order, as near as the tree keeps it: oldest first.
        entries.reverse()
        return (DirectoryListing(entries: entries, isComplete: true), directories)
    }

    /// Remembers the saved subfolders of a saved listing.
    func remember(children: [(name: String, id: NodeID)], under parent: String) {
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        waiting.withLock { waiting in
            for (name, id) in children { waiting[prefix + name] = id }
        }
    }

    /// Remembers, for each subfolder of a listing read from disk, the saved folder of that name
    /// under `savedParent` (nil when there is none).
    func remember(entries listing: DirectoryListing, under parent: String, savedParent: NodeID?) {
        var saved: [String: NodeID] = [:]
        if let savedParent {
            var child = tree.firstChildren[Int(savedParent)]
            while child >= 0 {
                let i = Int(child)
                if tree.kinds[i] == .directory, !tree.flags[i].contains(.removed) { saved[name(i)] = child }
                child = tree.nextSiblings[i]
            }
        }
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        waiting.withLock { waiting in
            for entry in listing.entries where entry.kind == .directory {
                waiting[prefix + entry.name] = .some(saved[entry.name])
            }
        }
    }

    private func name(_ i: Int) -> String {
        let start = i == 0 ? 0 : Int(tree.nameEnds[i - 1])
        return tree.nameBytes.withUnsafeBufferPointer {
            String(decoding: $0[start..<Int(tree.nameEnds[i])], as: UTF8.self)
        }
    }
}
