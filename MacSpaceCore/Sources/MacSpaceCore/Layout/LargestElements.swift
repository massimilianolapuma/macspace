/// Picks the elements a chart exposes to VoiceOver: both charts are drawn in a `Canvas`, so
/// only the largest few get an accessibility child, to keep the list usable.
public enum LargestElements {
    /// How many segments or tiles a chart exposes.
    public static let accessibilityLimit = 50

    /// The `limit` largest of `items`, biggest first. Equal sizes keep their input order, so the
    /// result is the same on every call.
    public static func of<T>(_ items: [T], limit: Int = accessibilityLimit, size: (T) -> UInt64) -> [T] {
        guard limit > 0 else { return [] }
        let ranked = items.enumerated().sorted { a, b in
            let (sa, sb) = (size(a.element), size(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }
        return ranked.prefix(limit).map(\.element)
    }
}
