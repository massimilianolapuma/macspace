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
    /// An empty `name` on the record means a running app whose name is unknown (only `bundleID` is set).
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
        ownership(of: name, in: location, apps: apps, running: RunningApps(bundleIDs: running, paths: []))
    }

    /// `ownership` against running apps already indexed (`SafetyEnvironment.running`, built once).
    static func ownership(
        of name: String, in location: LibraryLocation, apps: AppsIndex, running: RunningApps
    ) -> Ownership {
        let parsed = parse(name, in: location)
        if isApple(parsed.text) || parsed.team?.lowercased() == SafetyTables.appleTeamID.lowercased() {
            return .apple
        }
        // A team-prefixed Group Container is shared by the apps of that team: while any of them runs,
        // it is that app's data, whatever the rest of the name says.
        let team = location == .groupContainers ? parsed.team.map { apps.apps(forTeam: $0) } ?? [] : []
        if let app = team.first(where: running.isRunning) { return .installed(app) }
        let core = withoutFileExtension(parsed.text)
        guard isIdentifierLike(core) else {
            return apps.app(named: parsed.text).map(Ownership.installed)
                ?? apps.app(named: core).map(Ownership.installed)
                ?? team.first.map(Ownership.installed) ?? .unknownName
        }
        if let app = apps.app(forIdentifier: core) { return .installed(app) }
        // Running apps may live outside every scanned root: the lowest related running ID.
        if let id = running.id(relatedTo: core) {
            return .installed(AppRecord(bundleID: id, name: "", teamID: nil, path: ""))
        }
        if let app = team.first { return .installed(app) }
        return .unmatchedIdentifier(core)
    }

    /// The identifier `name` stands for in `location` (suffix, `group.`, team prefix and a trailing
    /// file extension removed), or nil when it is not identifier-like.
    public static func identifier(from name: String, in location: LibraryLocation) -> String? {
        let core = withoutFileExtension(parse(name, in: location).text)
        return isIdentifierLike(core) ? core : nil
    }

    // MARK: - Parsing

    private static func parse(_ name: String, in location: LibraryLocation) -> (text: String, team: String?) {
        var text = name
        if let suffix = location.suffix, hasSuffix(text, suffix) { text.removeLast(suffix.utf16.count) }
        guard location == .groupContainers else { return (text, nil) }
        for prefix in ["group.", "systemgroup."] where hasPrefix(text, prefix) && text.utf16.count > prefix.utf16.count {
            return (String(text.dropFirst(prefix.count)), nil)
        }
        let chars = Array(text.utf8)
        if chars.count > 11, chars[10] == 0x2E,
           chars[..<10].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) {
            return (String(decoding: chars[11...], as: UTF8.self), String(decoding: chars[..<10], as: UTF8.self))
        }
        return (text, nil)
    }

    private static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
    }

    private static func hasSuffix(_ text: String, _ suffix: String) -> Bool {
        text.range(of: suffix, options: [.anchored, .backwards, .caseInsensitive]) != nil
    }

    /// Apple's: `com.apple` as the first labels or right after any `.`, or a listed Apple prefix.
    private static func isApple(_ text: String) -> Bool {
        let labels = text.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        for index in labels.indices.dropLast() where labels[index] == "com" && labels[index + 1] == "apple" {
            return true
        }
        return SafetyTables.appleIdentifierPrefixes.contains { hasPrefix(text, $0) }
    }

    /// Drops one trailing label that is a file extension (`com.foo.app.log` -> `com.foo.app`).
    private static func withoutFileExtension(_ text: String) -> String {
        guard let dot = text.lastIndex(of: "."), dot != text.startIndex else { return text }
        let last = text[text.index(after: dot)...].lowercased()
        return SafetyTables.fileExtensionLabels.contains(last) ? String(text[..<dot]) : text
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
