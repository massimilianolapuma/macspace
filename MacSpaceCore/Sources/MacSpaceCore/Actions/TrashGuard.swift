/// The last, independent check before anything is moved to the Trash. It shares no code with
/// `SafetyRules` (only the `SafetyTables.essentialPaths` list), so a bug in one does not disable
/// the other. Comparisons are in NFC and case-insensitive, which only ever refuses more.
public enum TrashGuard {
    /// Why `path` must never be moved to the Trash, or nil if this guard has no objection.
    /// Refuses: a path that is not absolute or has an empty, `.` or `..` component (a trailing
    /// slash included); `/`; fewer than 2 components; `home` itself or any folder above it; the
    /// essential folders; a direct child of `/Volumes` (a mounted volume), of `/Users` (a home
    /// folder or Shared), of `~/Library/Mobile Documents` or of `~/Library/CloudStorage` (a cloud
    /// drive root); a path holding U+FFFD (a name decoded from invalid UTF-8). Also refuses
    /// everything when `home` itself is not a plain absolute path.
    public static func refusal(path: String, home: String) -> String? {
        guard let parts = components(path) else { return "not a plain absolute path" }
        // U+FFFD stands in for bytes that were not valid UTF-8 when the name was read: the path may
        // then name another item, or none.
        if path.unicodeScalars.contains("\u{FFFD}") { return "a name that could not be read exactly" }
        if parts.isEmpty { return "the root folder" }
        if parts.count < 2 { return "a top-level folder" }
        var homePath = home
        while homePath.utf8.count > 1, homePath.hasSuffix("/") { homePath.removeLast() }
        guard let homeParts = components(homePath) else { return "home folder unknown" }

        let keyParts = parts.map(key)
        let homeKeyParts = homeParts.map(key)
        if keyParts.count <= homeKeyParts.count, Array(homeKeyParts.prefix(keyParts.count)) == keyParts {
            return "the home folder or a folder above it"
        }
        let joined = "/" + keyParts.joined(separator: "/")
        let essential = Set(SafetyTables.essentialPaths(home: homePath).map { key(Substring($0)) })
        if essential.contains(joined) { return "an essential folder" }
        let parentKey = Array(keyParts.dropLast())
        if parentKey == ["volumes"] { return "a mounted volume" }
        if parentKey == ["users"] { return "a home folder" }
        let cloudRoots = [homeKeyParts + ["library", "mobile documents"], homeKeyParts + ["library", "cloudstorage"]]
        if cloudRoots.contains(parentKey) { return "a cloud drive root" }
        return nil
    }

    /// The components of an absolute path (`[]` for `/`), or nil when it is not absolute or has an
    /// empty, `.` or `..` component.
    private static func components(_ path: String) -> [Substring]? {
        guard path.hasPrefix("/") else { return nil }
        if path == "/" { return [] }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts
    }

    /// Comparison form of a name or path: NFC, lowercased.
    private static func key(_ s: Substring) -> String {
        String(s).precomposedStringWithCanonicalMapping.lowercased()
    }
}
