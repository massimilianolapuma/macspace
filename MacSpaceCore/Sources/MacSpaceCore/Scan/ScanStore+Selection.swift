/// What the user selected for the Trash, as the store sees it.
public struct SelectionSummary: Sendable, Equatable {
    /// The items that stay selected: top-most, never the root or protected; size descending, then id.
    public let ids: [NodeID]
    /// Sum of their sizes: each byte once, since none is inside another.
    public let total: UInt64
}

/// Selection rules (spec §5.6) and the folders the app navigates to for a group of items.
extension ScanStore {
    /// `ids` reduced to what may stay selected: first every item whose verdict is protected goes
    /// (and stale IDs), then `topMost` of the rest (no root, nothing removed, nothing inside another
    /// selected folder). Selecting a folder therefore drops what was selected inside it, selecting
    /// something inside a selected folder changes nothing, and a protected folder never hides what
    /// may be selected inside it.
    public func resolveSelection(_ ids: Set<NodeID>) -> SelectionSummary {
        let kept = topMost(ids.filter { contains($0) && judged($0).level != .protected })
        return SelectionSummary(ids: kept, total: kept.reduce(0) { $0 + tree.size($1) })
    }

    /// The deepest folder that holds every item of `ids` strictly inside it (the parent, for a single
    /// item): where they all show at once. IDs that are not in the tree are ignored; nil when no
    /// other ID is left, or the root is among them.
    public func commonFolder(of ids: Set<NodeID>) -> NodeID? {
        var common: [NodeID]?  // root first
        for id in ids where contains(id) {
            guard let parent = tree.parent(id) else { return nil }
            var chain = [parent]
            while let up = tree.parent(chain[chain.count - 1]) { chain.append(up) }
            chain.reverse()
            guard let current = common else {
                common = chain
                continue
            }
            let shared = zip(current, chain).prefix { $0 == $1 }.count
            common = Array(current.prefix(shared))
        }
        return common?.last
    }
}
