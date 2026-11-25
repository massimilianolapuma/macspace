import Foundation

/// A `~/Library` folder whose children are matched to their owning app. Raw values are the folder names.
public enum LibraryLocation: String, CaseIterable, Sendable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case preferences = "Preferences"
    case savedState = "Saved Application State"
    case httpStorages = "HTTPStorages"
    case webKit = "WebKit"
    case logs = "Logs"
    case launchAgents = "LaunchAgents"

    /// The file-name suffix this location appends to an identifier, if any.
    fileprivate var suffix: String? {
        switch self {
        case .preferences, .launchAgents: ".plist"
        case .savedState: ".savedState"
        case .httpStorages: ".binarycookies"
        default: nil
        }
    }
}

/// Who a `~/Library` entry belongs to.
public enum Ownership: Sendable, Hashable {
    case apple
    case installed(AppRecord)
    /// Looks like a reverse-DNS identifier but matches no installed or running app: a potential leftover.
    case unmatchedIdentifier(String)
    /// A plain name that matches no app; never treated as a leftover.
    case unknownName
}

/// Decides whether a name inside a `~/Library` location belongs to Apple, an installed (or running)
/// app, or nobody. Doubtful cases resolve to `.installed` or `.unknownName`, never to a leftover.
public enum OwnerMatcher {
    private static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "me", "co", "de", "uk", "fr", "it", "jp", "cn", "ru", "us",
        "ch", "nl", "se",
    ]

    /// Classifies `name` (a child of `location`); `running` holds the bundle IDs of running apps.
    public static func ownership(
        of name: String, in location: LibraryLocation, apps: AppsIndex, running: Set<String>
    ) -> Ownership {
        let parsed = parse(name, in: location)
        if isApple(parsed.text) { return .apple }
        guard isIdentifierLike(parsed.text) else {
            return apps.app(named: parsed.text).map(Ownership.installed) ?? .unknownName
        }
        if let app = apps.app(forIdentifier: parsed.text) { return .installed(app) }
        if !running.isEmpty {
            // Reuse AppsIndex's prefix rule over the running IDs.
            let runningIndex = AppsIndex(records: running.map {
                AppRecord(bundleID: $0, name: parsed.text, teamID: nil, path: "")
            })
            if let app = runningIndex.app(forIdentifier: parsed.text) { return .installed(app) }
        }
        if location == .groupContainers, let team = parsed.team, apps.hasTeam(team) {
            // AppsIndex answers team membership only, so report a placeholder record carrying the team.
            return .installed(AppRecord(bundleID: "", name: parsed.text, teamID: team, path: ""))
        }
        return .unmatchedIdentifier(parsed.text)
    }

    /// The identifier `name` stands for in `location` (suffix, `group.` and team prefix removed),
    /// or nil when it is not identifier-like.
    public static func identifier(from name: String, in location: LibraryLocation) -> String? {
        let text = parse(name, in: location).text
        return isIdentifierLike(text) ? text : nil
    }

    // MARK: - Parsing

    private static func parse(_ name: String, in location: LibraryLocation) -> (text: String, team: String?) {
        var text = name
        if let suffix = location.suffix, text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        guard location == .groupContainers else { return (text, nil) }
        let lowered = text.lowercased()
        for prefix in ["group.", "systemgroup."] where lowered.hasPrefix(prefix) && text.count > prefix.count {
            return (String(text.dropFirst(prefix.count)), nil)
        }
        let chars = Array(text.utf8)
        if chars.count > 11, chars[10] == 0x2E,
           chars[..<10].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) {
            return (String(decoding: chars[11...], as: UTF8.self), String(decoding: chars[..<10], as: UTF8.self))
        }
        return (text, nil)
    }

    private static func isApple(_ text: String) -> Bool {
        text.lowercased().hasPrefix("com.apple.")
    }

    /// No spaces, at least 2 labels of `[A-Za-z0-9_-]+`, and either 3+ labels or a common TLD first.
    private static func isIdentifierLike(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.utf8.allSatisfy({
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                    || $0 == 0x5F || $0 == 0x2D
            }) else { return false }
        }
        return labels.count >= 3 || commonTLDs.contains(labels[0].lowercased())
    }
}
