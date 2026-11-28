import Foundation
@testable import MacSpaceCore

/// What a node shows, without its ID: equal trees built in another order compare equal.
struct ShownFacts: Equatable, CustomStringConvertible {
    var size: UInt64
    var kind: NodeKind
    var flags: NodeFlags
    var category: FileCategory
    var lastUsed: UInt32
    var ageBucket: AgeBucket

    var description: String { "\(kind) \(size)B flags:\(flags.rawValue) \(category) last:\(lastUsed) \(ageBucket)" }
}

extension ScanStore {
    /// Every node still in the tree, by path.
    func factsByPath() -> [String: ShownFacts] {
        var facts: [String: ShownFacts] = [:]
        for raw in 0..<tree.count {
            let id = NodeID(raw)
            let row = tree.row(id)
            guard !row.flags.contains(.removed) else { continue }
            facts[tree.path(of: id)] = ShownFacts(size: row.size, kind: row.kind, flags: row.flags, category: row.category,
                                                 lastUsed: row.lastUsed, ageBucket: row.ageBucket)
        }
        return facts
    }

    /// The paths of the directories whose contents are not fully known.
    func unverifiedPaths() -> Set<String> { Set(unverifiedDirectories.map { tree.path(of: $0) }) }

    /// Each multiply-linked file's links, by path, with the one carrying its bytes first.
    func hardLinkPaths() -> Set<[String]> {
        Set(hardLinks.values.map { ids in
            let counted = ids.filter { countedLink[$0] != nil }
            return (counted + ids.filter { countedLink[$0] == nil }).map { tree.path(of: $0) }
        })
    }

    func totals(at path: String) -> (categories: [FileCategory: UInt64], ages: [AgeBucket: UInt64])? {
        guard let id = tree.node(atPath: path) else { return nil }
        return (tree.categoryTotals(id), tree.ageTotals(id))
    }
}
