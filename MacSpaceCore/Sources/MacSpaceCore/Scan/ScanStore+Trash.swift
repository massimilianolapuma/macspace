import Darwin
import Foundation

/// Moving user-confirmed items to the Trash, re-verified right before each move.
extension ScanStore {
    /// The selection reduced to what can be moved on its own: ids that are not in the tree (stale,
    /// from another scan), the root, removed ids and ids below another selected id are dropped.
    /// Sorted by size descending, then id.
    public func topMost(_ ids: Set<NodeID>) -> [NodeID] { topMost(ids, keepingRemoved: false) }

    /// `topMost`, optionally keeping removed ids, so `trash` can report them as `.missing`.
    func topMost(_ ids: Set<NodeID>, keepingRemoved: Bool) -> [NodeID] {
        let valid = ids.filter { $0 > FileTree.root && Int($0) < tree.count }
        let kept = valid.filter { id in
            if !keepingRemoved, tree.flags(id).contains(.removed) { return false }
            var ancestor = tree.parent(id)
            while let a = ancestor {
                if valid.contains(a) { return false }
                ancestor = tree.parent(a)
            }
            return true
        }
        return kept.sorted { a, b in
            let (sa, sb) = (tree.size(a), tree.size(b))
            return sa != sb ? sa > sb : a < b
        }
    }

    /// Moves each `topMost` item of `ids` to the Trash with `actions`, after re-checking it, and
    /// takes what moved out of the tree. Every check fails closed; an item is skipped at the first
    /// one that fails. Before any item:
    /// - the scan has not finished (`markScanFinished`): every item → `.scanInProgress`, nothing
    ///   moves and `openFiles` is not called;
    /// - otherwise `openFiles()` is called exactly once; if incomplete, every item →
    ///   `.cannotCheckOpenFiles` and nothing moves;
    /// - the current mount table is read once (`getfsstat`); if it cannot be read, every item →
    ///   `.containsUnverified` and nothing moves.
    ///
    /// Then per item, in this order:
    /// 1. removed already (it or a folder above it) → `.missing`;
    /// 2. `TrashGuard` refuses it, or the scan saw it as a mount point → `.refused`;
    /// 3. a fresh `SafetyRules` verdict (not the cache) is protected → `.protected(reason)`; its
    ///    level differs from the one in `expectedLevels` (what the user confirmed), or the map has
    ///    none for it → `.verdictChanged`;
    /// 4. a folder above it, up to `/`, is a package per `packages` → `.insidePackage`;
    /// 5. it or a file inside it is open → `.openNow`;
    /// 6. a folder holding something the rules protect as a whole (Apple data, a Photos library, a
    ///    running app or its data, an essential, system or Trash folder, an unusual path), or a
    ///    running app's bundle → `.protected(reason)`; a folder whose contents were not all seen
    ///    (it or a folder inside it is a mount point, unreadable, not fully listed or not descended
    ///    by the scan, or a volume is mounted at or below it right now) → `.containsUnverified`;
    /// 7. on disk, checked last, right before the move: gone → `.missing`; cannot be examined →
    ///    `.failed`; another kind of object than scanned, now a mount point, on a device the scan
    ///    was not confined to, or a folder above it (up to the scan root) no longer a folder → `.changed`;
    /// 8. `moveToTrash` throws → `.failed(error.localizedDescription)`.
    ///
    /// Residual window: between the step-7 `stat` and the rename inside `moveToTrash` the item can
    /// still be swapped; its identity is checked by kind, mount status and device only (not inode).
    /// Verdicts are dropped afterwards, since sizes and contents moved.
    ///
    /// `expectedLevels`: the level each item had when the user confirmed it. With a map, an item
    /// absent from it was never confirmed and is skipped `.verdictChanged` (fail closed); a nil map
    /// compares nothing. It has no default: a caller that confirms no levels says so with `nil`.
    public func trash(_ ids: Set<NodeID>, actions: any DiskActions, packages: any PackageProbe,
                      openFiles: @Sendable () -> OpenFileSet,
                      expectedLevels: [NodeID: SafetyLevel]?) -> TrashOutcome {
        trash(ids, actions: actions, packages: packages, openFiles: openFiles, expectedLevels: expectedLevels,
              mountPoints: MountTable.current)
    }

    /// `trash` with the mount table injectable for tests: `mountPoints` returns every mount-on
    /// path, or nil when they cannot be read.
    func trash(_ ids: Set<NodeID>, actions: any DiskActions, packages: any PackageProbe,
               openFiles: @Sendable () -> OpenFileSet, expectedLevels: [NodeID: SafetyLevel]?,
               mountPoints: () -> [String]?) -> TrashOutcome {
        defer { verdictCache.removeAll() }
        let items = topMost(ids, keepingRemoved: true)
        var outcome = TrashOutcome()
        func skipAll(_ reason: TrashSkip) -> TrashOutcome {
            outcome.skipped = items.map { TrashOutcome.Skipped(node: $0, name: tree.name($0), reason: reason) }
            return outcome
        }
        guard scanFinished else { return skipAll(.scanInProgress) }
        let open = openFiles()
        guard open.isComplete else { return skipAll(.cannotCheckOpenFiles) }
        guard let rawMounts = mountPoints() else { return skipAll(.containsUnverified) }
        let mounts = MountTable.canonical(rawMounts)
        let devices = allowedDevices()
        for id in items {
            let name = tree.name(id)
            if let reason = trashBlocker(id, open: open, packages: packages, mounts: mounts, devices: devices,
                                         comparesLevel: expectedLevels != nil, expectedLevel: expectedLevels?[id]) {
                outcome.skipped.append(TrashOutcome.Skipped(node: id, name: name, reason: reason))
                continue
            }
            let size = tree.size(id)
            do {
                let trashed = try actions.moveToTrash(tree.path(of: id))
                tree.remove(id)
                dropVerdicts()
                outcome.moved.append(TrashOutcome.Moved(node: id, name: name, size: size, trashedPath: trashed))
            } catch {
                outcome.skipped.append(TrashOutcome.Skipped(node: id, name: name,
                                                            reason: .failed(error.localizedDescription)))
            }
        }
        return outcome
    }

    /// The devices items must still be on: those the scan was confined to, or, when none were
    /// recorded, the scan root's current device (stat once per `trash` call). Empty if neither is known.
    private func allowedDevices() -> Set<Int32> {
        if !scanDevices.isEmpty { return scanDevices }
        guard let root = try? DirectoryReader.stat(path: tree.path(of: FileTree.root)) else { return [] }
        return [root.device]
    }

    /// Checks 1–7 of `trash` for one item: the first failing one, or nil when it may move.
    private func trashBlocker(_ id: NodeID, open: OpenFileSet, packages: any PackageProbe,
                              mounts: [String], devices: Set<Int32>, comparesLevel: Bool,
                              expectedLevel: SafetyLevel?) -> TrashSkip? {
        // 1. Already moved (`remove` marks the whole subtree).
        if tree.flags(id).contains(.removed) { return .missing }
        let path = tree.path(of: id)
        // 2. The independent guard; a mount point is never moved (it would take a volume along).
        if TrashGuard.refusal(path: path, home: environment.home) != nil { return .refused }
        if tree.flags(id).contains(.mountPoint) { return .refused }
        // 3. Fresh verdict, bypassing the cache.
        let verdict = SafetyRules.evaluate(facts(id), in: environment)
        if verdict.level == .protected { return .protected(verdict.reason) }
        // Not what the user saw when confirming (an app launched or quit meanwhile, say), or never
        // confirmed at all (no level for it).
        if comparesLevel, verdict.level != expectedLevel { return .verdictChanged }
        // 4. Inside a package LaunchServices knows of (registered types too).
        if Self.ancestorPaths(of: path).contains(where: packages.isPackage) { return .insidePackage }
        // 5. Open right now.
        let kind = tree.kind(id)
        if kind == .directory {
            if open.isOpen(path) || open.hasOpen(under: path) { return .openNow }
        } else if open.isOpen(path) {
            return .openNow
        }
        // 6. A volume mounted at or below it now (perhaps after the scan); something inside it
        //    that must never go, or contents never seen.
        if MountTable.hasMount(atOrBelow: path, in: mounts) { return .containsUnverified }
        if kind == .directory, let reason = subtreeBlocker(id, path: path) { return reason }
        // 7. On disk, last: the same kind of object, on a scanned device, reached through the same folders.
        let entry: DirectoryEntry
        do {
            entry = try DirectoryReader.stat(path: path)
        } catch .notFound {
            return .missing
        } catch {
            return .failed(Self.message(for: error))
        }
        if let change = Self.onDiskChange(entry, kind: kind, devices: devices) { return change }
        var ancestor = tree.parent(id)
        while let a = ancestor {
            guard (try? DirectoryReader.stat(path: tree.path(of: a)))?.kind == .directory else { return .changed }
            ancestor = tree.parent(a)
        }
        return nil
    }

    /// `.changed` when a fresh `stat` of an item no longer matches the scan: another kind than
    /// `kind`, a mount point, or a device outside `devices` (an empty set matches nothing).
    static func onDiskChange(_ entry: DirectoryEntry, kind: NodeKind, devices: Set<Int32>) -> TrashSkip? {
        if entry.kind != kind || entry.isMountPoint || !devices.contains(entry.device) { return .changed }
        return nil
    }

    /// Protected reasons that make a whole folder untrashable when a folder inside it has them.
    /// `.insidePackage` and `.notWritable` are absent: the package or folder goes along as a whole.
    static let subtreeBlockingReasons: Set<SafetyReason> = [
        .appleData, .photosLibrary, .runningApp, .runningAppData, .essentialFolder, .systemLocation, .trash,
        .unusualPath,
    ]

    /// Flags that mean a directory's contents were never (fully) seen.
    private static let unverifiedFlags: NodeFlags = [.mountPoint, .unreadable]

    /// Why the folder `id` at `path` may not go because of what it holds, or nil:
    /// `.containsUnverified` when it or a folder below it (not removed) is a mount point, unreadable
    /// or not fully listed; `.protected(reason)` for a folder below it whose fresh verdict is
    /// protected for one of `subtreeBlockingReasons`, or for a running app's bundle at or below it
    /// (compared in NFC, case-insensitively, by component).
    private func subtreeBlocker(_ id: NodeID, path: String) -> TrashSkip? {
        if !tree.flags(id).isDisjoint(with: Self.unverifiedFlags) || unverifiedDirectories.contains(id) {
            return .containsUnverified
        }
        var stack: [NodeID] = []
        tree.forEachChild(of: id) { stack.append($0) }
        while let n = stack.popLast() {
            guard tree.kind(n) == .directory, !tree.flags(n).contains(.removed) else { continue }
            if !tree.flags(n).isDisjoint(with: Self.unverifiedFlags) || unverifiedDirectories.contains(n) {
                return .containsUnverified
            }
            let verdict = SafetyRules.evaluate(facts(n), in: environment)
            if verdict.level == .protected, Self.subtreeBlockingReasons.contains(verdict.reason) {
                return .protected(verdict.reason)
            }
            tree.forEachChild(of: n) { stack.append($0) }
        }
        let base = SafetyPaths.folded(path)
        let below = base + "/"
        for key in environment.running.pathKeys
        where key.utf8.elementsEqual(base.utf8) || key.utf8.starts(with: below.utf8) {
            return .protected(.runningApp)
        }
        return nil
    }

    /// Every folder above `path`, nearest first, ending with `/` (split on `/` bytes, so names
    /// beginning with a combining mark cannot hide a separator).
    static func ancestorPaths(of path: String) -> [String] {
        let bytes = Array(path.utf8)
        var result: [String] = []
        var end = bytes.count
        while let slash = bytes[..<end].lastIndex(of: UInt8(ascii: "/")) {
            result.append(slash == 0 ? "/" : String(decoding: bytes[..<slash], as: UTF8.self))
            if slash == 0 { break }
            end = slash
        }
        return result
    }

    /// A readable, localized message for a failed `stat`.
    private static func message(for error: DirectoryReadError) -> String {
        let code: Int32
        switch error {
        case .permissionDenied: code = EACCES
        case .notFound: code = ENOENT
        case .nameTooLong: code = ENAMETOOLONG
        case .notADirectory: code = ENOTDIR
        case .other(let c): code = c
        }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }
}
