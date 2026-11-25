import Darwin
import Foundation

/// How safe it is to move an item to the Trash.
public enum SafetyLevel: UInt8, Sendable, CaseIterable {
    case safe, caution, normal, protected

    /// Everything except `.protected` may be moved to the Trash (after the user confirms).
    public var isTrashable: Bool { self != .protected }
}

/// Why an item got its `SafetyLevel`; one case per row of the rule table in `SafetyRules`.
public enum SafetyReason: Sendable, Hashable, CaseIterable {
    case unusualPath
    case scanRoot, essentialFolder, insidePackage, systemLocation, trash, appleData, photosLibrary, runningApp
    case notWritable, cloudOnly, cloudSynced, developerCache, analysisPending
    case appleCache, cacheOfRunningApp, cacheOfApp, leftover
    case runningAppData, appData, leftoverLaunchAgent, recentLeftover, vendorLeftover
    case installer, notUsedForLong, ordinary
}

/// The outcome of `SafetyRules.evaluate`.
public struct SafetyVerdict: Sendable, Hashable {
    public let level: SafetyLevel
    public let reason: SafetyReason
    /// App name, cloud provider or developer-cache name, when the reason has one and it is known.
    public let owner: String?

    public init(level: SafetyLevel, reason: SafetyReason, owner: String? = nil) {
        self.level = level
        self.reason = reason
        self.owner = owner
    }
}

/// What the rules know about one file or folder.
public struct NodeFacts: Sendable {
    /// Absolute path.
    public let path: String
    /// Last path component.
    public let name: String
    public let kind: NodeKind
    public let flags: NodeFlags
    public let size: UInt64
    /// Seconds since 1970 (0 = unknown); for a directory, the latest over its contents.
    public let lastUsed: UInt32
    /// Last use of the `~/Library/<location>/<name>` folder the node is at or below (its own
    /// `lastUsed` for that folder itself, and when the node is not in such a folder).
    public let anchorLastUsed: UInt32
    public let category: FileCategory
    public let isScanRoot: Bool

    /// `anchorLastUsed` defaults to `lastUsed`.
    public init(path: String, name: String, kind: NodeKind, flags: NodeFlags, size: UInt64, lastUsed: UInt32,
                anchorLastUsed: UInt32? = nil, category: FileCategory, isScanRoot: Bool) {
        self.path = path
        self.name = name
        self.kind = kind
        self.flags = flags
        self.size = size
        self.lastUsed = lastUsed
        self.anchorLastUsed = anchorLastUsed ?? lastUsed
        self.category = category
        self.isScanRoot = isScanRoot
    }
}

/// Everything outside the node the rules depend on. Immutable: build a new one when apps launch or quit.
public struct SafetyEnvironment: Sendable {
    public let home: String
    /// `nil` while the apps index is still being built: `~/Library` items then stay `.analysisPending`.
    public let apps: AppsIndex?
    public let runningBundleIDs: Set<String>
    /// Bundle paths of running apps.
    public let runningAppPaths: Set<String>
    /// Seconds since 1970.
    public let now: UInt32
    /// Whether the current user may modify the given directory (add or remove entries).
    public let isWritable: @Sendable (String) -> Bool

    /// Lowercased path tables derived from `home`.
    let paths: SafetyPaths
    /// `runningBundleIDs` and `runningAppPaths` as lookup tables, built once here (not per node).
    let running: RunningApps

    public init(home: String, apps: AppsIndex?, runningBundleIDs: Set<String>, runningAppPaths: Set<String>,
                now: UInt32, isWritable: @escaping @Sendable (String) -> Bool) {
        self.home = home
        self.apps = apps
        self.runningBundleIDs = runningBundleIDs
        self.runningAppPaths = runningAppPaths
        self.now = now
        self.isWritable = isWritable
        paths = SafetyPaths(home: home)
        running = RunningApps(bundleIDs: runningBundleIDs, paths: runningAppPaths)
    }

    /// The live environment: the current time and `access(dir, W_OK)` for write checks.
    public static func system(home: String, apps: AppsIndex?, runningBundleIDs: Set<String> = [],
                              runningAppPaths: Set<String> = []) -> SafetyEnvironment {
        let seconds = Date().timeIntervalSince1970
        let now = seconds <= 0 ? 0 : seconds >= Double(UInt32.max) ? UInt32.max : UInt32(seconds)
        return SafetyEnvironment(home: home, apps: apps, runningBundleIDs: runningBundleIDs,
                                 runningAppPaths: runningAppPaths, now: now,
                                 isWritable: { access($0, W_OK) == 0 })
    }
}

/// The running apps as the rules look them up: built once per `SafetyEnvironment`, so judging a
/// node costs a few dictionary lookups whatever the number of running apps.
struct RunningApps: Sendable {
    /// ASCII-lowercased running bundle ID -> the lowest (sorted) original ID with that key.
    private let byID: [String: String]
    /// Every proper dot-prefix of a running ID that keeps at least 2 labels -> the lowest ID having it.
    private let byPrefix: [String: String]
    /// Running bundle paths, normalized, in `SafetyPaths.folded` form.
    let pathKeys: Set<String>

    init(bundleIDs: Set<String>, paths: Set<String>) {
        var byID: [String: String] = [:]
        var byPrefix: [String: String] = [:]
        for id in bundleIDs.sorted() {
            let key = SafetyPaths.key(id)
            guard !key.isEmpty else { continue }
            if byID[key] == nil { byID[key] = id }
            for prefix in AppsIndex.dotPrefixes(of: key) where byPrefix[prefix] == nil { byPrefix[prefix] = id }
        }
        self.byID = byID
        self.byPrefix = byPrefix
        pathKeys = Set(paths.map { SafetyPaths.folded(SafetyTables.normalized($0)) })
    }

    /// The lowest running ID related to `identifier` by the `AppsIndex` prefix rule: equal, or one a
    /// dot-prefix of the other while they share at least 2 labels. Nil when none is.
    func id(relatedTo identifier: String) -> String? {
        let key = SafetyPaths.key(identifier)
        guard !key.isEmpty else { return nil }
        var best = byID[key]
        func consider(_ candidate: String?) {
            if let candidate, best.map({ candidate < $0 }) ?? true { best = candidate }
        }
        // A running ID that is a dot-prefix of the identifier.
        for prefix in AppsIndex.dotPrefixes(of: key) { consider(byID[prefix]) }
        // The identifier is a dot-prefix of a longer running ID.
        if key.contains(".") { consider(byPrefix[key]) }
        return best
    }

    /// Whether the bundle at `path` is a running app's (compared as `SafetyPaths.folded`). `key`, when
    /// given, is `SafetyPaths.key` of the normalized `path` (reused when the path is ASCII).
    func isRunning(path: String, key: String? = nil) -> Bool {
        guard !pathKeys.isEmpty else { return false }
        let clean = SafetyTables.normalized(path)
        if let key, clean.utf8.allSatisfy({ $0 < 0x80 }) { return pathKeys.contains(key) }
        return pathKeys.contains(SafetyPaths.folded(clean))
    }

    /// Whether `record` is a running app: its bundle ID is related to a running ID, or its bundle is
    /// a running app's.
    func isRunning(_ record: AppRecord) -> Bool {
        id(relatedTo: record.bundleID) != nil || (!record.path.isEmpty && isRunning(path: record.path))
    }
}
