/// The groups of ready-made findings the store offers for the Trash.
public enum SuggestionKind: Sendable, CaseIterable {
    /// Data left behind by apps that are no longer installed.
    case leftovers
    /// Caches that are rebuilt on demand.
    case caches
    /// Disk images and packages used to install apps.
    case installers
}

/// One suggested file or folder.
public struct SuggestionItem: Sendable, Hashable, Identifiable {
    public let id: NodeID
    public let name: String
    public let path: String
    public let size: UInt64
    public let verdict: SafetyVerdict
    /// Only `.safe` items start selected.
    public let preselected: Bool

    public init(id: NodeID, name: String, path: String, size: UInt64, verdict: SafetyVerdict) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.verdict = verdict
        preselected = verdict.level == .safe
    }
}

/// A non-empty group of suggested items, largest first.
public struct Suggestion: Sendable, Identifiable {
    public let kind: SuggestionKind
    public let items: [SuggestionItem]
    /// Sum of the items' sizes.
    public let total: UInt64
    public var id: SuggestionKind { kind }
}

extension Suggestion {
    /// Sorts `items` (size descending, then name, then path) and sums them.
    init(kind: SuggestionKind, items unsorted: [SuggestionItem]) {
        self.kind = kind
        items = unsorted.sorted {
            if $0.size != $1.size { return $0.size > $1.size }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.path < $1.path
        }
        total = unsorted.reduce(0) { $0 + $1.size }
    }
}
