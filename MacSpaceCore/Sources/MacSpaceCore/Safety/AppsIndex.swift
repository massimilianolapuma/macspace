import Foundation
import Security

/// One installed application, or a bundle embedded in one (helper, extension, XPC service).
/// Embedded bundles carry the host app's `name` and `path`.
public struct AppRecord: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public let teamID: String?
    public let path: String

    public init(bundleID: String, name: String, teamID: String?, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.teamID = teamID
        self.path = path
    }
}

/// Lookup table of installed apps used to decide whether a `~/Library` folder belongs to one.
/// All lookups are ASCII case-insensitive.
public struct AppsIndex: Sendable {
    /// Where `build` looks for apps by default.
    public static let defaultRoots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]

    /// An index with no apps.
    public static let empty = AppsIndex(records: [])

    /// Number of records (apps, including those without a bundle ID, plus embedded bundles).
    public var count: Int { records.count }

    private let records: [AppRecord]
    private let byID: [String: AppRecord]
    /// Every dot-prefix (at least 2 labels, shorter than the whole ID) of each app ID.
    private let byIDPrefix: [String: AppRecord]
    private let byName: [String: AppRecord]
    private let teams: Set<String>
    /// Every record signed by a team, by lowest path first.
    private let byTeam: [String: [AppRecord]]
    /// Lowest-path app per vendor (first two bundle-ID labels), `com.apple` excluded.
    private let byVendor: [String: AppRecord]

    /// Builds an index over `records`; the first record wins when keys collide.
    public init(records: [AppRecord]) {
        var byID: [String: AppRecord] = [:]
        var byIDPrefix: [String: AppRecord] = [:]
        var byName: [String: AppRecord] = [:]
        var teams: Set<String> = []
        var byTeam: [String: [AppRecord]] = [:]
        var byVendor: [String: AppRecord] = [:]
        for record in records {
            let id = Self.lower(record.bundleID)
            if !id.isEmpty {   // "" means "no bundle ID": never reachable through identifier lookups
                if byID[id] == nil { byID[id] = record }
                for prefix in Self.dotPrefixes(of: id) where byIDPrefix[prefix] == nil {
                    byIDPrefix[prefix] = record
                }
                if let vendor = Self.vendor(of: id) {
                    if let current = byVendor[vendor], current.path <= record.path {} else { byVendor[vendor] = record }
                }
            }
            for name in [record.name, Self.baseName(ofPath: record.path)] {
                let key = Self.lower(name)
                if byName[key] == nil { byName[key] = record }
            }
            if let team = record.teamID, !team.isEmpty {
                let key = Self.lower(team)
                teams.insert(key)
                byTeam[key, default: []].append(record)
            }
        }
        // Stable: of records with the same path, the first one stays first.
        for key in byTeam.keys {
            byTeam[key] = byTeam[key]!.enumerated()
                .sorted { $0.element.path != $1.element.path ? $0.element.path < $1.element.path : $0.offset < $1.offset }
                .map(\.element)
        }
        self.records = records
        self.byID = byID
        self.byIDPrefix = byIDPrefix
        self.byName = byName
        self.teams = teams
        self.byTeam = byTeam
        self.byVendor = byVendor
    }

    /// The app whose bundle ID equals `id`, or where one is a prefix of the other on a `.` boundary
    /// and they share at least 2 labels (`com.foo.helper` and `com.foo`, never `com` and anything).
    public func app(forIdentifier id: String) -> AppRecord? {
        let key = Self.lower(id)
        guard !key.isEmpty else { return nil }
        if let exact = byID[key] { return exact }
        // An app ID that is a dot-prefix of the identifier, longest first.
        var end = key.endIndex
        while let dot = key[..<end].lastIndex(of: ".") {
            let prefix = key[..<dot]
            guard prefix.contains(".") else { break }
            if let record = byID[String(prefix)] { return record }
            end = dot
        }
        // The identifier is a dot-prefix of a longer app ID.
        guard key.contains(".") else { return nil }
        return byIDPrefix[key]
    }

    /// The app whose display name or file name (without `.app`) equals `name`.
    public func app(named name: String) -> AppRecord? {
        byName[Self.lower(name)]
    }

    /// The app whose display name or file name (without `.app`) starts with `prefix`; when several do,
    /// the one whose lowercased name sorts first. An empty prefix matches nothing.
    func app(namePrefix prefix: String) -> AppRecord? {
        let key = Self.lower(prefix)
        guard !key.isEmpty else { return nil }
        return byName.keys.filter { $0.utf8.starts(with: key.utf8) }.min().flatMap { byName[$0] }
    }

    /// Whether any installed app is signed by `teamID`.
    func hasTeam(_ teamID: String) -> Bool {
        teams.contains(Self.lower(teamID))
    }

    /// The app signed by `teamID` (case-insensitive); when several are, the one with the lowest `path`.
    public func app(forTeam teamID: String) -> AppRecord? {
        apps(forTeam: teamID).first
    }

    /// Every app signed by `teamID` (case-insensitive), lowest `path` first.
    func apps(forTeam teamID: String) -> [AppRecord] {
        byTeam[Self.lower(teamID)] ?? []
    }

    /// The app whose bundle ID has the same vendor (first two labels, `com.openai` for
    /// `com.openai.chat`) as `id`; when several do, the one with the lowest `path`. `com.apple` is no
    /// vendor here (Apple items are decided before), nor is an identifier with fewer than 2 labels.
    public func app(forVendorOf id: String) -> AppRecord? {
        Self.vendor(of: Self.lower(id)).flatMap { byVendor[$0] }
    }

    // MARK: - Building

    /// Scans `roots` (up to 2 levels below each, never into apps) plus `extraAppPaths` for apps and
    /// their embedded bundles. An app whose Info.plist is unreadable or lacks a bundle ID is still
    /// indexed by name and team ID with an empty `bundleID` (which never matches an identifier
    /// lookup), and its embedded bundles are still walked. Duplicates by path are ignored.
    /// Team IDs are read from the code signature of top-level apps only.
    ///
    /// Synchronous file-system and code-signature work: it blocks the caller, so keep it off the
    /// main actor.
    public static func build(
        roots: [String] = AppsIndex.defaultRoots,
        extraAppPaths: [String] = [],
        readTeamIDs: Bool = true
    ) -> AppsIndex {
        var appPaths: [String] = []
        var seenApps: Set<String> = []
        func add(_ path: String) {
            let clean = SafetyTables.normalized(path)
            if seenApps.insert(clean).inserted { appPaths.append(clean) }
        }
        for rawRoot in roots {
            let root = SafetyTables.normalized(rawRoot)
            for entry in names(in: root) {
                let path = root + "/" + entry
                if isApp(entry) {
                    add(path)
                } else if isDirectory(path) {
                    for child in names(in: path) where isApp(child) { add(path + "/" + child) }
                }
            }
        }
        extraAppPaths.forEach(add)

        let teams = readTeamIDs ? teamIDs(ofCodeAt: appPaths) : [:]
        var records: [AppRecord] = []
        var seenBundles: Set<String> = []
        for appPath in appPaths {
            let info = readInfo(bundle: appPath)
            let name = info?.displayName ?? info?.name ?? baseName(ofPath: appPath)
            if seenBundles.insert(appPath).inserted {
                records.append(AppRecord(bundleID: info?.id ?? "", name: name, teamID: teams[appPath], path: appPath))
            }
            for embedded in embeddedBundles(inApp: appPath) where seenBundles.insert(embedded.path).inserted {
                guard let childID = embedded.isBundle ? readInfo(bundle: embedded.path)?.id : embedded.fileID
                else { continue }
                records.append(AppRecord(bundleID: childID, name: name, teamID: nil, path: appPath))
            }
        }
        return AppsIndex(records: records)
    }

    // MARK: - Helpers

    /// ASCII-only lowercase (`SafetyPaths.key`), so lookups never depend on Unicode case folding.
    private static func lower(_ string: String) -> String { SafetyPaths.key(string) }

    /// The first two labels of a lowercased identifier (`com.openai`), or nil when it has fewer than 2
    /// non-empty leading labels, the vendor is `com.apple` or one of `SafetyTables.notVendorPrefixes`.
    private static func vendor(of id: String) -> String? {
        let labels = id.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels[0].isEmpty, !labels[1].isEmpty else { return nil }
        let vendor = String(labels[0] + "." + labels[1])
        return vendor == "com.apple" || SafetyTables.notVendorPrefixes.contains(vendor) ? nil : vendor
    }

    /// Proper dot-prefixes of `id` that keep at least 2 labels, longest first.
    static func dotPrefixes(of id: String) -> [String] {
        var result: [String] = []
        var end = id.endIndex
        while let dot = id[..<end].lastIndex(of: ".") {
            let prefix = id[..<dot]
            guard prefix.contains(".") else { break }
            result.append(String(prefix))
            end = dot
        }
        return result
    }

    /// File name of `path` without a (case-insensitive) `.app` suffix.
    static func baseName(ofPath path: String) -> String {
        let fileName = (path as NSString).lastPathComponent
        return fileName.lowercased().hasSuffix(".app") && fileName.count > 4 ? String(fileName.dropLast(4)) : fileName
    }

    /// Whether `name` looks like a reverse-DNS identifier (privileged helpers are named by it).
    private static func isIdentifierLike(_ name: String) -> Bool {
        name.contains(".") && !name.hasPrefix(".") && !name.hasSuffix(".")
            && name.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7A)
                || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F }
    }

    private static func isApp(_ name: String) -> Bool {
        name.count > 4 && name.lowercased().hasSuffix(".app")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func names(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    private struct BundleInfo {
        var id: String?
        var name: String?
        var displayName: String?
    }

    /// Reads `Contents/Info.plist` (or a flat `Info.plist`) of the bundle at `path`.
    private static func readInfo(bundle path: String) -> BundleInfo? {
        for candidate in [path + "/Contents/Info.plist", path + "/Info.plist"] {
            guard let data = FileManager.default.contents(atPath: candidate),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any] else { continue }
            func string(_ key: String) -> String? {
                guard let value = dict[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            return BundleInfo(id: string("CFBundleIdentifier"), name: string("CFBundleName"),
                              displayName: string("CFBundleDisplayName"))
        }
        return nil
    }

    private struct Embedded {
        var path: String
        var isBundle: Bool
        /// For launch-services helpers (plain executables): the file name, used as bundle ID.
        var fileID: String?
    }

    /// Helper apps, extensions, XPC services and launch-services helpers inside an app.
    private static func embeddedBundles(inApp appPath: String) -> [Embedded] {
        let places: [(dir: String, ext: String?)] = [
            ("Contents/Library/LoginItems", "app"), ("Contents/Helpers", "app"),
            ("Contents/PlugIns", "appex"), ("Contents/XPCServices", "xpc"),
            ("Contents/Library/LaunchServices", nil),
        ]
        var result: [Embedded] = []
        for place in places {
            let dir = appPath + "/" + place.dir
            for name in names(in: dir) {
                if let ext = place.ext {
                    if (name as NSString).pathExtension.lowercased() == ext {
                        result.append(Embedded(path: dir + "/" + name, isBundle: true, fileID: nil))
                    }
                } else if isIdentifierLike(name) {
                    // Privileged helpers are Mach-O files named by their bundle ID, not bundles.
                    result.append(Embedded(path: dir + "/" + name, isBundle: false, fileID: name))
                }
            }
        }
        return result
    }

    /// Reads team IDs concurrently (code-signature checks dominate the build time).
    private static func teamIDs(ofCodeAt paths: [String]) -> [String: String] {
        let lock = NSLock()
        nonisolated(unsafe) var result: [String: String] = [:]
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let team = teamID(ofCodeAt: paths[index]) else { return }
            lock.lock()
            result[paths[index]] = team
            lock.unlock()
        }
        return result
    }

    private static func teamID(ofCodeAt path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }
}
