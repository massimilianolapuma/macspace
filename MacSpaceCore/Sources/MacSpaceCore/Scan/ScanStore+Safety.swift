import Foundation

/// Safety verdicts for the store's nodes (`SafetyRules` fed with facts from the tree).
extension ScanStore {
    /// Replaces the environment verdicts are judged against (apps index ready, apps launched or
    /// quit) and forgets every cached verdict.
    public func setEnvironment(_ env: SafetyEnvironment) {
        environment = env
        verdictCache.removeAll()
    }

    /// Forgets every cached verdict; call it when a scan ends. The tree's own changes (`insert`,
    /// `markUnreadable`) already do this; what else moves (write access, the clock) does not.
    public func invalidateVerdicts() {
        verdictCache.removeAll()
    }

    /// Drops cached verdicts after a change to the tree; free while none is cached (scan hot path).
    func dropVerdicts() {
        if !verdictCache.isEmpty { verdictCache.removeAll() }
    }

    /// `id`'s verdict under the current environment, computed once and cached; nil for an ID that is
    /// not in this tree.
    public func verdict(_ id: NodeID) -> SafetyVerdict? { contains(id) ? judged(id) : nil }

    /// `verdict` for an ID known to be in the tree.
    func judged(_ id: NodeID) -> SafetyVerdict {
        if let cached = verdictCache[id] { return cached }
        let verdict = SafetyRules.evaluate(facts(id), in: environment)
        verdictEvaluations += 1
        verdictCache[id] = verdict
        return verdict
    }

    /// The node at `path` (exact name bytes), or nil if the scan has not reached it or it is outside the root.
    public func node(atPath path: String) -> NodeID? { tree.node(atPath: path) }

    /// `row` with its node's safety level.
    func stamped(_ row: NodeRow) -> NodeRow {
        var row = row
        row.safety = judged(row.id).level
        return row
    }

    /// What the rules need to know about `id`, from the tree.
    func facts(_ id: NodeID) -> NodeFacts {
        let path = tree.path(of: id)
        return NodeFacts(path: path, name: tree.name(id), kind: tree.kind(id), flags: tree.flags(id),
                         size: tree.size(id), lastUsed: tree.lastUsed(id),
                         anchorLastUsed: anchorLastUsed(of: id, path: path),
                         category: tree.dominantCategory(id), isScanRoot: id == FileTree.root)
    }

    /// The last use of the `L/<location>/<name>` folder `id` is at or below, found with the same
    /// (case-insensitive) path match the rules use, so the two always agree on the anchor. It is
    /// `id`'s own last use when there is no such folder, and 0 (unknown, judged recent) when that
    /// folder lies above the scan root, since its other contents were not scanned.
    func anchorLastUsed(of id: NodeID, path: String) -> UInt32 {
        let key = SafetyPaths.key(path)
        for entry in environment.paths.locations {
            guard let name = SafetyPaths.component(below: entry.path, path: path, key: key) else { continue }
            let anchorEnd = entry.path.utf8.count + 1 + name.utf8.count
            let levels = path.utf8.dropFirst(anchorEnd).count { $0 == UInt8(ascii: "/") }
            var anchor = id
            for _ in 0..<levels {
                guard let parent = tree.parent(anchor) else { return 0 }
                anchor = parent
            }
            return tree.lastUsed(anchor)
        }
        return tree.lastUsed(id)
    }

    /// `path` with runs of `/` collapsed and trailing slashes removed (`/` stays `/`).
    static func canonicalRoot(_ path: String) -> String {
        var bytes: [UInt8] = []
        for byte in path.utf8 where !(byte == UInt8(ascii: "/") && bytes.last == UInt8(ascii: "/")) {
            bytes.append(byte)
        }
        while bytes.count > 1, bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
