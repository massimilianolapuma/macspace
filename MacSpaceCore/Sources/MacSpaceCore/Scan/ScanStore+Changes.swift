import Foundation

/// Step 8 of `trash`: contents added to a folder after the scan (S4). The change history says which
/// folders changed since the scan started; those are listed again and what is new in them is read
/// from disk and judged with the scan's own classification and `SafetyRules`. When the history
/// cannot say, the folder's whole content on disk is read and judged.
extension ScanStore {
    /// What changed in each folder among `items` since the scan started, from one history query.
    /// Every folder that is not removed gets an answer: `.untrusted` without a baseline (a store
    /// filled by hand, a volume without history), for a folder whose device cannot be read, or
    /// for one the history did not answer about. Files are left out: they hold no contents.
    func contentChanges(for items: [NodeID]) -> [NodeID: PathChanges] {
        let folders = items.filter { tree.kind($0) == .directory && !tree.flags($0).contains(.removed) }
        guard !folders.isEmpty else { return [:] }
        var paths: [NodeID: String] = [:]
        for id in folders { paths[id] = tree.path(of: id) }
        guard let baseline = changeBaseline else { return paths.mapValues { _ in .untrusted } }
        var devices: [String: Int32] = [:]
        for path in paths.values {
            if let entry = try? DirectoryReader.stat(path: path) { devices[path] = entry.device }
        }
        let answers = history.changes(since: baseline, under: Array(paths.values), devices: devices)
        return paths.mapValues { answers[$0] ?? .untrusted }
    }

    /// Why the folder `id` at `path` may not go because of what was added to it since the scan, or
    /// nil. `changes` is what the history says (nil: nothing known, as `.untrusted`). Content on a
    /// device outside `devices`, or past `deadline`, is `.containsUnverified`.
    func contentBlocker(_ id: NodeID, path: String, changes: PathChanges?, devices: Set<Int32>,
                        deadline: ContinuousClock.Instant) -> TrashSkip? {
        guard ContinuousClock.now < deadline else { return .containsUnverified }
        guard case .folders(let folders) = changes ?? .untrusted else {
            // The whole folder, as new content; the folder itself was judged by step 3.
            return walk(path, context: tree.context(id), flags: tree.flags(id), devices: devices, deadline: deadline)
        }
        for folder in folders.sorted() {
            guard ContinuousClock.now < deadline else { return .containsUnverified }
            guard let node = tree.node(atPath: folder), node == id || isBelow(node, id),
                  tree.kind(node) == .directory, !tree.flags(node).contains(.removed) else {
                // Not in the tree: inside new content, judged whole where that content starts.
                continue
            }
            if let reason = changedFolderBlocker(node, path: folder, devices: devices, deadline: deadline) {
                return reason
            }
        }
        return nil
    }

    /// The folder `id` at `path`, which the history says changed: listed again, and every entry the
    /// tree does not hold (by name, kind and inode) judged as new content. Gone is fine; replaced by
    /// another object is new content as a whole; unlistable or listed in part is unverified.
    private func changedFolderBlocker(_ id: NodeID, path: String, devices: Set<Int32>,
                                      deadline: ContinuousClock.Instant) -> TrashSkip? {
        let me: DirectoryEntry
        do {
            me = try DirectoryReader.stat(path: path)
        } catch .notFound {
            return nil
        } catch {
            return .containsUnverified
        }
        if me.kind != .directory || !Self.sameObject(me, inode: tree.inode(id)) {
            guard let parent = tree.parent(id) else { return .containsUnverified }
            return judgeNew(me, path: path, parentContext: tree.context(parent), parentFlags: tree.flags(parent),
                            siblings: [], devices: devices, deadline: deadline)
        }
        let listing: DirectoryListing
        do {
            listing = try DirectoryReader.read(path: path)
        } catch .notFound {
            return nil
        } catch {
            return .containsUnverified
        }
        guard listing.isComplete else { return .containsUnverified }
        var known: [String: (kind: NodeKind, inode: UInt64)] = [:]
        tree.forEachChild(of: id) { child in
            if !tree.flags(child).contains(.removed) { known[tree.name(child)] = (tree.kind(child), tree.inode(child)) }
        }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for entry in listing.entries {
            if let old = known[entry.name], old.kind == entry.kind, old.inode == 0 || old.inode == entry.inode {
                continue
            }
            if let reason = judgeNew(entry, path: prefix + entry.name, parentContext: tree.context(id),
                                     parentFlags: tree.flags(id), siblings: listing.entries, devices: devices,
                                     deadline: deadline) {
                return reason
            }
        }
        return nil
    }

    /// New content: `entry` at `path`, classified as the scan would have under a folder with
    /// `parentContext` and `parentFlags`. A file is judged by its own verdict; a folder, with
    /// everything below it on disk.
    private func judgeNew(_ entry: DirectoryEntry, path: String, parentContext: FileCategory?, parentFlags: NodeFlags,
                          siblings: [DirectoryEntry], devices: Set<Int32>,
                          deadline: ContinuousClock.Instant) -> TrashSkip? {
        let isFolder = entry.kind == .directory
        let (category, flags) = classify(entry, path: isFolder ? path : nil, parentContext: parentContext,
                                         parentFlags: parentFlags, siblings: siblings)
        if let reason = judged(entry, path: path, category: category, flags: flags, devices: devices) { return reason }
        guard isFolder else { return nil }
        return walk(path, context: category == .other ? nil : category, flags: flags, devices: devices,
                    deadline: deadline)
    }

    /// Every folder below `path` on disk (whose context is `context` and flags `flags`), each
    /// classified as the scan would and judged by `judged`. Symbolic links are not followed; a
    /// folder that is gone meanwhile is fine; one that cannot be listed, or only in part, is
    /// unverified.
    private func walk(_ path: String, context: FileCategory?, flags: NodeFlags, devices: Set<Int32>,
                      deadline: ContinuousClock.Instant) -> TrashSkip? {
        var stack: [(path: String, context: FileCategory?, flags: NodeFlags)] = [(path, context, flags)]
        while let folder = stack.popLast() {
            guard ContinuousClock.now < deadline else { return .containsUnverified }
            let listing: DirectoryListing
            do {
                listing = try DirectoryReader.read(path: folder.path)
            } catch .notFound {
                continue
            } catch {
                return .containsUnverified
            }
            guard listing.isComplete else { return .containsUnverified }
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            for entry in listing.entries where entry.kind == .directory {
                let child = prefix + entry.name
                let (category, childFlags) = classify(entry, path: child, parentContext: folder.context,
                                                      parentFlags: folder.flags, siblings: listing.entries)
                if let reason = judged(entry, path: child, category: category, flags: childFlags, devices: devices) {
                    return reason
                }
                stack.append((child, category == .other ? nil : category, childFlags))
            }
        }
        return nil
    }

    /// One new object, judged as `subtreeBlocker` judges a folder of the tree: contents not seen
    /// (a mount point, dataless, on a device outside `devices`) are unverified; a verdict protected
    /// for one of `subtreeBlockingReasons` blocks. Size and last use are unknown (0): no blocking
    /// rule depends on them.
    private func judged(_ entry: DirectoryEntry, path: String, category: FileCategory, flags: NodeFlags,
                        devices: Set<Int32>) -> TrashSkip? {
        if entry.kind == .directory, entry.isMountPoint || entry.isDataless || !devices.contains(entry.device) {
            return .containsUnverified
        }
        let facts = NodeFacts(path: path, name: entry.name, kind: entry.kind, flags: flags, size: 0, lastUsed: 0,
                              anchorLastUsed: 0, category: category, isScanRoot: false)
        let verdict = SafetyRules.evaluate(facts, in: environment)
        if verdict.level == .protected, Self.subtreeBlockingReasons.contains(verdict.reason) {
            return .containsProtected(verdict.reason)
        }
        return nil
    }

    /// Whether `node` is a strict descendant of `ancestor`.
    private func isBelow(_ node: NodeID, _ ancestor: NodeID) -> Bool {
        var cur = tree.parent(node)
        while let c = cur {
            if c == ancestor { return true }
            cur = tree.parent(c)
        }
        return false
    }
}
