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
    /// one that fails:
    /// 0. `openFiles()` (called exactly once, before the loop) is incomplete: every item is
    ///    skipped as `.cannotCheckOpenFiles` and nothing moves;
    /// 1. removed already → `.missing`;
    /// 2. `TrashGuard` refuses it → `.refused`;
    /// 3. a fresh `SafetyRules` verdict (not the cache) is protected → `.protected(reason)`;
    /// 4. on disk it is gone → `.missing`, cannot be examined → `.failed`, or is another kind of
    ///    object than scanned, or a folder above it (up to the scan root) is no longer a folder → `.changed`;
    /// 5. a folder above it, up to `/`, is a package per `packages` → `.insidePackage`;
    /// 6. it or a file inside it is open → `.openNow`;
    /// 7. a folder holding something the rules protect as a whole (Apple data, a Photos library, a
    ///    running app or its data, an essential, system or Trash folder, an unusual path), or a
    ///    running app's bundle → `.protected(reason)`;
    /// 8. `moveToTrash` throws → `.failed(error.localizedDescription)`.
    /// Verdicts are dropped afterwards, since sizes and contents moved.
    public func trash(_ ids: Set<NodeID>, actions: any DiskActions, packages: any PackageProbe,
                      openFiles: @Sendable () -> OpenFileSet) -> TrashOutcome {
        defer { verdictCache.removeAll() }
        let items = topMost(ids, keepingRemoved: true)
        let open = openFiles()
        var outcome = TrashOutcome()
        guard open.isComplete else {
            outcome.skipped = items.map {
                TrashOutcome.Skipped(node: $0, name: tree.name($0), reason: .cannotCheckOpenFiles)
            }
            return outcome
        }
        for id in items {
            let name = tree.name(id)
            if let reason = trashBlocker(id, open: open, packages: packages) {
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

    /// Checks 1–7 of `trash` for one item: the first failing one, or nil when it may move.
    private func trashBlocker(_ id: NodeID, open: OpenFileSet, packages: any PackageProbe) -> TrashSkip? {
        // 1. Already moved (it or a folder above it).
        if tree.flags(id).contains(.removed) { return .missing }
        let path = tree.path(of: id)
        // 2. The independent guard.
        if TrashGuard.refusal(path: path, home: environment.home) != nil { return .refused }
        // 3. Fresh verdict, bypassing the cache.
        let verdict = SafetyRules.evaluate(facts(id), in: environment)
        if verdict.level == .protected { return .protected(verdict.reason) }
        // 4. Still the same kind of object, reached through the same folders.
        let kind = tree.kind(id)
        do {
            let entry = try DirectoryReader.stat(path: path)
            if entry.kind != kind { return .changed }
        } catch .notFound {
            return .missing
        } catch {
            return .failed(Self.message(for: error))
        }
        var ancestor = tree.parent(id)
        while let a = ancestor {
            guard (try? DirectoryReader.stat(path: tree.path(of: a)))?.kind == .directory else { return .changed }
            ancestor = tree.parent(a)
        }
        // 5. Inside a package LaunchServices knows of (registered types too).
        if Self.ancestorPaths(of: path).contains(where: packages.isPackage) { return .insidePackage }
        // 6. Open right now.
        if kind == .directory {
            if open.isOpen(path) || open.hasOpen(under: path) { return .openNow }
        } else if open.isOpen(path) {
            return .openNow
        }
        // 7. Something inside it that must never go.
        if kind == .directory, let reason = protectedContent(below: id, path: path) { return .protected(reason) }
        return nil
    }

    /// Protected reasons that make a whole folder untrashable when a folder inside it has them.
    /// `.insidePackage` and `.notWritable` are absent: the package or folder goes along as a whole.
    static let subtreeBlockingReasons: Set<SafetyReason> = [
        .appleData, .photosLibrary, .runningApp, .runningAppData, .essentialFolder, .systemLocation, .trash,
        .unusualPath,
    ]

    /// Why the folder `id` at `path` holds something that must never go, or nil: a folder below it
    /// (not removed) whose fresh verdict is protected for one of `subtreeBlockingReasons`, or a
    /// running app's bundle at or below it (compared in NFC, case-insensitively, by component).
    private func protectedContent(below id: NodeID, path: String) -> SafetyReason? {
        var stack: [NodeID] = []
        tree.forEachChild(of: id) { stack.append($0) }
        while let n = stack.popLast() {
            guard tree.kind(n) == .directory, !tree.flags(n).contains(.removed) else { continue }
            let verdict = SafetyRules.evaluate(facts(n), in: environment)
            if verdict.level == .protected, Self.subtreeBlockingReasons.contains(verdict.reason) {
                return verdict.reason
            }
            tree.forEachChild(of: n) { stack.append($0) }
        }
        let base = Self.pathKey(path)
        let below = base + "/"
        for running in environment.runningAppPaths {
            let key = Self.pathKey(SafetyTables.normalized(running))
            if key.utf8.elementsEqual(base.utf8) || key.utf8.starts(with: below.utf8) { return .runningApp }
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

    /// Comparison form of a path: NFC, lowercased.
    private static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// A readable message for a failed `stat`.
    private static func message(for error: DirectoryReadError) -> String {
        let code: Int32
        switch error {
        case .permissionDenied: code = EACCES
        case .notFound: code = ENOENT
        case .nameTooLong: code = ENAMETOOLONG
        case .notADirectory: code = ENOTDIR
        case .other(let c): code = c
        }
        return String(cString: strerror(code))
    }
}
