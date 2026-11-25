import Foundation

/// Decides how safe it is to move a file or folder to the Trash: one first-match-wins rule table.
///
/// Paths are compared component-wise ("under X" = X itself or below it) and ASCII case-insensitively
/// (macOS volumes are case-insensitive by default, so a differently cased path names the same item).
/// Case folding only ever reduces protection on a case-sensitive volume, where a folder whose name
/// differs only by case from a known root (a cache, a `~/Library` location) is judged like that root.
/// Paths are not resolved: anything not absolute or with an empty, `.` or `..` component is protected,
/// and so is anything below a non-ASCII home folder spelled in another Unicode form than `env.home`.
/// Doubtful cases resolve towards `.protected`, `.caution` or `.normal`, never `.safe`.
public enum SafetyRules {
    /// A file unused this long (and big enough) is suggested for review: 2 years.
    public static let longUnusedSeconds: UInt32 = 730 * 86_400
    /// Smallest file flagged as long unused.
    public static let longUnusedMinSize: UInt64 = 50_000_000
    /// A leftover used more recently than this may belong to an app the index missed: 30 days.
    public static let recentLeftoverSeconds: UInt32 = 30 * 86_400
    /// Smallest item listed in suggestions.
    public static let suggestionMinSize: UInt64 = 1_000_000
    /// Categories of user content that rule 17 may flag as long unused.
    public static let longUnusedCategories: Set<FileCategory> = [.video, .photo, .music, .document, .archive]

    /// The verdict for `f`; the first matching rule wins.
    public static func evaluate(_ f: NodeFacts, in env: SafetyEnvironment) -> SafetyVerdict {
        let t = env.paths
        let path = SafetyTables.normalized(f.path)
        let key = SafetyPaths.key(path)

        // 0. Not a plain absolute path (`//`, `.`, `..`, relative): no rule below can be trusted.
        if isUnusual(path) { return SafetyVerdict(level: .protected, reason: .unusualPath) }
        //    Below a non-ASCII home folder whose name on disk is in another Unicode form (NFC/NFD) or
        //    case than `env.home`: the byte-wise home rules below would all miss, so none is trusted.
        if let folded = t.homeFolded, !SafetyPaths.isUnder(key, t.home), !path.utf8.allSatisfy({ $0 < 0x80 }),
           SafetyPaths.isUnder(SafetyPaths.folded(path), folded) {
            return SafetyVerdict(level: .protected, reason: .unusualPath)
        }
        // 1. The scanned folder itself.
        if f.isScanRoot { return SafetyVerdict(level: .protected, reason: .scanRoot) }
        // 2. Essential folders of the Mac and the user (exact path).
        if t.essential.contains(key) { return SafetyVerdict(level: .protected, reason: .essentialFolder) }
        //    ... and every cloud drive root: a direct child of `L/Mobile Documents` or `L/CloudStorage`.
        let parentKey = parent(of: key)
        if parentKey == t.mobileDocuments || parentKey == t.cloudStorage {
            return SafetyVerdict(level: .protected, reason: .essentialFolder)
        }
        // 3. Anything inside a package: only the package as a whole can move.
        if f.flags.contains(.insidePackage) { return SafetyVerdict(level: .protected, reason: .insidePackage) }
        // 4. macOS-owned trees, except /usr/local.
        if t.system.contains(where: { SafetyPaths.isUnder(key, $0) })
            && !t.systemExceptions.contains(where: { SafetyPaths.isUnder(key, $0) }) {
            return SafetyVerdict(level: .protected, reason: .systemLocation)
        }
        // 5. The user's Trash, or any volume's `.Trashes`.
        if SafetyPaths.isUnder(key, t.homeTrash) || key.split(separator: "/").contains(".trashes") {
            return SafetyVerdict(level: .protected, reason: .trash)
        }
        // 6. Apple data: never-touch folders, Apple containers, `L/com.apple.*` (ruling R44), and
        //    Apple-owned `L/<location>/<name>` (except Caches and Logs, decided by rules 14 and 15).
        //    Needs no apps index.
        let libraryChild = SafetyPaths.component(below: t.library, path: path, key: key).map(SafetyPaths.key)
        let anchor = t.anchor(path: path, key: key)
        let ownership = anchor.map {
            OwnerMatcher.ownership(of: $0.name, in: $0.location, apps: env.apps ?? .empty, running: env.running)
        }
        if t.appleData.contains(where: { SafetyPaths.isUnder(key, $0) }) || isAppleContainer(anchor)
            || libraryChild.map({ child in SafetyTables.appleLibraryChildPrefixes.contains { child.hasPrefix($0) } })
                == true
            || (ownership == .apple && anchor.map { $0.location != .caches && $0.location != .logs } == true) {
            return SafetyVerdict(level: .protected, reason: .appleData)
        }
        // 7. A Photos library.
        if SafetyPaths.key(f.name).hasSuffix(".photoslibrary") {
            return SafetyVerdict(level: .protected, reason: .photosLibrary)
        }
        // 8. A running app's bundle.
        if env.running.isRunning(path: path, key: key) {
            return SafetyVerdict(level: .protected, reason: .runningApp, owner: AppsIndex.baseName(ofPath: path))
        }
        // 9. The user may not remove it from its folder.
        if !env.isWritable(parent(of: path)) { return SafetyVerdict(level: .protected, reason: .notWritable) }
        // 10. Synced by iCloud Drive (its folder, or the Desktop and Documents it syncs) or a File
        //     Provider: deleting it deletes it everywhere, downloaded or not (ruling R42). A cloud-only
        //     item in Desktop or Documents counts as synced even when the sync was not detected.
        if SafetyPaths.isUnder(key, t.mobileDocuments)
            || env.syncedFolderKeys.contains(where: { SafetyPaths.isUnder(key, $0) })
            || (f.flags.contains(.dataless) && t.iCloudSyncableFolders.contains { SafetyPaths.isUnder(key, $0) }) {
            return SafetyVerdict(level: .caution, reason: .cloudSynced, owner: SafetyTables.iCloudDriveName)
        }
        if let folder = SafetyPaths.component(below: t.cloudStorage, path: path, key: key) {
            let provider = folder.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? ""
            return SafetyVerdict(level: .caution, reason: .cloudSynced, owner: provider.isEmpty ? folder : provider)
        }
        // 11. Cloud-only placeholder anywhere else: frees nothing locally.
        if f.flags.contains(.dataless) { return SafetyVerdict(level: .normal, reason: .cloudOnly) }
        // 12. Developer caches that their tools rebuild.
        if let cache = t.developerCaches.first(where: { SafetyPaths.isUnder(key, $0.path) }) {
            return SafetyVerdict(level: .safe, reason: .developerCache, owner: cache.name)
        }
        // 12b. Any other `~/Library` child (and below) outside the known locations: macOS or app
        //      internals no table describes, so only caution (ruling R43). Unsaved versions of
        //      documents get their own caution (ruling R44).
        if let child = libraryChild, !t.libraryKnownChildren.contains(child) {
            if child == t.autosaveFolder { return SafetyVerdict(level: .caution, reason: .autosave) }
            return SafetyVerdict(level: .caution, reason: .libraryInternal)
        }
        if let anchor, let ownership {
            // 13. `L/<location>/<name>` (and below) while the apps index is not ready.
            guard env.apps != nil else { return SafetyVerdict(level: .normal, reason: .analysisPending) }
            if anchor.location == .caches {
                // 14. Caches. An unmatched identifier whose vendor has an installed app is only caution.
                switch ownership {
                case .apple:
                    return SafetyVerdict(level: .caution, reason: .appleCache)
                case .installed(let app) where isRunning(app, in: env):
                    return SafetyVerdict(level: .caution, reason: .cacheOfRunningApp, owner: owner(of: app))
                case .installed(let app):
                    return SafetyVerdict(level: .safe, reason: .cacheOfApp, owner: owner(of: app))
                case .unmatchedIdentifier(let id):
                    if let vendor = vendorApp(of: id, in: env) {
                        return SafetyVerdict(level: .caution, reason: .vendorLeftover, owner: owner(of: vendor))
                    }
                    return SafetyVerdict(level: .safe, reason: .leftover)
                case .unknownName:
                    return SafetyVerdict(level: .safe, reason: .cacheOfApp)
                }
            }
            // 15. Other locations.
            switch ownership {
            case .apple:   // only Logs reaches here (rule 6 took the rest)
                return SafetyVerdict(level: .normal, reason: .ordinary)
            case .installed(let app) where isRunning(app, in: env):
                return SafetyVerdict(level: .protected, reason: .runningAppData, owner: owner(of: app))
            case .installed(let app):
                return SafetyVerdict(level: .caution, reason: .appData, owner: owner(of: app))
            case .unmatchedIdentifier(let id):
                if anchor.location == .launchAgents {
                    return SafetyVerdict(level: .caution, reason: .leftoverLaunchAgent)
                }
                // Same vendor as an installed app (ruling R36): maybe the app's old or sibling ID.
                if let vendor = vendorApp(of: id, in: env) {
                    return SafetyVerdict(level: .caution, reason: .vendorLeftover, owner: owner(of: vendor))
                }
                // Unknown last use (0) is not evidence of age: treated as recent.
                if f.anchorLastUsed == 0 || age(f.anchorLastUsed, now: env.now) < recentLeftoverSeconds {
                    return SafetyVerdict(level: .caution, reason: .recentLeftover)
                }
                return SafetyVerdict(level: .safe, reason: .leftover)
            case .unknownName:
                return SafetyVerdict(level: .normal, reason: .ordinary)
            }
        }
        // 16. An installer file: safe in Downloads or when its app is installed; elsewhere it may be a
        //     disk image the user made (an encrypted vault), so only caution.
        if f.kind == .file, CategoryClassifier.isInstallerName(f.name) {
            let app = InstallerMatcher.app(forInstaller: f.name, apps: env.apps ?? .empty)
            let level: SafetyLevel = app != nil || SafetyPaths.isUnder(key, t.downloads) ? .safe : .caution
            return SafetyVerdict(level: level, reason: .installer, owner: app.flatMap(owner(of:)))
        }
        // 17. Big user content in the home folder (outside ~/Library) unused for long.
        if f.kind == .file, SafetyPaths.isUnder(key, t.home), !SafetyPaths.isUnder(key, t.library),
           longUnusedCategories.contains(f.category), f.size >= longUnusedMinSize, f.lastUsed > 0,
           age(f.lastUsed, now: env.now) >= longUnusedSeconds {
            return SafetyVerdict(level: .caution, reason: .notUsedForLong)
        }
        // 18. Everything else.
        return SafetyVerdict(level: .normal, reason: .ordinary)
    }

    // MARK: - Helpers

    /// Not absolute, or holding an empty, `.` or `..` component (`path` has no trailing slash; `/` is fine).
    static func isUnusual(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return true }
        guard path != "/" else { return false }
        return path.utf8.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0.elementsEqual(".".utf8) || $0.elementsEqual("..".utf8) }
    }

    /// `L/Containers/com.apple.*`, `L/Group Containers/group.com.apple.*` or `L/Group Containers/*.com.apple.*`.
    private static func isAppleContainer(_ anchor: SafetyPaths.Anchor?) -> Bool {
        guard let anchor else { return false }
        let name = SafetyPaths.key(anchor.name)
        switch anchor.location {
        case .containers:
            return SafetyTables.appleContainerPrefixes.contains { name.hasPrefix($0) }
        case .groupContainers:
            return SafetyTables.appleGroupContainerPrefixes.contains { name.hasPrefix($0) }
                || SafetyTables.appleGroupContainerInfixes.contains { name.contains($0) }
        default:
            return false
        }
    }

    /// Running when the record came from a running-only match (empty name, ruling R9), its bundle ID is
    /// related to a running ID by the `AppsIndex` prefix rule, or its bundle is a running app's.
    private static func isRunning(_ app: AppRecord, in env: SafetyEnvironment) -> Bool {
        app.name.isEmpty || env.running.isRunning(app)
    }

    /// An installed app from the same vendor (first two labels) as the unmatched identifier `id`.
    private static func vendorApp(of id: String, in env: SafetyEnvironment) -> AppRecord? {
        env.apps?.app(forVendorOf: id)
    }

    /// The app's name, or nil when unknown (a running-only match).
    private static func owner(of app: AppRecord) -> String? {
        app.name.isEmpty ? nil : app.name
    }

    /// Seconds from `time` to `now`; 0 for a time in the future.
    private static func age(_ time: UInt32, now: UInt32) -> UInt32 {
        time >= now ? 0 : now - time
    }

    /// `path` without its last component; `/` for a top-level item, `""` for a path with no `/`.
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}

/// Lowercased path tables for one home folder, built once per `SafetyEnvironment`.
struct SafetyPaths: Sendable {
    /// A node at or below `L/<location>/<name>`.
    struct Anchor {
        let location: LibraryLocation
        /// The original-case name of the location's child.
        let name: String
    }

    let home: String
    /// `home` in NFC and Unicode lowercase when it has non-ASCII bytes (rule 0), else nil.
    let homeFolded: String?
    let library: String
    let essential: Set<String>
    let system: [String]
    let systemExceptions: [String]
    let homeTrash: String
    let downloads: String
    let appleData: [String]
    let mobileDocuments: String
    let cloudStorage: String
    let developerCaches: [(name: String, path: String)]
    let locations: [(location: LibraryLocation, path: String)]
    /// Lowercased names of the `~/Library` children rule 12b leaves alone.
    let libraryKnownChildren: Set<String>
    /// Lowercased name of the `~/Library` child holding unsaved document versions (rule 12b).
    let autosaveFolder: String
    /// The home folders iCloud Drive can sync (`SafetyTables.iCloudSyncableHomeFolders`), as keys.
    let iCloudSyncableFolders: [String]

    init(home rawHome: String) {
        let h = SafetyTables.normalized(rawHome)
        let lib = h + "/Library"
        home = Self.key(h)
        homeFolded = h.utf8.allSatisfy { $0 < 0x80 } ? nil : Self.folded(h)
        library = Self.key(lib)
        essential = Set(SafetyTables.essentialPaths(home: h).map(Self.key))
        system = SafetyTables.systemPrefixes.map(Self.key)
        systemExceptions = SafetyTables.systemExceptions.map(Self.key)
        homeTrash = Self.key(h + "/.Trash")
        downloads = Self.key(h + "/Downloads")
        appleData = SafetyTables.appleDataFolders.map { Self.key(lib + "/" + $0) }
        mobileDocuments = Self.key(lib + "/Mobile Documents")
        cloudStorage = Self.key(lib + "/CloudStorage")
        developerCaches = SafetyTables.developerCaches(home: h).map { ($0.name, Self.key($0.path)) }
        locations = LibraryLocation.allCases.map { ($0, Self.key(lib + "/" + $0.rawValue)) }
        libraryKnownChildren = Set((LibraryLocation.allCases.map(\.rawValue) + SafetyTables.libraryInternalExceptions)
            .map(Self.key))
        autosaveFolder = Self.key(SafetyTables.autosaveFolder)
        iCloudSyncableFolders = SafetyTables.iCloudSyncableHomeFolders.map { Self.key(h + "/" + $0) }
    }

    /// The `L/<location>/<name>` folder `path` is at or below, if any.
    func anchor(path: String, key: String) -> Anchor? {
        for entry in locations {
            if let name = Self.component(below: entry.path, path: path, key: key) {
                return Anchor(location: entry.location, name: name)
            }
        }
        return nil
    }

    /// ASCII-only lowercase: byte lengths stay equal, so offsets in a key are offsets in the original.
    static func key(_ string: String) -> String {
        var bytes = Array(string.utf8)
        for index in bytes.indices where bytes[index] >= 0x41 && bytes[index] <= 0x5A { bytes[index] += 0x20 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// NFC and Unicode lowercase: compares names whatever form the file system keeps them in. The
    /// one comparison form for running apps' bundle paths (rule 8, running app data, the Trash's
    /// subtree check). ASCII strings take a fast path with the same result (`key`).
    static func folded(_ string: String) -> String {
        string.utf8.allSatisfy { $0 < 0x80 } ? key(string) : string.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Whether `key` is `root` or below it, component-wise (both already keys).
    static func isUnder(_ key: String, _ root: String) -> Bool {
        let k = key.utf8, r = root.utf8
        guard k.starts(with: r) else { return false }
        return k.count == r.count || k[k.index(k.startIndex, offsetBy: r.count)] == UInt8(ascii: "/")
    }

    /// The original-case component of `path` right below `root` (compared by `key`), or nil when `path`
    /// is not strictly below `root` or that component is empty.
    static func component(below root: String, path: String, key: String) -> String? {
        let rootCount = root.utf8.count
        guard isUnder(key, root), key.utf8.count > rootCount + 1 else { return nil }
        let bytes = path.utf8.dropFirst(rootCount + 1)
        let name = bytes.prefix { $0 != UInt8(ascii: "/") }
        return name.isEmpty ? nil : String(decoding: name, as: UTF8.self)
    }
}

/// Finds the installed app an installer file is for (`Firefox 132.0.dmg` -> Firefox).
public enum InstallerMatcher {
    /// Stems shorter than this never match.
    public static let minimumStemLength = 3

    /// The installed app whose name (or file name) equals the installer's stem or starts with it.
    /// The stem is the lowercased name without extension, cut at the first digit or `-`, `_`, space or `(`.
    public static func app(forInstaller name: String, apps: AppsIndex) -> AppRecord? {
        guard let stem = stem(of: name) else { return nil }
        return apps.app(named: stem) ?? apps.app(namePrefix: stem)
    }

    static func stem(of name: String) -> String? {
        var text = SafetyPaths.key(name).trimmingCharacters(in: .whitespaces)
        if let dot = text.lastIndex(of: "."), dot != text.startIndex { text = String(text[..<dot]) }
        if let cut = text.firstIndex(where: { $0.isNumber || "-_ (".contains($0) }) { text = String(text[..<cut]) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count >= minimumStemLength ? text : nil
    }
}
